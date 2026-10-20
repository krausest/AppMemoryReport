import Darwin
import Foundation

/// Memory of one app or root process with all processes attributed to it.
public struct AppUsage: Identifiable, Sendable, Codable {
    /// Names are unique per user, see `groupProcesses`.
    public var id: String { "\(uid)/\(name)" }
    public let name: String
    /// Owner of the app or root process.
    public let uid: uid_t
    public let processCount: Int
    public let bytes: UInt64
    /// false if shared memory may be counted more than once (see `Measurement`).
    public let deduplicated: Bool
    /// Sum of the processes' `phys_footprint` that `bytes` was measured from.
    public let plainSum: UInt64
    /// Plain sum of the kernel values, reported via `progress` before `footprint` is done.
    public let preliminary: Bool
    /// Outermost `.app` bundle, nil for processes outside any bundle.
    public let appPath: String?

    /// Memory counted in several of the group's processes, which `bytes` counts once.
    /// Only measured if `deduplicated` and not `preliminary`.
    public var shared: UInt64 { plainSum > bytes ? plainSum - bytes : 0 }
}

public struct MemoryReport: Sendable {
    /// Unsorted, without groups whose processes all exited before measuring.
    public let rows: [AppUsage]
    /// All rows' processes measured together, so memory shared between rows counts once.
    public let total: Measurement?
    /// Number of groups found, including those left out by `limit`.
    public let groupCount: Int
    /// Shared amounts measured or reused in this run; pass it to the next one.
    public let cache: FootprintCache

    /// Groups measured per round with `limit` (see `measureTop`).
    private static let batchSize = 10

    /// Snapshots, groups and measures all processes of the current user (or of all users).
    ///
    /// Measuring the total is by far the slowest part, as `footprint` has to compare
    /// every process with every other one. With `limit`, only the `limit` largest groups
    /// are returned, and only as many groups are measured as needed to find them.
    ///
    /// `progress` first gets the plain sums of the groups that would be shown (marked
    /// `preliminary`), then each of them again once it is measured. It is called on
    /// background threads.
    public static func measure(
        includeAllUsers: Bool,
        includeTotal: Bool,
        limit: Int? = nil,
        maxConcurrency: Int = ProcessInfo.processInfo.activeProcessorCount,
        qos: QualityOfService = .default,
        cache: FootprintCache? = nil,
        progress: (@Sendable ([AppUsage]) -> Void)? = nil
    ) -> MemoryReport {
        let groups = groupProcesses(ProcessTable.snapshot(), includeAllUsers: includeAllUsers)
        // The kernel's per-process values are cheap. They rank the groups, are checked
        // against the cache and make up the preliminary rows.
        let candidates = groups.map(Candidate.init).filter { !$0.phys.isEmpty }
            .sorted { $0.plainSum > $1.plainSum }
        let shown = min(limit ?? candidates.count, candidates.count)
        progress?(candidates.prefix(shown).map { $0.usage(.plainSum(of: $0.phys), preliminary: true) })

        var newCache = FootprintCache()
        var total: Measurement?
        let measurements = measureTop(candidates, limit: shown, batch: batchSize, bound: \.plainSum,
                                      value: \.bytes) { batch in
            var results = [Measurement?](repeating: nil, count: batch.count)
            var jobs: [[pid_t: UInt64]] = []
            var slots: [Int?] = []  // index into `results`, nil for the total
            if includeTotal, total == nil {
                // The all-PIDs run is the slowest, so it starts first.
                jobs.append(candidates.reduce(into: [:]) { $0.merge($1.phys) { a, _ in a } })
                slots.append(nil)
            }
            let now = ContinuousClock.now
            for (offset, candidate) in batch.enumerated() {
                if let cache, let hit = cache.lookup(candidate.phys, now: now) {
                    results[offset] = hit
                    newCache.keep(candidate.phys, from: cache)
                } else {
                    jobs.append(candidate.phys)
                    slots.append(offset)
                }
            }
            let reported = zip(batch.indices, results).filter { $0.0 < shown && $0.1 != nil }
            if !reported.isEmpty {
                progress?(reported.map { candidates[$0.0].usage($0.1!) })
            }

            let jobSlots = slots
            let start = batch.startIndex
            let measured = parallelMap(jobs, maxConcurrency: maxConcurrency, onResult: { job, measurement in
                guard let slot = jobSlots[job], start + slot < shown else { return }
                progress?([candidates[start + slot].usage(measurement)])
            }) {
                Footprint.measure($0, qos: qos)
            }
            for (job, measurement) in measured.enumerated() {
                if let slot = slots[job] {
                    results[slot] = measurement
                    newCache.store(jobs[job], measurement, at: .now)
                } else {
                    total = measurement
                }
            }
            return results.map { $0! }
        }

        var rows = zip(candidates, measurements)
            .filter { $0.1.processCount > 0 }
            .map { $0.usage($1) }
        if let limit {
            rows = Array(rows.sorted { $0.bytes > $1.bytes }.prefix(limit))
        }
        return MemoryReport(rows: rows, total: total, groupCount: candidates.count, cache: newCache)
    }
}

