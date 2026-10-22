import AppKit
import MemoryCore
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @Environment(MemoryModel.self) private var model
    @State private var search = ""
    @State private var selection: AppUsage.ID?
    /// Shows the Shared column.
    @State private var showsShared = false
    /// Only for the visibility of the User and Shared columns (an `if` in the table needs macOS 14.4).
    @State private var columns = TableColumnCustomization<AppUsage>()

    private var filteredRows: [AppUsage] {
        search.isEmpty ? model.rows : model.rows.filter {
            $0.name.localizedCaseInsensitiveContains(search)
                || model.showsAllUsers && $0.userName.localizedCaseInsensitiveContains(search)
        }
    }

    var body: some View {
        @Bindable var model = model
        Table(filteredRows, selection: $selection, sortOrder: $model.sortOrder, columnCustomization: $columns) {
            TableColumn(localized("App"), value: \.name) { row in
                HStack(spacing: 6) {
                    Image(nsImage: AppIcons.icon(for: row.appPath))
                        .resizable()
                        .frame(width: 16, height: 16)
                    Text(row.name)
                }
            }
            TableColumn(localized("User"), value: \.userName)
                .width(min: 50, ideal: 80, max: 140)
                .customizationID("user")
            TableColumn(localized("Processes"), value: \.processCount) { row in
                Text(String(row.processCount))
                    .monospacedDigit()
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 60, ideal: 70, max: 90)
            TableColumn(localized("Memory"), value: \.bytes) { row in
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
            .width(min: 90, ideal: 105, max: 140)
            TableColumn(localized("Shared"), value: \.shared) { row in
                let measured = row.deduplicated && !row.preliminary
                Text(measured ? formatBytes(row.shared) : "–")
                    .monospacedDigit()
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .help(measured ? localized("Memory used by several of the app's processes, counted only once in “Memory”")
                        : localized("Not measured (plain sum)"))
            }
            .width(min: 80, ideal: 95, max: 140)
            .customizationID("shared")
        }
        .onChange(of: model.sortOrder) { model.sortRows() }
        .onChange(of: model.showsAllUsers, initial: true) {
            columns[visibility: "user"] = model.showsAllUsers ? .visible : .hidden
        }
        .onChange(of: showsShared, initial: true) {
            columns[visibility: "shared"] = showsShared ? .visible : .hidden
        }
        .searchable(text: $search, placement: .toolbar, prompt: localized("Search"))
        .toolbar {
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
                Toggle(localized("Top \(MemoryModel.topCount) only"), isOn: $model.topOnly)
                    .toggleStyle(.checkbox)
                    .help(localized("Measure and show only the largest apps (saves a lot of CPU)"))
                Toggle(localized("Advanced"), isOn: $showsShared)
                    .toggleStyle(.checkbox)
                    .help(localized("Show how much less each row is than the sum of its processes, because memory they share counts only once"))
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
        .safeAreaInset(edge: .bottom, spacing: 0) {
            statusBar
        }
        .task { await model.runAutoRefresh() }
        .alert(localized("Can't show all users' processes"), isPresented: Binding(
            get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } }
        )) {} message: {
            Text(model.errorMessage ?? "")
        }
    }

    private var statusBar: some View {
        HStack {
            Text(statusText)
            Spacer()
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(.bar)
    }

    private var statusText: String {
        guard let lastUpdate = model.lastUpdate, let duration = model.lastDuration else {
            return localized("Measuring…")
        }
        let seconds = Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
        let count = model.rows.count < model.groupCount
            ? localized("\(model.rows.count) of \(model.groupCount) apps") : localized("\(model.rows.count) apps")
        let time = lastUpdate.formatted(date: .omitted, time: .standard)
        let measured = seconds.formatted(.number.precision(.fractionLength(1)))
        return [count, localized("Updated \(time)"), localized("Measurement \(measured) s")].joined(separator: " · ")
    }
}

extension AppUsage {
    var userName: String { MemoryCore.userName(of: uid) }
}

@MainActor
private enum AppIcons {
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
