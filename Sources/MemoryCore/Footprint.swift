import Darwin
import Foundation

public struct Measurement: Sendable {
    public let bytes: UInt64
    public let processCount: Int
    /// true if shared memory between the processes is counted only once (via `footprint`).
    public let deduplicated: Bool
    /// Sum of the per-process `phys_footprint` this measurement is based on (from the same
    /// snapshot as `bytes`, so `plainSum - bytes` is the memory deduplication removed).
    public let plainSum: UInt64
}

/// Measures groups of PIDs with `/usr/bin/footprint`.
///
/// `footprint`'s "total footprint" counts memory shared between the given processes only
/// once. It sums the memory regions it can see, though, while the kernel's
/// `phys_footprint` (`ri_phys_footprint`, Activity Monitor's "Memory") also charges memory
/// that doesn't show up as dirty there. For example, OrbStack's helper maps its VM disk
/// image, and gigabytes of it count as clean file pages for `footprint`, but as footprint
/// for the kernel. That excess is added per process, so the result matches `phys_footprint`.
enum Footprint {
    private static let executable = URL(fileURLWithPath: "/usr/bin/footprint")

    /// Measures the processes in `phys` (PID → `ri_phys_footprint`; exited processes are
    /// left out) with `footprint`, or falls back to the plain sum.
    static func measure(_ phys: [pid_t: UInt64], qos: QualityOfService = .default) -> Measurement {
        let sum = phys.values.reduce(0, +)
        // Nothing is shared within a single process, so the kernel value is all we need.
        if phys.count <= 1 {
            return Measurement(bytes: sum, processCount: phys.count, deduplicated: true, plainSum: sum)
        }
        // At most everything but the largest process could be shared. If that is small,
        // running footprint isn't worth it; the row is marked as not deduplicated.
        if sum - phys.values.max()! <= max(1 << 20, sum / 100) {
            return Measurement(bytes: sum, processCount: phys.count, deduplicated: false, plainSum: sum)
        }
        let plainSum = Measurement(bytes: sum, processCount: phys.count, deduplicated: false, plainSum: sum)

        let jsonURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("app-memory-report-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: jsonURL) }

        let pids = phys.keys.sorted()
        let process = Process()
        process.executableURL = executable
        process.arguments = ["--noCategories", "-f", "bytes", "-j", jsonURL.path]
            + pids.flatMap { ["-p", String($0)] }
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.qualityOfService = qos
        guard (try? process.run()) != nil else { return plainSum }
        process.waitUntilExit()

        guard process.terminationStatus == 0, let data = try? Data(contentsOf: jsonURL) else { return plainSum }
        return parseReport(data, requested: pids) ?? plainSum
    }

    static func parseReport(_ data: Data, requested pids: [pid_t]) -> Measurement? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let processes = json["processes"] as? [[String: Any]],
              let total = (json["total footprint"] as? NSNumber)?.uint64Value
        else { return nil }

        // Per PID: the kernel's phys_footprint, and how much it exceeds footprint's own value.
        var perProcess: [pid_t: UInt64] = [:]
        var excess: [pid_t: UInt64] = [:]
        for entry in processes {
            if let pid = (entry["pid"] as? NSNumber)?.int32Value,
               let bytes = (entry["footprint"] as? NSNumber)?.uint64Value {
                let auxiliary = entry["auxiliary"] as? [String: Any]
                let phys = (auxiliary?["phys_footprint"] as? NSNumber)?.uint64Value ?? bytes
                perProcess[pid] = phys
                excess[pid] = phys > bytes ? phys - bytes : 0
            }
        }

        // footprint treats a PID it cannot find (process exited meanwhile) as a partial
        // process *name* and may add unrelated processes. Then the deduplicated total
        // is unusable, so fall back to the plain sum of the requested processes.
        let requested = Set(pids)
        if !Set(perProcess.keys).isSubset(of: requested) {
            let own = perProcess.filter { requested.contains($0.key) }
            let sum = own.values.reduce(0, +)
            return Measurement(bytes: sum, processCount: own.count, deduplicated: false, plainSum: sum)
        }
        // The excess isn't deduplicated, so cap the result at the plain sum. That also
        // guarantees a group never measures more than the sum it was ranked by.
        let sum = perProcess.values.reduce(0, +)
        let bytes = min(total + excess.values.reduce(0, +), sum)
        return Measurement(bytes: bytes, processCount: perProcess.count, deduplicated: true, plainSum: sum)
    }
}
