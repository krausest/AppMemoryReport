import Darwin
import Foundation

/// Memory of one app or root process with all processes attributed to it.
public struct AppUsage: Identifiable, Sendable {
    public var id: String { name }
    public let name: String
    public let processCount: Int
    public let bytes: UInt64
    /// false if shared memory may be counted more than once (see `Measurement`).
    public let deduplicated: Bool
    /// Outermost `.app` bundle, nil for processes outside any bundle.
    public let appPath: String?
}

public struct MemoryReport: Sendable {
    /// Unsorted, without groups whose processes all exited before measuring.
    public let rows: [AppUsage]
    /// All rows' processes measured together, so memory shared between rows counts once.
    public let total: Measurement?
    /// Number of groups found, including those left out by `limit`.
    public let groupCount: Int

    /// Extra candidates measured beyond `limit`, because deduplication can move a group
    /// past the cut-off of the cheap pre-ranking.
    private static let limitMargin = 10

    /// Snapshots, groups and measures all processes of the current user (or of all users).
    ///
    /// Measuring the total is by far the slowest part, as `footprint` has to compare
    /// every process with every other one. With `limit`, only the largest groups by plain
    /// sum of per-process footprints are measured, and only the `limit` largest are returned.
    public static func measure(
        includeAllUsers: Bool,
        includeTotal: Bool,
        limit: Int? = nil,
        maxConcurrency: Int = ProcessInfo.processInfo.activeProcessorCount,
        qos: QualityOfService = .default
    ) -> MemoryReport {
        var groups = groupProcesses(ProcessTable.snapshot(), includeAllUsers: includeAllUsers)
        let groupCount = groups.count
        guard !groups.isEmpty else { return MemoryReport(rows: [], total: nil, groupCount: 0) }
        if let limit {
            groups = groups
                .map { ($0, $0.pids.compactMap(ProcessTable.physFootprint(of:)).reduce(0, +)) }
                .sorted { $0.1 > $1.1 }
                .prefix(limit + limitMargin)
                .map(\.0)
        }
        // The all-PIDs run is the slowest, so it starts first.
        let pidLists = (includeTotal ? [groups.flatMap(\.pids)] : []) + groups.map(\.pids)
        var measurements = parallelMap(pidLists, maxConcurrency: maxConcurrency) {
            Footprint.measure($0, qos: qos)
        }
        let total = includeTotal ? measurements.removeFirst() : nil
        var rows = zip(groups, measurements)
            .filter { $0.1.processCount > 0 }
            .map { group, m in
                AppUsage(name: group.name, processCount: m.processCount, bytes: m.bytes,
                         deduplicated: m.deduplicated, appPath: group.appPath)
            }
        if let limit {
            rows = Array(rows.sorted { $0.bytes > $1.bytes }.prefix(limit))
        }
        return MemoryReport(rows: rows, total: total, groupCount: groupCount)
    }
}

/// "3.34 GB" / "692 MB", with the user's decimal separator.
public func formatBytes(_ bytes: UInt64) -> String {
    let mib = Double(bytes) / 1_048_576
    return mib >= 1024
        ? (mib / 1024).formatted(.number.precision(.fractionLength(2)).grouping(.never)) + " GB"
        : mib.formatted(.number.precision(.fractionLength(0)).grouping(.never)) + " MB"
}
