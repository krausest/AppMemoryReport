import Darwin
@testable import MemoryCore
import Testing

private func usage(_ processes: [(pid_t, ProcessAttribution)]) -> AppUsage {
    AppUsage(name: "App", uid: 501, processCount: processes.count, bytes: 0, deduplicated: true, plainSum: 0,
             preliminary: false, appPath: nil,
             processes: processes.map {
                 ProcessUsage(pid: $0.0, name: "p\($0.0)", uid: 501, attribution: $0.1, bytes: 1)
             })
}

/// The tree as "pid(children…)" strings, in input order.
private func shape(_ nodes: [ProcessNode]) -> [String] {
    nodes.map { node in
        let children = shape(node.children)
        return children.isEmpty ? "\(node.process.pid)" : "\(node.process.pid)(\(children.joined(separator: " ")))"
    }
}

struct ProcessTreeTests {
    @Test func nestsAlongAttribution() {
        let row = usage([
            (1, .appBundle),
            (2, .parent(pid: 1, name: "p1")),
            (3, .parent(pid: 2, name: "p2")),
            (4, .responsible(pid: 1, name: "p1")),
        ])
        #expect(shape(row.processTree) == ["1(2(3) 4)"])
    }

    /// The process attributed through isn't in the row (another user's `login`): top level.
    @Test func viaOutsideTheRowIsTopLevel() {
        let row = usage([(1, .appBundle), (2, .parent(pid: 99, name: "login"))])
        #expect(shape(row.processTree) == ["1", "2"])
    }

    @Test func cyclesKeepAllProcesses() {
        let row = usage([(1, .parent(pid: 2, name: "p2")), (2, .parent(pid: 1, name: "p1"))])
        let tree = row.processTree
        #expect(tree.count == 1)
        #expect(Set(shape(tree)) == ["1(2)"] || Set(shape(tree)) == ["2(1)"])
    }
}
