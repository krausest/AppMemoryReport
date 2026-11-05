import AppKit
import MemoryCore
import SwiftUI

/// A process to show in `ProcessDetailsView`, read when the row is double-clicked.
struct ProcessDetailsRequest: Identifiable {
    let id = UUID()
    let name: String
    let userName: String
    let details: ProcessDetails
}

/// PID, executable and command line of one process.
struct ProcessDetailsView: View {
    let request: ProcessDetailsRequest
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(request.name)
                .font(.headline)
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 8) {
                GridRow {
                    label("PID")
                    Text(String(request.details.pid))
                        .monospacedDigit()
                        .textSelection(.enabled)
                }
                GridRow {
                    label(localized("User"))
                    Text(request.userName)
                }
                GridRow {
                    label(localized("Executable"))
                    switch request.details.state {
                    case .running(let path, _):
                        Text(path)
                            .font(.body.monospaced())
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    case .exited:
                        Text(localized("The process has exited."))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            if case .running(_, let arguments) = request.details.state {
                label(localized("Arguments"))
                if let arguments {
                    argumentList(arguments)
                } else {
                    Text(localized("The arguments can't be read (other users' processes need root)."))
                        .foregroundStyle(.secondary)
                }
            }
            HStack {
                if case .running(_, let arguments?) = request.details.state {
                    Button(localized("Copy Command Line")) {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(commandLine(arguments), forType: .string)
                    }
                }
                Spacer()
                Button(localized("Close")) { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(minWidth: 520, idealWidth: 680, maxWidth: 1000, minHeight: 260, idealHeight: 440)
    }

    private func label(_ text: String) -> some View {
        Text(text)
            .foregroundStyle(.secondary)
            .gridColumnAlignment(.trailing)
    }

    /// One argument per line with its index; argv[0] is the name the process was started with.
    private func argumentList(_ arguments: [String]) -> some View {
        ScrollView {
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 4) {
                ForEach(Array(arguments.enumerated()), id: \.offset) { index, argument in
                    GridRow {
                        Text(String(index))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .gridColumnAlignment(.trailing)
                        Text(argument.isEmpty ? "\"\"" : argument)
                            .font(.body.monospaced())
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .padding(8)
        }
        .background(Color(nsColor: .textBackgroundColor))
        .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color(nsColor: .separatorColor)))
    }

    /// The arguments as a shell command, quoted where needed.
    private func commandLine(_ arguments: [String]) -> String {
        let safe = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_@%+=:,./-")
        return arguments.map { argument in
            !argument.isEmpty && argument.unicodeScalars.allSatisfy(safe.contains) ? argument
                : "'" + argument.replacingOccurrences(of: "'", with: "'\\''") + "'"
        }.joined(separator: " ")
    }
}
