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

/// An app with its value at one point of the history, for the largest-apps pane.
struct RankedApp: Identifiable {
    let id: AppUsage.ID
    let name: String
    let appPath: String?
    let bytes: UInt64
}

@Observable
@MainActor
final class MemoryModel {
    /// Unsorted; the view sorts them.
    private(set) var rows: [AppUsage] = []
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
    /// Measured values per row from the last `historyWindow`, oldest first.
    private(set) var histories: [AppUsage.ID: [MemorySample]] = [:]
    /// Name and bundle of every row in `histories`, kept after the app quits.
    private var historyApps: [AppUsage.ID: (name: String, appPath: String?)] = [:]
    /// Values of `systemMemory.used` from the last `historyWindow`, oldest first.
    private(set) var ramHistory: [MemorySample] = []
    /// How far the histories (and so the chart) reach back. Measurements pause while no
    /// window is visible or the Mac sleeps; older samples are dropped by the next one.
    static let historyWindow: TimeInterval = 30 * 60
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
        rows = result.rows
        systemMemory = SystemMemory.current()
        recordSamples(result.rows, at: lastUpdate!)
        // A measurement churns through many short-lived allocations (process table, progress
        // updates, SwiftUI diffs). malloc keeps the freed pages dirty, and they would count
        // toward the app's own footprint until reused; hand them back to the system.
        malloc_zone_pressure_relief(nil, 0)
    }

    /// Appends the final values of a measurement (never preliminary ones) to the histories.
    private func recordSamples(_ measured: [AppUsage], at date: Date) {
        let start = date.addingTimeInterval(-Self.historyWindow)
        for row in measured {
            histories[row.id, default: []].append(MemorySample(date: date, bytes: row.bytes))
            historyApps[row.id] = (row.name, row.appPath)
        }
        if let systemMemory {
            ramHistory.append(MemorySample(date: date, bytes: systemMemory.used))
        }
        ramHistory.removeAll { $0.date < start }
        // Rows no longer measured (quit apps, finished terminal commands) drop out entirely.
        histories = histories.compactMapValues { samples in
            let recent = samples.filter { $0.date >= start }
            return recent.isEmpty ? nil : recent
        }
        historyApps = historyApps.filter { histories[$0.key] != nil }
    }

    /// The `count` largest apps measured at `date`, a measurement's date from the histories
    /// (all rows of a measurement and the RAM history share it).
    func largestApps(at date: Date, count: Int) -> [RankedApp] {
        histories.compactMap { id, samples in
            guard let sample = samples.last(where: { $0.date == date }), let app = historyApps[id] else { return nil }
            return RankedApp(id: id, name: app.name, appPath: app.appPath, bytes: sample.bytes)
        }
        .sorted { $0.bytes > $1.bytes }
        .prefix(count)
        .map { $0 }
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
        historyApps = [:]
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
