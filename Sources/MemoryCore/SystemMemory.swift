import Darwin
import Foundation

/// Physical memory in use system-wide, as Activity Monitor's "Memory Used": app memory
/// (anonymous minus purgeable pages) + wired + the pages the compressor occupies.
///
/// Every physical page counts once, for all users and the kernel. Compressed memory counts
/// at the RAM it occupies, while `phys_footprint` charges processes its original size, so
/// the rows can add up to more than this.
public struct SystemMemory: Sendable {
    /// The kernel's memory pressure level (`kern.memorystatus_vm_pressure_level`), the
    /// colors of Activity Monitor's "Memory Pressure" graph.
    public enum Pressure: Sendable {
        case normal, warning, critical
    }

    public let used: UInt64
    public let physical: UInt64
    public let pressure: Pressure

    /// Reads the kernel's page counters; nil if that fails.
    public static func current() -> SystemMemory? {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        var pageSize: vm_size_t = 0
        guard result == KERN_SUCCESS, host_page_size(mach_host_self(), &pageSize) == KERN_SUCCESS else { return nil }
        return SystemMemory(stats, pageSize: UInt64(pageSize),
                            physical: ProcessInfo.processInfo.physicalMemory, pressure: currentPressure())
    }

    /// 1 = normal, 2 = warning, 4 = critical; normal if it can't be read.
    private static func currentPressure() -> Pressure {
        var level: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0) == 0 else { return .normal }
        return level >= 4 ? .critical : level >= 2 ? .warning : .normal
    }

    /// `compressor_page_count` is "Pages occupied by compressor" in `vm_stat`: the RAM the
    /// compressed data takes, not its original size. Segments swapped to disk are not in it.
    init(_ stats: vm_statistics64, pageSize: UInt64, physical: UInt64, pressure: Pressure = .normal) {
        let internalPages = UInt64(stats.internal_page_count)
        let purgeable = UInt64(stats.purgeable_count)
        let app = internalPages > purgeable ? internalPages - purgeable : 0
        used = (app + UInt64(stats.wire_count) + UInt64(stats.compressor_page_count)) * pageSize
        self.physical = physical
        self.pressure = pressure
    }
}
