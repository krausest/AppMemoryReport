import Foundation
import MemoryCore

/// SwiftPM puts the compiled string catalog into a resource bundle next to the executable.
/// Not `Bundle.module`: it aborts if the bundle is missing, e.g. for a binary copied
/// elsewhere. Without the bundle, the English keys are shown.
let localizationBundle = Bundle(url: Bundle.main.bundleURL
    .appendingPathComponent("app-memory-report_app-memory-report.bundle"))
    .map(preferredLocalization(of:)) ?? .main

func localized(_ key: String.LocalizationValue) -> String {
    String(localized: key, bundle: localizationBundle)
}

func pad(_ text: String, _ width: Int, right: Bool = false) -> String {
    let fill = String(repeating: " ", count: max(0, width - text.count))
    return right ? fill + text : text + fill
}

func truncate(_ text: String, _ width: Int) -> String {
    text.count > width ? text.prefix(width - 1) + "…" : text
}

// Started as root by the GUI to measure all users' processes (see `serveHelper`).
if CommandLine.arguments.count >= 3, CommandLine.arguments[1] == "--serve" {
    exit(serveHelper(socketPath: CommandLine.arguments[2]))
}

// As root, footprint can read every process, so include all users.
let report = MemoryReport.measure(includeAllUsers: geteuid() == 0, includeTotal: true)
guard let total = report.total else {
    print(localized("No processes found."))
    exit(0)
}
let results = report.rows.sorted { $0.bytes > $1.bytes }

let nameWidth = min(40, max(20, results.map(\.name.count).max() ?? 0))
// As root the rows belong to several users; otherwise they are all the current user's.
let showUser = geteuid() == 0
let userNames = Dictionary(uniqueKeysWithValues: Set(results.map(\.uid)).map { ($0, userName(of: $0)) })
let userWidth = showUser ? min(16, max(localized("User").count, userNames.values.map(\.count).max() ?? 0)) + 2 : 0
func userColumn(_ name: String) -> String {
    showUser ? pad(truncate(name, userWidth - 2), userWidth) : ""
}

let header = pad(localized("App"), nameWidth) + userColumn(localized("User"))
    + pad(localized("Processes"), 10, right: true) + pad(localized("Memory"), 12, right: true)
print(header)
for row in results {
    let marker = row.deduplicated ? " " : "*"
    print(pad(truncate(row.name, nameWidth), nameWidth) + userColumn(userNames[row.uid]!)
          + pad(String(row.processCount), 10, right: true)
          + pad(formatBytes(row.bytes), 11, right: true) + marker)
}
print(String(repeating: "-", count: header.count))
print(pad(localized("Total"), nameWidth) + userColumn("")
      + pad(String(total.processCount), 10, right: true)
      + pad(formatBytes(total.bytes), 11, right: true) + (total.deduplicated ? "" : "*"))

print("\n" + localized("Memory shared by several rows counts in each of them, but only once in “Total”."))
if !total.deduplicated || results.contains(where: { !$0.deduplicated }) {
    print(localized("* Plain sum of the individual footprints (footprint unavailable, or skipped because hardly any memory can be shared): shared memory may be counted more than once."))
}
