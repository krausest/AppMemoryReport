import Darwin
@testable import MemoryCore
import Testing

private let me: uid_t = 501

/// Paths treated as app bundles: path → (bundle ID, name).
private let bundles: [String: (String, String)] = [
    "/Applications/Safari.app": ("com.apple.Safari", "Safari"),
    "/Applications/Google Chrome.app": ("com.google.Chrome", "Google Chrome"),
    "/Applications/Google Chrome.app/Contents/Frameworks/Helper.app": ("com.google.Chrome.helper", "Helper"),
    "/Applications/Utilities/Terminal.app": ("com.apple.Terminal", "Terminal"),
    "/Applications/iTerm.app": ("com.googlecode.iterm2", "iTerm2"),
    "/Applications/Visual Studio Code.app": ("com.microsoft.VSCode", "Code"),
    "/Applications/Notes.app": ("com.apple.Notes", "Notes"),
    "/Users/me/Apps/Notes.app": ("com.example.notes", "Notes"),
]

private func appBundle(_ path: String) -> AppBundleInfo? {
    outermostAppPath(forExecutable: path, isBundle: { bundles[$0] != nil }).map {
        AppBundleInfo(bundleID: bundles[$0]!.0, name: bundles[$0]!.1, path: $0)
    }
}

private func process(_ pid: pid_t, _ path: String, ppid: pid_t = 1, responsible: pid_t? = nil,
                     uid: uid_t = me, tty: Bool = false) -> ProcessEntry {
    ProcessEntry(pid: pid, ppid: ppid, responsiblePID: responsible ?? pid, uid: uid, path: path,
                 hasControllingTTY: tty)
}

/// Row name → PIDs.
private func group(_ entries: [ProcessEntry], allUsers: Bool = false,
                   arguments: [pid_t: [String]] = [:]) -> [String: Set<pid_t>] {
    let table = Dictionary(uniqueKeysWithValues: entries.map { ($0.pid, $0) })
    let groups = groupProcesses(table, includeAllUsers: allUsers, uid: me, appBundle: appBundle,
                                arguments: { arguments[$0] })
    return Dictionary(uniqueKeysWithValues: groups.map { ($0.name, Set($0.pids)) })
}

private let safari = process(100, "/Applications/Safari.app/Contents/MacOS/Safari")
private let terminal = process(300, "/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal")
private let iTerm = process(600, "/Applications/iTerm.app/Contents/MacOS/iTerm2")

struct GroupingTests {
    @Test func xpcServiceUnderLaunchdFollowsResponsibility() {
        let webContent = process(101, "/System/Library/Frameworks/WebKit.framework/XPCServices/WebContent",
                                 responsible: 100)
        #expect(group([safari, webContent]) == ["Safari": [100, 101]])
    }

    @Test func nestedHelperAppsCountTowardOutermostBundle() {
        let chrome = process(200, "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome")
        let helper = "/Applications/Google Chrome.app/Contents/Frameworks/Helper.app/Contents/MacOS/Helper"
        let gpu = process(201, helper, ppid: 200, responsible: 200)
        let renderer = process(202, helper, ppid: 201, responsible: 200)
        #expect(group([chrome, gpu, renderer]) == ["Google Chrome": [200, 201, 202]])
    }

    /// Terminal → login → zsh → npm → node, all responsible to Terminal: the command is a root,
    /// the shell stays with Terminal, and the root-owned login is filtered out after attribution.
    @Test func terminalCommandIsRoot() {
        let entries = [
            terminal,
            process(301, "/usr/bin/login", ppid: 300, uid: 0, tty: true),
            process(302, "/bin/zsh", ppid: 301, responsible: 300, tty: true),
            process(303, "/opt/homebrew/bin/node", ppid: 302, responsible: 300, tty: true),
            process(304, "/opt/homebrew/bin/node", ppid: 303, responsible: 300, tty: true),
        ]
        let arguments: [pid_t: [String]] = [303: ["npm run dev", "", ""]]
        #expect(group(entries, arguments: arguments) == ["Terminal": [300, 302], "npm run dev": [303, 304]])
        #expect(group(entries, allUsers: true, arguments: arguments)["Terminal"] == [300, 301, 302])
    }

    /// npm runs scripts with `sh -c`: only the topmost shell counts, so the script stays one row.
    @Test func shellsBelowTheTerminalShellDontSplit() {
        let entries = [
            terminal,
            process(401, "/usr/bin/login", ppid: 300, uid: 0, tty: true),
            process(402, "/bin/zsh", ppid: 401, tty: true),
            process(403, "/bin/sh", ppid: 402, tty: true),
            process(404, "/opt/homebrew/bin/node", ppid: 403, tty: true),
            process(405, "/bin/sh", ppid: 404, tty: true),
            process(406, "/opt/homebrew/bin/node", ppid: 405, tty: true),
        ]
        let groups = group(entries, arguments: [403: ["sh", "./build.sh"]])
        #expect(groups["sh build.sh"] == [403, 404, 405, 406])
    }

