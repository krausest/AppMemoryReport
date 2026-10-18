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

// As root, footprint can read every process, so include all users.
let report = MemoryReport.measure(includeAllUsers: geteuid() == 0, includeTotal: true)
guard let total = report.total else {
    print(localized("No processes found."))
    exit(0)
}
let results = report.rows.sorted { $0.bytes > $1.bytes }

let nameWidth = min(40, max(20, results.map(\.name.count).max() ?? 0))
let header = pad(localized("App"), nameWidth) + pad(localized("Processes"), 10, right: true)
    + pad(localized("Memory"), 12, right: true)
print(header)
for row in results {
    let marker = row.deduplicated ? " " : "*"
    print(pad(truncate(row.name, nameWidth), nameWidth) + pad(String(row.processCount), 10, right: true)
          + pad(formatBytes(row.bytes), 11, right: true) + marker)
}
print(String(repeating: "-", count: header.count))
print(pad(localized("Total"), nameWidth)
      + pad(String(total.processCount), 10, right: true)
      + pad(formatBytes(total.bytes), 11, right: true) + (total.deduplicated ? "" : "*"))

print("\n" + localized("Memory shared by several rows counts in each of them, but only once in “Total”."))
if !total.deduplicated || results.contains(where: { !$0.deduplicated }) {
    print(localized("* Plain sum of the individual footprints (footprint unavailable, or skipped because hardly any memory can be shared): shared memory may be counted more than once."))
}
