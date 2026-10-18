import Darwin
import Foundation

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

/// Shells whose children count as commands the user started (see `Attribution.isTerminalShell`).
private let shellNames: Set<String> = ["zsh", "bash", "sh", "fish", "dash", "ksh", "tcsh", "csh", "nu"]

/// Self-responsible background processes outside an app bundle that belong to an app,
/// added to its group while it runs.
private let satelliteRules: [(bundleID: String, matches: @Sendable (String) -> Bool)] = [
    // Safari's agents (launchd children): bookmarks sync, notifications, history, Safe Browsing.
    ("com.apple.Safari", { path in
        let agents: Set = ["SafariLaunchAgent", "SafariBookmarksSyncAgent", "SafariNotificationAgent",
                           "com.apple.Safari.History"]
        return (path.contains("/usr/libexec/") && agents.contains((path as NSString).lastPathComponent))
            || path.contains("/SafariSafeBrowsing.framework/")
    }),
    // iTerm2's session servers. One from before an update keeps running without a parent.
    ("com.googlecode.iterm2", { $0.contains("/Library/Application Support/iTerm2/iTermServer-") }),
]

/// Groups PIDs into rows with a unique display name.
///
/// Every process is attributed to a root (see `Attribution.resolveRoot`). Roots inside
/// the same `.app` bundle form one group. Some apps additionally get their
/// self-responsible background processes while they run (`satelliteRules`).
///
/// Attribution uses the whole table; afterwards only processes of `uid` (or of all users,
/// if `includeAllUsers`) are kept.
func groupProcesses(
    _ table: [pid_t: ProcessEntry],
    includeAllUsers: Bool,
    uid: uid_t = getuid(),
    appBundle: (String) -> AppBundleInfo? = AppBundleInfo.init(executable:),
    arguments: (pid_t) -> [String]? = ProcessTable.arguments(of:)
) -> [ProcessGroup] {
    var attribution = Attribution(table: table)
    var roots: [pid_t: pid_t] = [:]
    for pid in table.keys {
        roots[pid] = attribution.root(of: pid)
    }

    var rootKeys: [pid_t: GroupKey] = [:]
    var names: [GroupKey: String] = [:]
    var appPaths: [GroupKey: String] = [:]
    for root in Set(roots.values) {
        guard let entry = table[root] else { continue }
        if let app = appBundle(entry.path) {
            rootKeys[root] = .app(bundleID: app.bundleID)
            names[.app(bundleID: app.bundleID)] = app.name
            appPaths[.app(bundleID: app.bundleID)] = app.path
        } else {
            rootKeys[root] = .process(root)
            let command = attribution.isTerminalCommand(root) ? arguments(root).flatMap(commandName) : nil
            names[.process(root)] = command
                ?? (entry.path.isEmpty ? "PID \(root)" : entry.executableName)
        }
    }

    for (root, key) in rootKeys {
        guard case .process = key, let path = table[root]?.path,
              let rule = satelliteRules.first(where: { names[.app(bundleID: $0.bundleID)] != nil && $0.matches(path) })
        else { continue }
        rootKeys[root] = .app(bundleID: rule.bundleID)
    }

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

/// Short display name from a command line: `["/bin/sh", "./build.sh"]` → `sh build.sh`.
/// Empty arguments (left over when a program rewrites its title) are dropped.
func commandName(_ arguments: [String]) -> String? {
    let parts = arguments.enumerated().compactMap { index, argument -> String? in
        guard !argument.isEmpty else { return nil }
        let isPath = index == 0 || argument.hasPrefix("/") || argument.hasPrefix(".")
        return isPath ? (argument as NSString).lastPathComponent : argument
    }
    guard !parts.isEmpty else { return nil }
    let name = parts.joined(separator: " ")
    return name.count > 40 ? name.prefix(39) + "…" : name
}

/// Follows each process to its root, memoizing on the way.
private struct Attribution {
    let table: [pid_t: ProcessEntry]
    private var roots: [pid_t: pid_t] = [:]
    /// Whether a process or one of its ancestors is a shell with a controlling terminal.
    private var underTTYShell: [pid_t: Bool] = [:]

    init(table: [pid_t: ProcessEntry]) {
        self.table = table
    }

    /// Root of `pid`'s attribution chain:
    /// - A command started in a terminal (child of a terminal shell) is a root.
    /// - Otherwise go to the parent if the process is responsible for itself or its
    ///   responsible process is an ancestor anyway, so every ancestor is checked.
    /// - Otherwise jump to the responsible process (e.g. XPC services under launchd).
    /// - A process with neither (launchd child, responsible for itself) is a root.
    mutating func root(of pid: pid_t) -> pid_t {
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
            if isTerminalShell(entry.ppid) {
                root = current
                break
            }
            let parentUsable = entry.ppid > 1 && table[entry.ppid] != nil
            let responsibleUsable = !entry.isSelfResponsible && table[entry.responsiblePID] != nil
            if parentUsable && (!responsibleUsable || isAncestor(entry.responsiblePID, of: current)) {
                current = entry.ppid
            } else if responsibleUsable {
                current = entry.responsiblePID
            } else {
                root = current
                break
            }
        }
        for pid in chain {
            roots[pid] = root
        }
        return root
    }

    /// Whether `pid` was started from a terminal, i.e. its parent is a terminal shell.
    mutating func isTerminalCommand(_ pid: pid_t) -> Bool {
        table[pid].map { isTerminalShell($0.ppid) } ?? false
    }

    /// The topmost shell with a controlling terminal: the shell of a Terminal/iTerm/VS Code
    /// session, not one a command runs (npm's `sh -c`) and not one an app spawns without
    /// a terminal.
    private mutating func isTerminalShell(_ pid: pid_t) -> Bool {
        guard let entry = table[pid], isTTYShell(entry) else { return false }
        return !isUnderTTYShell(entry.ppid)
    }

    private func isTTYShell(_ entry: ProcessEntry) -> Bool {
        entry.hasControllingTTY && shellNames.contains(entry.executableName)
    }

    private mutating func isUnderTTYShell(_ pid: pid_t) -> Bool {
        var chain: [pid_t] = []
        var current = pid
        var result = false
        while current > 1, let entry = table[current], !chain.contains(current) {
            if let known = underTTYShell[current] {
                result = known
                break
            }
            chain.append(current)
            if isTTYShell(entry) {
                result = true
                break
            }
            current = entry.ppid
        }
        for pid in chain {
            underTTYShell[pid] = result
        }
        return result
    }

    private func isAncestor(_ ancestor: pid_t, of pid: pid_t) -> Bool {
        var visited: Set<pid_t> = []
        var current = table[pid]?.ppid ?? 0
        while current > 1, visited.insert(current).inserted, let entry = table[current] {
            if current == ancestor { return true }
            current = entry.ppid
        }
        return false
    }
}
