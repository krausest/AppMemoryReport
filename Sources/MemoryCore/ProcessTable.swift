import Darwin
import Foundation

// Private libSystem API (used by Activity Monitor): returns the PID macOS holds
// "responsible" for a process, e.g. Safari for its WebKit XPC services.
@_silgen_name("responsibility_get_pid_responsible_for_pid")
private func responsibility_get_pid_responsible_for_pid(_ pid: pid_t) -> pid_t

struct ProcessEntry {
    let pid: pid_t
    let ppid: pid_t
    let responsiblePID: pid_t
    let uid: uid_t
    let path: String
    /// The process has a controlling terminal (interactive shells and what they start).
    var hasControllingTTY = false

    var isSelfResponsible: Bool { responsiblePID == pid }
    var executableName: String { (path as NSString).lastPathComponent }
}

enum ProcessTable {
    /// Snapshot of all processes visible to the current user.
    static func snapshot() -> [pid_t: ProcessEntry] {
        var table: [pid_t: ProcessEntry] = [:]
        for pid in allPIDs() where pid > 0 {
            guard let info = bsdInfo(of: pid) else { continue }
            let responsible = responsibility_get_pid_responsible_for_pid(pid)
            table[pid] = ProcessEntry(
                pid: pid,
                ppid: info.ppid,
                responsiblePID: responsible > 0 ? responsible : pid,
                uid: info.uid,
                path: executablePath(of: pid) ?? "",
                hasControllingTTY: info.flags & UInt32(PROC_FLAG_CTTY) != 0
            )
        }
        return table
    }

    /// Physical footprint as reported by the kernel (same value as Activity Monitor's "Memory").
    static func physFootprint(of pid: pid_t) -> UInt64? {
        var info = rusage_info_v4()
        let result = withUnsafeMutablePointer(to: &info) { ptr in
            ptr.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_V4, $0)
            }
        }
        return result == 0 ? info.ri_phys_footprint : nil
    }

    /// Command line (`argv`) of `pid`. Programs can rewrite it, e.g. npm shows up as
    /// `["npm run dev", "", ""]` instead of `node …/npm-cli.js run dev`.
    static func arguments(of pid: pid_t) -> [String]? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
        // Layout: argc, executable path, NUL padding, then argc NUL-terminated arguments.
        let argc = buffer.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
        var index = MemoryLayout<Int32>.size
        while index < size, buffer[index] != 0 { index += 1 }
        while index < size, buffer[index] == 0 { index += 1 }
        var arguments: [String] = []
        while arguments.count < argc, index < size {
            let start = index
            while index < size, buffer[index] != 0 { index += 1 }
            arguments.append(String(decoding: buffer[start..<index], as: UTF8.self))
            index += 1
        }
        return arguments
    }

    private static func allPIDs() -> [pid_t] {
        let estimate = proc_listallpids(nil, 0)
        guard estimate > 0 else { return [] }
        // Leave headroom for processes spawned between the two calls.
        var pids = [pid_t](repeating: 0, count: Int(estimate) + 128)
        let count = pids.withUnsafeMutableBytes {
            proc_listallpids($0.baseAddress, Int32($0.count))
        }
        return count > 0 ? Array(pids.prefix(Int(count))) : []
    }

    private static func bsdInfo(of pid: pid_t) -> (ppid: pid_t, uid: uid_t, flags: UInt32)? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        if proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size {
            return (pid_t(info.pbi_ppid), info.pbi_uid, info.pbi_flags)
        }
        // Without root, other users' processes (e.g. the setuid `login` between a terminal
        // and its shell) refuse the full info, but the short one is enough here.
        var short = proc_bsdshortinfo()
        let shortSize = Int32(MemoryLayout<proc_bsdshortinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDT_SHORTBSDINFO, 0, &short, shortSize) == shortSize else { return nil }
        return (pid_t(short.pbsi_ppid), short.pbsi_uid, short.pbsi_flags)
    }

    private static func executablePath(of pid: pid_t) -> String? {
        var buffer = [UInt8](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(decoding: buffer.prefix(Int(length)), as: UTF8.self)
    }
}

/// The outermost `.app` bundle containing an executable.
struct AppBundleInfo {
    let bundleID: String
    /// User-visible name, localized for the user's languages.
    let name: String
    /// e.g. `/Applications/Firefox.app`
    let path: String

    /// e.g. `/Applications/Firefox.app/Contents/MacOS/firefox` → `org.mozilla.firefox`.
    init?(executable: String) {
        guard let path = outermostAppPath(forExecutable: executable, isBundle: { Bundle(path: $0)?.bundleIdentifier != nil }),
              let bundle = Bundle(path: path), let bundleID = bundle.bundleIdentifier
        else { return nil }
        let name = localizedInfoString("CFBundleDisplayName", in: bundle)
            ?? localizedInfoString("CFBundleName", in: bundle)
            ?? bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? bundle.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? bundle.bundleURL.deletingPathExtension().lastPathComponent
        self.bundleID = bundleID
        // Some Apple apps add soft hyphens for line breaking ("System­einstellungen").
        self.name = name.replacingOccurrences(of: "\u{AD}", with: "")
        self.path = path
    }

    init(bundleID: String, name: String, path: String) {
        self.bundleID = bundleID
        self.name = name
        self.path = path
    }
}

/// Info.plist value localized for the user's preferred languages. Unlike
/// `object(forInfoDictionaryKey:)`, this doesn't depend on the main bundle's
/// localizations, which a command-line tool (or `swift run`) doesn't have.
private func localizedInfoString(_ key: String, in bundle: Bundle) -> String? {
    guard #available(macOS 15.4, *) else { return nil }
    let languages = Bundle.preferredLocalizations(
        from: bundle.localizations, forPreferences: Locale.preferredLanguages)
    let value = bundle.localizedString(forKey: key, value: nil, table: "InfoPlist",
                                       localizations: languages.map(Locale.Language.init(identifier:)))
    return value == key ? nil : value
}

/// Path of the outermost `.app` bundle containing `path`, e.g. `/Applications/Firefox.app`.
/// Directories that are merely named `*.app` (`isBundle` returns false) are skipped.
func outermostAppPath(forExecutable path: String, isBundle: (String) -> Bool) -> String? {
    var prefix = ""
    for component in path.split(separator: "/").dropLast() {
        prefix += "/" + component
        if component.hasSuffix(".app"), isBundle(prefix) {
            return prefix
        }
    }
    return nil
}
