import Darwin
@testable import MemoryCore
import Testing

struct SystemMemoryTests {
    @Test func sumsAppWiredAndCompressorPages() {
        var stats = vm_statistics64()
        stats.internal_page_count = 286_923
        stats.purgeable_count = 10_886
        stats.wire_count = 297_149
        stats.compressor_page_count = 222_252
        stats.total_uncompressed_pages_in_compressor = 467_357  // not counted
        let memory = SystemMemory(stats, pageSize: 16384, physical: 16 << 30)
        #expect(memory.used == (286_923 - 10_886 + 297_149 + 222_252) * 16384)
        #expect(memory.physical == 16 << 30)
    }

    @Test func purgeableBeyondAnonymousDoesNotUnderflow() {
        var stats = vm_statistics64()
        stats.internal_page_count = 5
        stats.purgeable_count = 10
        stats.wire_count = 3
        let memory = SystemMemory(stats, pageSize: 4096, physical: 1 << 30)
        #expect(memory.used == 3 * 4096)
    }

    @Test func currentIsPlausible() throws {
        let memory = try #require(SystemMemory.current())
        #expect(memory.used > 0)
        #expect(memory.used <= memory.physical)
    }
}
