import Darwin
import Foundation
@testable import MemoryCore
import Testing

struct ProcessDetailsTests {
    @Test func readsOwnProcess() throws {
        guard case .running(let path, let arguments) = ProcessDetails(pid: getpid()).state else {
            Issue.record("own process not running")
            return
        }
        #expect(path == Bundle.main.executablePath.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path })
        #expect(try #require(arguments).count == CommandLine.arguments.count)
    }

    @Test func exitedProcess() throws {
        let process = try Process.run(URL(fileURLWithPath: "/usr/bin/true"), arguments: [])
        process.waitUntilExit()
        guard case .exited = ProcessDetails(pid: process.processIdentifier).state else {
            Issue.record("expected an exited process")
            return
        }
    }
}