/// A group with the kernel value (`ri_phys_footprint`) of each of its live processes.
private struct Candidate: Sendable {
    let group: ProcessGroup
    let phys: [pid_t: UInt64]
    let plainSum: UInt64

    init(_ group: ProcessGroup) {
        self.group = group
        phys = Dictionary(uniqueKeysWithValues: group.pids.compactMap { pid in
            ProcessTable.physFootprint(of: pid).map { (pid, $0) }
        })
        plainSum = phys.values.reduce(0, +)
    }

    func usage(_ measurement: Measurement, preliminary: Bool = false) -> AppUsage {
        AppUsage(name: group.name, uid: group.uid, processCount: measurement.processCount, bytes: measurement.bytes,
                 deduplicated: measurement.deduplicated, plainSum: measurement.plainSum,
                 preliminary: preliminary, appPath: group.appPath)
    }
}

extension Measurement {
    static func plainSum(of phys: [pid_t: UInt64]) -> Measurement {
        let sum = phys.values.reduce(0, +)
        return Measurement(bytes: sum, processCount: phys.count, deduplicated: phys.count <= 1, plainSum: sum)
    }
}

/// Measures `ranked` (sorted by `bound`, descending) in rounds of `batch` items until the
/// `limit` largest results are known, and returns the results of the measured prefix.
///
/// A result never exceeds its item's bound (`footprint` only removes shared memory from
/// the plain sum). So once the `limit`-th largest result is at least the bound of the next
/// unmeasured item, no unmeasured item can make it into the top `limit`.
func measureTop<T, R>(
    _ ranked: [T], limit: Int, batch: Int,
    bound: (T) -> UInt64, value: (R) -> UInt64,
    measure: (ArraySlice<T>) -> [R]
) -> [R] {
    guard limit > 0 else { return [] }
    var results: [R] = []
    var end = min(ranked.count, limit + batch)
    while true {
        results += measure(ranked[results.count..<end])
        guard end < ranked.count else { return results }
        let values = results.map(value).sorted(by: >)
        if values[limit - 1] >= bound(ranked[end]) { return results }
        end = min(ranked.count, end + batch)
    }
}

/// Login name of `uid`, or the number if it has no account.
public func userName(of uid: uid_t) -> String {
    getpwuid(uid).map { String(cString: $0.pointee.pw_name) } ?? String(uid)
}

/// Always in MB with one decimal, e.g. "3420.2 MB" / "692.0 MB", with the user's decimal separator.
public func formatBytes(_ bytes: UInt64) -> String {
    let mib = Double(bytes) / 1_048_576
    return mib.formatted(.number.precision(.fractionLength(1)).grouping(.never)) + " MB"
}
