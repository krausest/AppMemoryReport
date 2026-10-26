import Darwin
import Foundation
@testable import MemoryCore
import Testing

struct HelperTests {
    /// Runs the helper in-process as the current user and measures through the socket.
    @Test func measuresThroughSocket() throws {
        let connection = try HelperConnection.accept(peerUID: getuid()) { socketPath in
            Thread.detachNewThread { _ = serveHelper(socketPath: socketPath) }
        }
        var progressRows = 0
        let result = try connection.measure(limit: 2) { progressRows += $0.count }
        #expect(result.rows.count == 2)
        #expect(result.groupCount >= 2)
        #expect(progressRows >= 2)
        for row in result.rows {
            #expect(row.processes.count >= row.processCount)
            #expect(row.processes.compactMap(\.bytes).reduce(0, +) == row.plainSum)
        }
    }

    @Test func rejectsOtherUsers() {
        #expect(throws: HelperError.self) {
            try HelperConnection.accept(peerUID: getuid() + 1) { socketPath in
                Thread.detachNewThread { _ = serveHelper(socketPath: socketPath) }
            }
        }
    }
}
