import Darwin

/// Remembers how much memory each group's processes share, so an unchanged group can skip
/// `footprint` on the next refresh.
///
/// The shared amount (plain sum − deduplicated total) is reused, not the total: the result
/// then follows the live kernel values. An entry is reused while the group has exactly the
/// same processes, their plain sum moved by at most `tolerance`, and it is younger than
/// `maxAge`.
public struct FootprintCache: Sendable {
    struct Entry: Sendable {
        let plainSum: UInt64
        let shared: UInt64
        let measuredAt: ContinuousClock.Instant
    }

    static let tolerance = 0.02
    static let maxAge = Duration.seconds(300)

    /// Keyed by the sorted PIDs.
    private(set) var entries: [[pid_t]: Entry] = [:]

    public init() {}

    /// The cached measurement for the processes in `phys` (PID → `ri_phys_footprint`).
    func lookup(_ phys: [pid_t: UInt64], now: ContinuousClock.Instant) -> Measurement? {
        guard let entry = entries[phys.keys.sorted()], now - entry.measuredAt < Self.maxAge else { return nil }
        let sum = phys.values.reduce(0, +)
        let change = Double(sum > entry.plainSum ? sum - entry.plainSum : entry.plainSum - sum)
        guard change <= Double(entry.plainSum) * Self.tolerance else { return nil }
        return Measurement(bytes: sum - min(entry.shared, sum), processes: phys, deduplicated: true)
    }

    /// Remembers a `footprint` result; anything else (a plain sum) isn't worth caching.
    /// The shared amount comes from the measurement's own snapshot; the tolerance check
    /// compares against `phys`, the values the next lookup will see.
    mutating func store(_ phys: [pid_t: UInt64], _ measurement: Measurement, at time: ContinuousClock.Instant) {
        guard measurement.deduplicated, phys.count > 1 else { return }
        let shared = measurement.plainSum - min(measurement.bytes, measurement.plainSum)
        entries[phys.keys.sorted()] = Entry(plainSum: phys.values.reduce(0, +), shared: shared, measuredAt: time)
    }

    /// Keeps a reused entry (unchanged) for the next run.
    mutating func keep(_ phys: [pid_t: UInt64], from cache: FootprintCache) {
        let key = phys.keys.sorted()
        entries[key] = cache.entries[key]
    }
}
