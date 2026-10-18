import AppKit
import MemoryCore
import Observation

enum RefreshInterval: Int, CaseIterable, Identifiable {
    case manual = 0, seconds5 = 5, seconds10 = 10, seconds30 = 30, seconds60 = 60

    var id: Int { rawValue }
    var label: String { self == .manual ? localized("Manual") : "\(rawValue) s" }
}

@Observable
@MainActor
final class MemoryModel {
    private(set) var rows: [AppUsage] = []
    var sortOrder = [KeyPathComparator(\AppUsage.bytes, order: .reverse)]
    var interval = RefreshInterval.seconds30
    /// Measures only the largest apps, which saves most of the footprint runs.
    var topOnly = true
    nonisolated static let topCount = 30
    private(set) var groupCount = 0
    private(set) var isMeasuring = false
    private(set) var lastUpdate: Date?
    private(set) var lastDuration: Duration?
    /// End of the last measurement; the next automatic one starts `interval` later.
    private var lastFinished: ContinuousClock.Instant?
    /// `topOnly` of the shown rows; a mismatch triggers a new measurement.
    private var rowsTopOnly: Bool?
    /// Shared memory per group from the previous measurement, so unchanged groups skip footprint.
    private var cache = FootprintCache()
    /// Number of the measurement whose progress updates are applied; nil when none runs.
    private var liveRun: Int?
    private var runCount = 0

    func refresh() async {
        guard !isMeasuring else { return }
        isMeasuring = true
        defer { isMeasuring = false }

        let start = ContinuousClock.now
        let topOnly = topOnly
        let cache = cache
        runCount += 1
        let run = runCount
        liveRun = run
        // footprint is CPU-heavy, so run few of them at low priority. No total: it is
        // the slowest measurement by far and not needed to compare apps.
        let report = await Task.detached(priority: .utility) {
            MemoryReport.measure(includeAllUsers: false, includeTotal: false,
                                 limit: topOnly ? Self.topCount : nil,
                                 maxConcurrency: 4, qos: .utility, cache: cache) { updates in
                Task { @MainActor in self.apply(updates, run: run) }
            }
        }.value
        liveRun = nil
        self.cache = report.cache
        lastFinished = .now
        lastDuration = lastFinished! - start
        lastUpdate = .now
        rowsTopOnly = topOnly
        groupCount = report.groupCount
        rows = report.rows.sorted(using: sortOrder)
    }

    /// Shows rows while a measurement runs. Preliminary values only fill in rows that
    /// aren't shown yet, so a refresh never replaces a measured value with a rough one.
    private func apply(_ updates: [AppUsage], run: Int) {
        guard run == liveRun else { return }
        let indices = Dictionary(rows.enumerated().map { ($1.name, $0) }, uniquingKeysWith: { a, _ in a })
        for update in updates {
            if let index = indices[update.name] {
                if !update.preliminary { rows[index] = update }
            } else {
                rows.append(update)
            }
        }
        rows.sort(using: sortOrder)
    }

    func sortRows() {
        rows.sort(using: sortOrder)
    }

    /// Measures once at start, then every `interval` after the previous measurement ended,
    /// but only while a window is visible. Runs until the calling task is cancelled.
    func runAutoRefresh() async {
        while !Task.isCancelled {
            if isDue {
                await refresh()
            }
            try? await Task.sleep(for: .seconds(1))
        }
    }

    private var isDue: Bool {
        guard let lastFinished, rowsTopOnly == topOnly else { return true }
        return interval != .manual && NSApp.occlusionState.contains(.visible)
            && ContinuousClock.now - lastFinished >= .seconds(interval.rawValue)
    }
}
