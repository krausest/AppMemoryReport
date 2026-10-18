import Darwin
import Foundation
@testable import MemoryCore
import Testing

private let mib: UInt64 = 1 << 20

private func report(_ processes: [(pid: Int, footprint: Int, phys: Int)], total: Int) -> Data {
    let json: [String: Any] = [
        "total footprint": total,
        "processes": processes.map {
            ["pid": $0.pid, "footprint": $0.footprint, "auxiliary": ["phys_footprint": $0.phys]]
        },
    ]
    return try! JSONSerialization.data(withJSONObject: json)
}

struct FootprintTests {
    @Test func addsKernelExcessToDeduplicatedTotal() throws {
        let data = report([(1, 100, 100), (2, 50, 80)], total: 120)
        let measurement = try #require(Footprint.parseReport(data, requested: [1, 2]))
        #expect(measurement.bytes == 150)
        #expect(measurement.processCount == 2)
        #expect(measurement.deduplicated)
    }

    @Test func neverExceedsThePlainSum() throws {
        let data = report([(1, 100, 60), (2, 50, 50)], total: 140)
        #expect(try #require(Footprint.parseReport(data, requested: [1, 2])).bytes == 110)
    }

    @Test func unrequestedProcessesFallBackToPlainSum() throws {
        let data = report([(1, 100, 100), (3, 50, 50)], total: 120)
        let measurement = try #require(Footprint.parseReport(data, requested: [1, 2]))
        #expect(measurement.bytes == 100)
        #expect(measurement.processCount == 1)
        #expect(!measurement.deduplicated)
    }

    @Test func malformedReport() {
        #expect(Footprint.parseReport(Data("{}".utf8), requested: [1]) == nil)
    }

    @Test func singleOrExitedProcessesNeedNoFootprint() {
        let single = Footprint.measure([1: 5 * mib])
        #expect(single.bytes == 5 * mib && single.processCount == 1 && single.deduplicated)
        #expect(Footprint.measure([:]).processCount == 0)
    }

    /// Everything but the largest process is ≤ 1 MiB (or ≤ 1 %): footprint is skipped.
    @Test func skipsFootprintWhenLittleCanBeShared() {
        let small = Footprint.measure([1: 500 * mib, 2: mib / 2, 3: mib / 4])
        #expect(small.bytes == 500 * mib + mib / 2 + mib / 4)
        #expect(small.processCount == 3)
        #expect(!small.deduplicated)
        #expect(!Footprint.measure([1: 1000 * mib, 2: 9 * mib]).deduplicated)
    }
}

struct MeasureTopTests {
    /// The two largest by bound shrink a lot, so the cut-off moves and another round runs.
    @Test func measuresMoreWhenGroupsShrinkBelowTheCutOff() {
        let bounds: [UInt64] = [100, 90, 80, 70, 60, 50]
        var rounds: [Range<Int>] = []
        let results = measureTop(Array(bounds.indices), limit: 2, batch: 1, bound: { bounds[$0] },
                                 value: { $0 }) { slice in
            rounds.append(slice.indices)
            return slice.map { $0 < 2 ? 10 : bounds[$0] }
        }
        #expect(rounds == [0..<3, 3..<4])
        #expect(results == [10, 10, 80, 70])
    }

    @Test func measuresEverythingAtOnceWithoutLimit() {
        var calls = 0
        let results = measureTop([5, 4, 3], limit: 3, batch: 10, bound: { UInt64($0) }, value: { $0 }) {
            calls += 1
            return $0.map { UInt64($0) }
        }
        #expect(calls == 1)
        #expect(results == [5, 4, 3])
    }
}

struct FootprintCacheTests {
    private let phys: [pid_t: UInt64] = [1: 100 * mib, 2: 100 * mib]
    private let now = ContinuousClock.now

    private func filled() -> FootprintCache {
        var cache = FootprintCache()
        cache.store(phys, Measurement(bytes: 150 * mib, processCount: 2, deduplicated: true), at: now)
        return cache
    }

    @Test func reusesSharedAmountForLiveSum() throws {
        let hit = try #require(filled().lookup([1: 101 * mib, 2: 101 * mib], now: now))
        #expect(hit.bytes == 152 * mib)
        #expect(hit.deduplicated)
    }

    @Test func missesWhenSumMovedTooMuchProcessesChangedOrEntryIsOld() {
        let cache = filled()
        #expect(cache.lookup([1: 105 * mib, 2: 105 * mib], now: now) == nil)
        #expect(cache.lookup([1: 100 * mib, 3: 100 * mib], now: now) == nil)
        #expect(cache.lookup(phys, now: now + .seconds(301)) == nil)
    }

    @Test func storesOnlyFootprintResults() {
        var cache = FootprintCache()
        cache.store(phys, Measurement(bytes: 200 * mib, processCount: 2, deduplicated: false), at: now)
        #expect(cache.lookup(phys, now: now) == nil)
    }

    @Test func keepCarriesEntryOver() {
        var next = FootprintCache()
        next.keep(phys, from: filled())
        #expect(next.lookup(phys, now: now)?.bytes == 150 * mib)
    }
}
