import AppKit
import MemoryCore
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @Environment(MemoryModel.self) private var model
    @State private var search = ""
    @State private var selection: AppUsage.ID?

    private var filteredRows: [AppUsage] {
        search.isEmpty ? model.rows : model.rows.filter { $0.name.localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        @Bindable var model = model
        Table(filteredRows, selection: $selection, sortOrder: $model.sortOrder) {
            TableColumn(localized("App"), value: \.name) { row in
                HStack(spacing: 6) {
                    Image(nsImage: AppIcons.icon(for: row.appPath))
                        .resizable()
                        .frame(width: 16, height: 16)
                    Text(row.name)
                }
            }
            TableColumn(localized("Processes"), value: \.processCount) { row in
                Text(String(row.processCount))
                    .monospacedDigit()
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 60, ideal: 70, max: 90)
            TableColumn(localized("Memory"), value: \.bytes) { row in
                HStack(spacing: 1) {
                    Text(formatBytes(row.bytes))
                        .monospacedDigit()
                    Text("*")
                        .opacity(row.deduplicated ? 0 : 1)
                        .help(localized("footprint unavailable: sum of the individual footprints, shared memory may be counted more than once."))
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 80, ideal: 90, max: 120)
        }
        .onChange(of: model.sortOrder) { model.sortRows() }
        .searchable(text: $search, placement: .toolbar, prompt: localized("Search"))
        .toolbar {
            ToolbarItemGroup {
                Toggle(localized("Top \(MemoryModel.topCount) only"), isOn: $model.topOnly)
                    .toggleStyle(.checkbox)
                    .help(localized("Measure and show only the largest apps (saves a lot of CPU)"))
                Picker(localized("Interval"), selection: $model.interval) {
                    ForEach(RefreshInterval.allCases) { Text($0.label).tag($0) }
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
