import Foundation

private final class ParallelResults<R>: @unchecked Sendable {
    let lock = NSLock()
    var values: [R?]
    var nextIndex = 0
    init(count: Int) { values = Array(repeating: nil, count: count) }
}

/// `map` running at most `maxConcurrency` transforms at a time (default: one per CPU core).
/// Items start in order, so put the slowest ones first. `onResult` is called with each
/// item's index and result as soon as it is done, on the worker's thread.
func parallelMap<T: Sendable, R: Sendable>(
    _ items: [T],
    maxConcurrency: Int = ProcessInfo.processInfo.activeProcessorCount,
    onResult: (@Sendable (Int, R) -> Void)? = nil,
    _ transform: @Sendable (T) -> R
) -> [R] {
    let results = ParallelResults<R>(count: items.count)
    let workers = max(1, min(maxConcurrency, items.count))
    DispatchQueue.concurrentPerform(iterations: workers) { _ in
        while true {
            let index = results.lock.withLock {
                defer { results.nextIndex += 1 }
                return results.nextIndex
            }
            guard index < items.count else { return }
            let value = transform(items[index])
            results.lock.withLock { results.values[index] = value }
            onResult?(index, value)
        }
    }
    return results.values.map { $0! }
}
