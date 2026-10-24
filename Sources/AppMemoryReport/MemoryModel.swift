import AppKit
import MemoryCore
import Observation

enum RefreshInterval: Int, CaseIterable, Identifiable {
    case manual = 0, seconds5 = 5, seconds10 = 10, seconds30 = 30, seconds60 = 60

    var id: Int { rawValue }
    var label: String { self == .manual ? localized("Manual") : "\(rawValue) s" }
}

/// One value per finished measurement, for the chart.
struct MemorySample: Identifiable {
    let date: Date
    let bytes: UInt64
    var id: Date { date }
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
    /// System-wide RAM in use, read after each measurement.
    private(set) var systemMemory: SystemMemory?
    /// The last `historyLength` measured values per row, oldest first.
    private(set) var histories: [AppUsage.ID: [MemorySample]] = [:]
    /// The last `historyLength` values of `systemMemory.used`, oldest first.
    private(set) var ramHistory: [MemorySample] = []
    static let historyLength = 64
    /// Histories of rows that are no longer measured are dropped after this long.
    private static let historyRetention: TimeInterval = 30 * 60
    /// End of the last measurement; the next automatic one starts `interval` later.
    private var lastFinished: ContinuousClock.Instant?
    /// `topOnly` of the shown rows; a mismatch triggers a new measurement.
    private var rowsTopOnly: Bool?
    /// Connection to the helper running as root while all users' processes are shown.
    private var helper: HelperConnection?
    var showsAllUsers: Bool { helper != nil }
    /// `showsAllUsers` of the shown rows; a mismatch triggers a new measurement.
    private var rowsAllUsers: Bool?
    private(set) var isAuthenticating = false
    /// Shown as an alert, reset when it is dismissed.
    var errorMessage: String?
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
        let limit = topOnly ? Self.topCount : nil
        let helper = helper
        runCount += 1
        let run = runCount
        liveRun = run
        let progress: @Sendable ([AppUsage]) -> Void = { updates in
            Task { @MainActor in self.apply(updates, run: run) }
        }
        let result: (rows: [AppUsage], groupCount: Int)
        if let helper {
            do {
                result = try await Task.detached(priority: .utility) {
                    try helper.measure(limit: limit, progress: progress)
                }.value
            } catch {
                liveRun = nil
                if self.helper === helper {
                    self.helper = nil
                    clearRows()
                    errorMessage = localized("The helper process ended.")
                }
                return
            }
        } else {
            // footprint is CPU-heavy, so run few of them at low priority. No total: it is
            // the slowest measurement by far and not needed to compare apps.
            let cache = cache
            let report = await Task.detached(priority: .utility) {
                MemoryReport.measure(includeAllUsers: false, includeTotal: false, limit: limit,
                                     maxConcurrency: 4, qos: .utility, cache: cache, progress: progress)
            }.value
            self.cache = report.cache
            result = (report.rows, report.groupCount)
        }
        // Switched between own and all users' processes meanwhile: the next refresh measures again.
        guard liveRun == run else { return }
        liveRun = nil
        lastFinished = .now
        lastDuration = lastFinished! - start
        lastUpdate = .now
        rowsTopOnly = topOnly
        rowsAllUsers = helper != nil
        groupCount = result.groupCount
        rows = result.rows.sorted(using: sortOrder)
        systemMemory = SystemMemory.current()
        recordSamples(result.rows, at: lastUpdate!)
    }

    /// Appends the final values of a measurement (never preliminary ones) to the histories.
    private func recordSamples(_ measured: [AppUsage], at date: Date) {
        func append(_ bytes: UInt64, to history: inout [MemorySample]) {
            history.append(MemorySample(date: date, bytes: bytes))
            history.removeFirst(max(0, history.count - Self.historyLength))
        }
        for row in measured {
            append(row.bytes, to: &histories[row.id, default: []])
        }
        if let systemMemory {
            append(systemMemory.used, to: &ramHistory)
        }
        // Short-lived rows (e.g. terminal commands) would otherwise pile up.
        histories = histories.filter { date.timeIntervalSince($0.value.last!.date) < Self.historyRetention }
    }

    /// Shows all users' processes (starting the root helper, which asks for an administrator
    /// password) or only the current user's (ending the helper).
    func setShowsAllUsers(_ enabled: Bool) async {
        guard enabled != showsAllUsers, !isAuthenticating else { return }
        if enabled {
            isAuthenticating = true
            defer { isAuthenticating = false }
            do {
                helper = try await PrivilegedHelper.launch()
            } catch PrivilegedHelper.LaunchError.cancelled {
                return
            } catch PrivilegedHelper.LaunchError.notFound(let path) {
                errorMessage = localized("The helper \(path) wasn't found. Build it with “swift build”.")
                return
            } catch PrivilegedHelper.LaunchError.failed(let message) {
                errorMessage = message
                return
            } catch {
                errorMessage = String(describing: error)
                return
            }
        } else {
            helper = nil
        }
        clearRows()
        await refresh()
    }

    /// Drops rows of the other mode (own / all users), including those of a running measurement.
    /// The RAM history is system-wide and stays.
    private func clearRows() {
        liveRun = nil
        rows = []
        histories = [:]
        lastUpdate = nil
    }

    /// Shows rows while a measurement runs. Preliminary values only fill in rows that
    /// aren't shown yet, so a refresh never replaces a measured value with a rough one.
    private func apply(_ updates: [AppUsage], run: Int) {
        guard run == liveRun else { return }
        let indices = Dictionary(rows.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { a, _ in a })
        for update in updates {
            if let index = indices[update.id] {
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
        guard let lastFinished, rowsTopOnly == topOnly, rowsAllUsers == showsAllUsers else { return true }
        return interval != .manual && NSApp.occlusionState.contains(.visible)
            && ContinuousClock.now - lastFinished >= .seconds(interval.rawValue)
    }
}