    /// An app running a command through a shell without a terminal keeps it.
    @Test func shellWithoutTTYDoesNotSplit() {
        let entries = [
            process(500, "/Applications/Visual Studio Code.app/Contents/MacOS/Code"),
            process(501, "/Applications/Visual Studio Code.app/Contents/Frameworks/Plugin", ppid: 500,
                    responsible: 500),
            process(502, "/bin/zsh", ppid: 501, responsible: 500),
            process(503, "/usr/bin/git", ppid: 502, responsible: 500),
        ]
        #expect(group(entries) == ["Code": [500, 501, 502, 503]])
    }

    @Test func orphanedITermServerJoinsITerm() {
        let entries = [
            iTerm,
            process(610, "/Users/me/Library/Application Support/iTerm2/iTermServer-3.7.3"),
            process(611, "/usr/bin/login", ppid: 610, uid: 0, tty: true),
            process(612, "/bin/zsh", ppid: 611, tty: true),
            process(613, "/usr/bin/vi", ppid: 612, tty: true),
        ]
        let arguments: [pid_t: [String]] = [613: ["vi", "TODO.txt"]]
        #expect(group(entries, arguments: arguments) == ["iTerm2": [600, 610, 612], "vi TODO.txt": [613]])
        #expect(group(Array(entries.dropFirst()), arguments: arguments)["iTermServer-3.7.3"] == [610, 612])
    }

    @Test func safariAgentsJoinSafariWhileItRuns() {
        let agents = [
            process(120, "/System/Volumes/Preboot/Cryptexes/App/usr/libexec/SafariBookmarksSyncAgent"),
            process(121, "/System/Library/PrivateFrameworks/SafariSafeBrowsing.framework/Versions/A/"
                    + "com.apple.Safari.SafeBrowsing.Service"),
        ]
        let credentialHelper = process(
            130, "/System/Library/PrivateFrameworks/SafariFoundation.framework/Versions/A/XPCServices/"
                + "CredentialProviderExtensionHelper.xpc/Contents/MacOS/CredentialProviderExtensionHelper")
        let groups = group([safari, credentialHelper] + agents)
        #expect(groups["Safari"] == [100, 120, 121])
        #expect(groups["CredentialProviderExtensionHelper"] == [130])
        #expect(group(agents)["SafariBookmarksSyncAgent"] == [120])
    }

    @Test func cyclesTerminate() {
        let entries = [
            process(700, "/usr/bin/a", ppid: 701),
            process(701, "/usr/bin/b", ppid: 700),
            process(710, "/usr/bin/c", responsible: 711),
            process(711, "/usr/bin/d", responsible: 710),
        ]
        let pids = group(entries).values.reduce(into: Set<pid_t>()) { $0.formUnion($1) }
        #expect(pids == [700, 701, 710, 711])
    }

    @Test func collidingNamesAreDisambiguated() {
        let entries = [
            process(801, "/usr/local/bin/node"),
            process(802, "/opt/homebrew/bin/node"),
            process(803, "/Applications/Notes.app/Contents/MacOS/Notes"),
            process(804, "/Users/me/Apps/Notes.app/Contents/MacOS/Notes"),
        ]
        #expect(Set(group(entries).keys)
            == ["node [801]", "node [802]", "Notes (com.apple.Notes)", "Notes (com.example.notes)"])
    }

    @Test func outermostAppPathSkipsDirectoriesThatArentBundles() {
        let isBundle: (String) -> Bool = { $0.hasSuffix("/Real.app") || $0.hasSuffix("/Inner.app") }
        #expect(outermostAppPath(forExecutable: "/Users/me/my.app/Real.app/Contents/Inner.app/Contents/MacOS/x",
                                 isBundle: isBundle) == "/Users/me/my.app/Real.app")
        #expect(outermostAppPath(forExecutable: "/Users/me/my.app/tool", isBundle: isBundle) == nil)
    }

    @Test func commandNames() {
        #expect(commandName(["npm run dev", "", ""]) == "npm run dev")
        #expect(commandName(["/bin/sh", "./build.sh", "-v"]) == "sh build.sh -v")
        #expect(commandName(["vi", "/etc/hosts"]) == "vi hosts")
        #expect(commandName(["", ""]) == nil)
        #expect(commandName(["tool", String(repeating: "x", count: 50)])?.count == 40)
    }
}
