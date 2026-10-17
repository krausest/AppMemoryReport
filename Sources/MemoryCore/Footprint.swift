import Darwin
import Foundation

public struct Measurement: Sendable {
    public let bytes: UInt64
    public let processCount: Int
    /// true if shared memory between the processes is counted only once (via `footprint`).
    public let deduplicated: Bool
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

    /// Runs `footprint` for `pids` and waits for it, or falls back to the rusage-based sum.
    static func measure(_ pids: [pid_t], qos: QualityOfService = .default) -> Measurement {
        // Nothing is shared within a single process, so the kernel value is all we need.
        if pids.count == 1 {
            let bytes = ProcessTable.physFootprint(of: pids[0])
            return Measurement(bytes: bytes ?? 0, processCount: bytes == nil ? 0 : 1, deduplicated: true)
        }

        let jsonURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("app-memory-report-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: jsonURL) }

        let process = Process()
        process.executableURL = executable
        process.arguments = ["--noCategories", "-f", "bytes", "-j", jsonURL.path]
            + pids.flatMap { ["-p", String($0)] }
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.qualityOfService = qos
        guard (try? process.run()) != nil else { return rusageSum(of: pids) }
        process.waitUntilExit()

        guard process.terminationStatus == 0 else { return rusageSum(of: pids) }
        return parseReport(at: jsonURL, requested: pids) ?? rusageSum(of: pids)
    }

    private static func parseReport(at jsonURL: URL, requested pids: [pid_t]) -> Measurement? {
        guard let data = try? Data(contentsOf: jsonURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
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
                perProcess[pid] = max(phys, bytes)
                excess[pid] = phys > bytes ? phys - bytes : 0
            }
        }

        // footprint treats a PID it cannot find (process exited meanwhile) as a partial
        // process *name* and may add unrelated processes. Then the deduplicated total
        // is unusable, so fall back to the plain sum of the requested processes.
        let requested = Set(pids)
        if !Set(perProcess.keys).isSubset(of: requested) {
            let own = perProcess.filter { requested.contains($0.key) }
            return Measurement(bytes: own.values.reduce(0, +), processCount: own.count, deduplicated: false)
        }
        return Measurement(bytes: total + excess.values.reduce(0, +), processCount: perProcess.count,
                           deduplicated: true)
    }

    private static func rusageSum(of pids: [pid_t]) -> Measurement {
        let values = pids.compactMap(ProcessTable.physFootprint(of:))
        return Measurement(bytes: values.reduce(0, +), processCount: values.count, deduplicated: false)
    }
}
