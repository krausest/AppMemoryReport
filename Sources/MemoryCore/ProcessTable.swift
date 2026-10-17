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

    var isSelfResponsible: Bool { responsiblePID == pid }
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
                path: executablePath(of: pid) ?? ""
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

    private static func bsdInfo(of pid: pid_t) -> (ppid: pid_t, uid: uid_t)? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return (pid_t(info.pbi_ppid), info.pbi_uid)
    }

    private static func executablePath(of pid: pid_t) -> String? {
        var buffer = [UInt8](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(decoding: buffer.prefix(Int(length)), as: UTF8.self)
    }
}

/// Bundle identifier of the outermost `.app` bundle containing `path`, e.g.
/// `/Applications/Firefox.app/Contents/MacOS/firefox` → `org.mozilla.firefox`.
func outermostAppBundleID(forExecutable path: String) -> String? {
    outermostAppBundle(forExecutable: path)?.bundleIdentifier
}

/// User-visible name of the outermost `.app` bundle containing `path`.
func outermostAppName(forExecutable path: String) -> String? {
    guard let bundle = outermostAppBundle(forExecutable: path) else { return nil }
    let name = localizedInfoString("CFBundleDisplayName", in: bundle)
        ?? localizedInfoString("CFBundleName", in: bundle)
        ?? bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
        ?? bundle.object(forInfoDictionaryKey: "CFBundleName") as? String
        ?? bundle.bundleURL.deletingPathExtension().lastPathComponent
    // Some Apple apps add soft hyphens for line breaking ("System­einstellungen").
    return name.replacingOccurrences(of: "\u{AD}", with: "")
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
func outermostAppPath(forExecutable path: String) -> String? {
    guard let range = path.range(of: ".app/") else { return nil }
    return String(path[..<range.lowerBound]) + ".app"
}

private func outermostAppBundle(forExecutable path: String) -> Bundle? {
    outermostAppPath(forExecutable: path).flatMap(Bundle.init(path:))
}
