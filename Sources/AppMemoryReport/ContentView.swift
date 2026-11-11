import AppKit
import MemoryCore
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @Environment(MemoryModel.self) private var model
    @State private var search = ""
    @State private var selection: TableItem.ID?
    @State private var sortOrder = [KeyPathComparator(\TableItem.bytes, order: .reverse)]
    /// Shows the Shared and Est. RAM columns and the compressor in the status bar ("Advanced").
    @State private var showsShared = false
    /// Only for the visibility of the User, Shared and Est. RAM columns (an `if` in the table needs macOS 14.4).
    @State private var columns = TableColumnCustomization<TableItem>()
    /// The process shown in the details sheet (double click on a row).
    @State private var details: ProcessDetailsRequest?
    /// Pointer position over the chart, nil when it is outside.
    @State private var hoverDate: Date?

    /// App rows with their processes as children, filtered and sorted. A search also finds
    /// an app by the name of one of its processes.
    private var items: [TableItem] {
        let items = model.rows.map(TableItem.init)
        let filtered = search.isEmpty ? items
            : items.filter { $0.matches(search, includingUser: model.showsAllUsers) }
        return TableItem.sorted(filtered, using: sortOrder)
    }

    /// The app of the selected row, which may be one of its processes.
    private var selectedApp: AppUsage? {
        guard let selection else { return nil }
        return model.rows.first { $0.id == selection }
            ?? model.rows.first { row in
                selection.hasPrefix(row.id + "/") && Int(selection.dropFirst(row.id.count + 1)) != nil
            }
    }

    var body: some View {
        @Bindable var model = model
        // Not a safe-area inset: the split view ignores it and would run under the status bar.
        VStack(spacing: 0) {
            VSplitView {
                table
                    .frame(minHeight: 150)
                    .layoutPriority(1)
                chart
                    .frame(minHeight: 160, maxHeight: 400)
            }
            statusBar
        }
        .searchable(text: $search, placement: .toolbar, prompt: localized("Search"))
        .navigationSubtitle(subtitle)
        .toolbar {
            toolbar
        }
        .task { await model.runAutoRefresh() }
        .alert(localized("Can't show all users' processes"), isPresented: Binding(
            get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } }
        )) {} message: {
            Text(model.errorMessage ?? "")
        }
    }

    private var table: some View {
        let items = items
        return Table(items, children: \.children, selection: $selection, sortOrder: $sortOrder,
                     columnCustomization: $columns) {
            TableColumn(localized("App"), value: \.name) { row in
                HStack(spacing: 6) {
                    if !row.isProcess {
                        Image(nsImage: AppIcons.icon(for: row.appPath))
                            .resizable()
                            .frame(width: 16, height: 16)
                    }
                    Text(row.name)
                }
            }
            TableColumn(localized("User"), value: \.userName)
                .width(min: 50, ideal: 80, max: 140)
                .customizationID("user")
            TableColumn(localized("Processes"), value: \.processCount) { row in
                Text(row.isProcess ? "" : String(row.processCount))
                    .monospacedDigit()
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 60, ideal: 70, max: 90)
            TableColumn(localized("Memory"), value: \.bytes) { row in
                if row.isProcess {
                    processMemory(row)
                } else {
                    appMemory(row)
                }
            }
            .width(min: 90, ideal: 105, max: 140)
            TableColumn(localized("Shared"), value: \.shared) { row in
                let measured = row.deduplicated && !row.preliminary
                Text(row.isProcess ? "" : measured ? formatBytes(row.shared) : "–")
                    .monospacedDigit()
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .help(row.isProcess ? ""
                        : measured ? localized("Memory used by several of the app's processes, counted only once in “Memory”")
                        : localized("Not measured (plain sum)"))
            }
            .width(min: 80, ideal: 95, max: 140)
            .customizationID("shared")
            TableColumn(localized("Est. RAM"), value: \.estimatedRAM) { row in
                Text(row.measured ? formatBytes(row.estimatedRAM) : "–")
                    .monospacedDigit()
                    .foregroundStyle(row.preliminary ? .secondary : .primary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .help(row.measured ? estimatedRAMHelp(row) : "")
            }
            .width(min: 90, ideal: 105, max: 140)
            .customizationID("ram")
            TableColumn(localized("Attributed via"), value: \.attribution)
                .width(min: 120, ideal: 240)
        }
        .contextMenu(forSelectionType: TableItem.ID.self) { ids in
            if let id = ids.first {
                Button(localized("Show Details…")) { showDetails(id, in: items) }
            }
        } primaryAction: { ids in
            if let id = ids.first { showDetails(id, in: items) }
        }
        .sheet(item: $details) { ProcessDetailsView(request: $0) }
        .onChange(of: model.showsAllUsers, initial: true) {
            columns[visibility: "user"] = model.showsAllUsers ? .visible : .hidden
        }
        .onChange(of: showsShared, initial: true) {
            columns[visibility: "shared"] = showsShared ? .visible : .hidden
            columns[visibility: "ram"] = showsShared ? .visible : .hidden
        }
        .overlay {
            if items.isEmpty && !search.isEmpty {
                ContentUnavailableView(localized("No Results for “\(search)”"), systemImage: "magnifyingglass",
                                       description: Text(localized("Check the spelling or try a new search.")))
            }
        }
    }

    private func estimatedRAMHelp(_ row: TableItem) -> String {
        guard row.compressed > 0 else {
            return localized("Estimated physical RAM: none of this memory is compressed, so this equals “Memory”.")
        }
        let ratio = formatFactor(row.compressionRatio)
        return localized("Estimated physical RAM. “Memory” counts the \(formatBytes(row.compressed)) that macOS has compressed at their original size, as Activity Monitor does. Here they count at the system-wide compression ratio instead (currently \(ratio) : 1), roughly the RAM they take up in the compressor. The kernel doesn't record how well a single process's memory compresses, so this assumes the average: text and empty pages compress much better, images and code much worse.")
    }

    /// Opens the details sheet for a row's process (an app row: its main process).
    private func showDetails(_ id: TableItem.ID, in items: [TableItem]) {
        func find(_ items: [TableItem]) -> TableItem? {
            for item in items {
                if item.id == id { return item }
                if let found = find(item.children ?? []) { return found }
            }
            return nil
        }
        guard let item = find(items), let pid = item.pid else { return }
        let name = item.isProcess ? item.name : "\(item.name) [\(pid)]"
        details = ProcessDetailsRequest(name: name, userName: item.userName, details: ProcessDetails(pid: pid))
    }

    // No numericText transition in the table cells: its blurred in-between frames fill
    // CoreGraphics' glyph cache, ~55 MB with all rows shown.
    private func appMemory(_ row: TableItem) -> some View {
                HStack(spacing: 1) {
                    Text((row.preliminary ? "≈ " : "") + formatBytes(row.bytes))
                        .monospacedDigit()
                        .foregroundStyle(row.preliminary ? .secondary : .primary)
                    Text("*")
                        .opacity(row.deduplicated || row.preliminary ? 0 : 1)
                        .help(localized("Plain sum of the individual footprints (footprint unavailable, or skipped because hardly any memory can be shared): shared memory may be counted more than once."))
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
                .help(row.preliminary ? localized("Preliminary: sum of the individual footprints, still being measured") : "")
    }

    /// A single process's own value; the app row counts memory shared with its other processes once.
    private func processMemory(_ row: TableItem) -> some View {
        Text(row.measured ? formatBytes(row.bytes) : "–")
            .monospacedDigit()
            .frame(maxWidth: .infinity, alignment: .trailing)
            .help(localized("This process's own memory (phys_footprint). The app's row counts memory shared between its processes only once."))
    }

    /// The selected row's history, or system RAM without a selection. The RAM chart has the
    /// largest apps beside it, at the hovered measurement or else the latest one.
    @ViewBuilder
    private var chart: some View {
        if let row = selectedApp {
            MemoryChart(title: row.name, value: formatBytes(row.bytes), samples: model.histories[row.id] ?? [],
                        hoverDate: $hoverDate)
        } else {
            HStack(spacing: 0) {
                MemoryChart(title: localized("RAM used"), value: model.systemMemory.map {
                    localized("\(formatBytes($0.used)) of \(formatBytes($0.physical))")
                } ?? "", samples: model.ramHistory, hoverDate: $hoverDate)
                if let date = (MemoryChart.nearest(to: hoverDate, in: model.ramHistory) ?? model.ramHistory.last)?.date {
                    Divider()
                        .environment(\.colorScheme, .light)
                    LargestAppsPane(apps: model.largestApps(at: date, count: 6))
                        .frame(width: 240)
                }
            }
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        @Bindable var model = model
        ToolbarItemGroup {
            Button {
                Task { await model.setShowsAllUsers(!model.showsAllUsers) }
            } label: {
                Label(localized("All Users"), systemImage: model.showsAllUsers ? "lock.open.fill" : "lock.fill")
            }
            .disabled(model.isAuthenticating)
            .help(model.showsAllUsers
                ? localized("Showing all users' processes. Click to show only your own.")
                : localized("Click to show all users' processes (requires an administrator password)"))
            Menu {
                Toggle(localized("Top \(MemoryModel.topCount) only"), isOn: $model.topOnly)
                Toggle(localized("Advanced"), isOn: $showsShared)
            } label: {
                Label(localized("Options"), systemImage: "slider.horizontal.3")
            }
            .help(localized("Options"))
            // A menu with the current value as its title: a Picker in the toolbar
            // doesn't reliably show its selection.
            Menu {
                Picker(localized("Interval"), selection: $model.interval) {
                    ForEach(RefreshInterval.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            } label: {
                Text(model.interval.label)
            }
            .help(localized("Automatic refresh"))
            Button {
                Task { await model.refresh() }
            } label: {
                if model.isMeasuring {
                    ProgressView().controlSize(.small)
                } else {
                    Label(localized("Refresh"), systemImage: "arrow.clockwise")
                }
            }
            .disabled(model.isMeasuring)
            .help(localized("Refresh (⌘R)"))
        }
    }

    /// RAM gauge colored by memory pressure on the left, time and duration of the last measurement on the right.
    private var statusBar: some View {
        HStack(spacing: 8) {
            if let memory = model.systemMemory {
                Gauge(value: Double(memory.used), in: 0...Double(memory.physical)) {}
                    .gaugeStyle(.linearCapacity)
                    .tint(memory.pressure.color)
                    .frame(width: 90)
                    // On macOS the gauge is an NSLevelIndicator, which can be dragged by default.
                    .allowsHitTesting(false)
                Text(localized("RAM used \(formatBytes(memory.used)) of \(formatBytes(memory.physical))"))
                    .monospacedDigit()
                    .contentTransition(.numericText(value: Double(memory.used)))
                    .animation(.snappy, value: memory.used)
                if showsShared {
                    Text("·")
                    Text(localized("Compressor \(formatBytes(memory.compressorOccupied))"))
                        .monospacedDigit()
                    if memory.compressorStored > 0 {
                        Text("·")
                        Text(localized("Factor \(formatFactor(memory.compressionRatio)) : 1"))
                            .monospacedDigit()
                    }
                }
            }
            Spacer()
            Text(lastMeasurementText)
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(.bar)
        .help((model.systemMemory.map { $0.pressure.label + "\n" } ?? "")
            + localized("RAM used: Activity Monitor's “Memory Used”, the physical memory actually occupied by all users' apps, the kernel and the compressor. The rows count compressed memory at its original size, so they can add up to more.")
            + ((showsShared ? model.systemMemory : nil).map {
                "\n" + localized("Compressor: the RAM occupied by compressed memory, part of “RAM used”. It holds \(formatBytes($0.compressorStored)) at their original size, on average \(formatFactor($0.compressionRatio)) times as much (the factor “Est. RAM” uses).")
            } ?? ""))
    }

    /// `compressionRatio` (RAM per byte held) as a compression factor, e.g. 0.5 → "2.0".
    private func formatFactor(_ ratio: Double) -> String {
        (1 / ratio).formatted(.number.precision(.fractionLength(1)))
    }

    private var subtitle: String {
        guard model.lastUpdate != nil else { return localized("Measuring…") }
        return model.rows.count < model.groupCount
            ? localized("\(model.rows.count) of \(model.groupCount) apps") : localized("\(model.rows.count) apps")
    }

    private var lastMeasurementText: String {
        guard let lastUpdate = model.lastUpdate, let duration = model.lastDuration else { return "" }
        let seconds = Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
        let time = lastUpdate.formatted(date: .omitted, time: .standard)
        let measured = seconds.formatted(.number.precision(.fractionLength(1)))
        return [localized("Updated \(time)"), localized("Measurement \(measured) s")].joined(separator: " · ")
    }
}

extension SystemMemory.Pressure {
    /// As in Activity Monitor's "Memory Pressure" graph.
    var color: Color {
        switch self {
        case .normal: .green
        case .warning: .yellow
        case .critical: .red
        }
    }

    var label: String {
        switch self {
        case .normal: localized("Memory pressure: normal")
        case .warning: localized("Memory pressure: elevated")
        case .critical: localized("Memory pressure: critical")
        }
    }
}

extension AppUsage {
    var userName: String { MemoryCore.userName(of: uid) }
}

@MainActor
enum AppIcons {
    private static var cache: [String: NSImage] = [:]
    private static let executable = NSWorkspace.shared.icon(for: .unixExecutable)

    static func icon(for appPath: String?) -> NSImage {
        guard let appPath else { return executable }
        if let icon = cache[appPath] { return icon }
        let icon = NSWorkspace.shared.icon(forFile: appPath)
        cache[appPath] = icon
        return icon
    }
}
