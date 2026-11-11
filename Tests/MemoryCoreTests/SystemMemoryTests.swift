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

    @Test func compressionRatioIsOccupiedPerStoredPage() {
        var stats = vm_statistics64()
        stats.compressor_page_count = 278_346
        stats.total_uncompressed_pages_in_compressor = 548_039
        let memory = SystemMemory(stats, pageSize: 16384, physical: 16 << 30)
        #expect(abs(memory.compressionRatio - 278_346.0 / 548_039) < 1e-9)
        #expect(memory.compressorOccupied == 278_346 * 16384)
        #expect(memory.compressorStored == 548_039 * 16384)
        #expect(SystemMemory(vm_statistics64(), pageSize: 16384, physical: 1 << 30).compressionRatio == 1)
    }

    @Test func currentIsPlausible() throws {
        let memory = try #require(SystemMemory.current())
        #expect(memory.used > 0)
        #expect(memory.used <= memory.physical)
    }
}

struct EstimatedRAMTests {
    @Test func countsCompressedPartAtTheRatio() {
        // Mail: 255 MB footprint, 130 MB of it compressed at 2 : 1.
        #expect(estimatedRAM(bytes: 255 << 20, compressed: 130 << 20, compressionRatio: 0.5) == 190 << 20)
        #expect(estimatedRAM(bytes: 100, compressed: 0, compressionRatio: 0.5) == 100)
    }

    @Test func compressedNeverExceedsBytes() {
        // Deduplication can make a row smaller than its processes' compressed sum.
        #expect(estimatedRAM(bytes: 100, compressed: 300, compressionRatio: 0.5) == 50)
    }

    @Test func ownProcessIsReadable() throws {
        let footprint = try #require(ProcessTable.physFootprint(of: getpid()))
        #expect(ProcessTable.compressed(of: getpid()) <= footprint)
    }
}
