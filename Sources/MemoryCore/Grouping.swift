import Darwin
import Foundation

private let safariBundleID = "com.apple.Safari"

private enum GroupKey: Hashable {
    /// All roots inside the same outermost `.app` bundle.
    case app(bundleID: String)
    /// A single root process outside any app bundle.
    case process(pid_t)
}

/// One output row: the processes attributed to an app or root process.
public struct ProcessGroup: Sendable {
    /// Display name, unique among the groups of one `groupProcesses` call.
    public let name: String
    public let pids: [pid_t]
    /// Outermost `.app` bundle of the group, nil for processes outside any bundle.
    public let appPath: String?
}

/// Groups PIDs into rows with a unique display name.
///
/// Every process is attributed to a root: follow the responsible PID, otherwise the
/// parent, until a process is responsible for itself and was started by launchd.
/// Roots inside the same `.app` bundle form one group. Safari additionally gets its
/// self-responsible background agents (bookmarks sync, safe browsing, history, …)
/// while it runs.
///
/// Attribution uses the whole table; afterwards only processes of the current user
/// (or of all users, if `includeAllUsers`) are kept.
func groupProcesses(_ table: [pid_t: ProcessEntry], includeAllUsers: Bool) -> [ProcessGroup] {
    var roots: [pid_t: pid_t] = [:]
    for pid in table.keys {
        resolveRoot(of: pid, table, &roots)
    }

    var rootKeys: [pid_t: GroupKey] = [:]
    var names: [GroupKey: String] = [:]
    var appPaths: [GroupKey: String] = [:]
    for root in Set(roots.values) {
        guard let entry = table[root] else { continue }
        if let bundleID = outermostAppBundleID(forExecutable: entry.path) {
            rootKeys[root] = .app(bundleID: bundleID)
            names[.app(bundleID: bundleID)] = outermostAppName(forExecutable: entry.path) ?? bundleID
            appPaths[.app(bundleID: bundleID)] = outermostAppPath(forExecutable: entry.path)
        } else {
            rootKeys[root] = .process(root)
            names[.process(root)] = entry.path.isEmpty
                ? "PID \(root)" : URL(fileURLWithPath: entry.path).lastPathComponent
        }
    }

    let safari = GroupKey.app(bundleID: safariBundleID)
    if names[safari] != nil {
        for (root, key) in rootKeys where table[root]?.path.contains("Safari") == true {
            if case .process = key {
                rootKeys[root] = safari
            }
        }
    }

    let uid = getuid()
    var groups: [GroupKey: [pid_t]] = [:]
    for entry in table.values where includeAllUsers || entry.uid == uid {
        if let root = roots[entry.pid], let key = rootKeys[root] {
            groups[key, default: []].append(entry.pid)
        }
    }

    // Disambiguate rows that would share a name, e.g. two unrelated `node` daemons.
    var nameCounts: [String: Int] = [:]
    for key in groups.keys {
        nameCounts[names[key]!, default: 0] += 1
    }
    return groups.map { key, pids in
        var name = names[key]!
        if nameCounts[name]! > 1 {
            switch key {
            case .app(let bundleID): name += " (\(bundleID))"
            case .process(let pid): name += " [\(pid)]"
            }
        }
        return ProcessGroup(name: name, pids: pids, appPath: appPaths[key])
    }
}

/// Root of `pid`'s attribution chain; memoizes the root for every process on the way.
private func resolveRoot(of pid: pid_t, _ table: [pid_t: ProcessEntry], _ roots: inout [pid_t: pid_t]) {
    var chain: [pid_t] = []
    var visited: Set<pid_t> = []
    var current = pid
    var root: pid_t
    while true {
        if let known = roots[current] {
            root = known
            break
        }
        guard visited.insert(current).inserted, let entry = table[current] else {
            root = current
            break
        }
        chain.append(current)
        if !entry.isSelfResponsible, table[entry.responsiblePID] != nil {
            current = entry.responsiblePID
        } else if entry.ppid > 1, table[entry.ppid] != nil {
            current = entry.ppid
        } else {
            root = current
            break
        }
    }
    for pid in chain {
        roots[pid] = root
    }
}
