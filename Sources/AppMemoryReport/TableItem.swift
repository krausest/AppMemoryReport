import Foundation
import MemoryCore

/// A row of the table: an app, or one of its processes below it. A hierarchical `Table`
/// needs one type for both.
struct TableItem: Identifiable {
    /// `AppUsage.id` for an app, extended by the PID for a process.
    let id: String
    /// The app row this item belongs to (itself for an app).
    let appID: AppUsage.ID
    let name: String
    let uid: uid_t
    /// Whether this is a process row below an app.
    let isProcess: Bool
    /// The app's processes; 0 for a process row.
    let processCount: Int
    /// The app's (deduplicated) memory or the process's `phys_footprint`; 0 if unknown.
    let bytes: UInt64
    /// false for a process that exited before it was measured.
    let measured: Bool
    let preliminary: Bool
    let deduplicated: Bool
    /// The app's Shared value; 0 for a process row.
    let shared: UInt64
    let appPath: String?
    /// Why the process belongs to the app; empty for an app row.
    let attribution: String
    /// nil if there is nothing to expand.
    var children: [TableItem]?

    var userName: String { MemoryCore.userName(of: uid) }

    init(_ app: AppUsage) {
        id = app.id
        appID = app.id
        name = app.name
        uid = app.uid
        isProcess = false
        processCount = app.processCount
        bytes = app.bytes
        measured = true
        preliminary = app.preliminary
        deduplicated = app.deduplicated
        shared = app.shared
        appPath = app.appPath
        attribution = ""
        // A single process is the row itself.
        children = app.processes.count > 1 ? app.processTree.map { TableItem($0, of: app) } : nil
    }

    private init(_ node: ProcessNode, of app: AppUsage) {
        let process = node.process
        id = "\(app.id)/\(process.pid)"
        appID = app.id
        name = "\(process.name) [\(process.pid)]"
        uid = process.uid
        isProcess = true
        processCount = 0
        bytes = process.bytes ?? 0
        measured = process.bytes != nil
        preliminary = false
        deduplicated = true
        shared = 0
        appPath = nil
        attribution = process.attribution.label
        children = node.children.isEmpty ? nil : node.children.map { TableItem($0, of: app) }
    }

    /// Sorted, with the children of every level sorted the same way.
    static func sorted(_ items: [TableItem], using order: [KeyPathComparator<TableItem>]) -> [TableItem] {
        items.sorted(using: order).map { item in
            var item = item
            item.children = item.children.map { sorted($0, using: order) }
            return item
        }
    }

    /// Whether the item or one of its processes matches a search.
    func matches(_ search: String, includingUser: Bool) -> Bool {
        name.localizedCaseInsensitiveContains(search)
            || includingUser && userName.localizedCaseInsensitiveContains(search)
            || (children ?? []).contains { $0.matches(search, includingUser: includingUser) }
    }
}

extension ProcessAttribution {
    var label: String {
        switch self {
        case .appBundle: localized("In the app bundle")
        case .independent: localized("Independent process")
        case .terminalCommand: localized("Started in a terminal")
        case .satellite: localized("Belongs to the app (built-in rule)")
        case .parent(let pid, let name): localized("Child process of \(name) [\(Int(pid))]")
        case .responsible(let pid, let name): localized("\(name) [\(Int(pid))] is responsible")
        }
    }
}
