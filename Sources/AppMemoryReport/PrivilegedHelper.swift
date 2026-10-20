import Foundation
import MemoryCore

/// Starts the CLI binary (next to the app's executable: in the .app's `Contents/MacOS`,
/// or in SwiftPM's bin directory with `swift run`) as root via the standard administrator
/// password dialog and returns the connection to it.
enum PrivilegedHelper {
    enum LaunchError: Error {
        case notFound(String)
        /// The user cancelled the password dialog.
        case cancelled
        case failed(String)
    }

    static func launch() async throws -> HelperConnection {
        let executable = Bundle.main.executableURL!.deletingLastPathComponent()
            .appendingPathComponent("app-memory-report").path
        guard FileManager.default.isExecutableFile(atPath: executable) else {
            throw LaunchError.notFound(executable)
        }
        // Root has its own language settings; app names should follow the user's.
        let languages = "(" + Locale.preferredLanguages.map { "\"\($0)\"" }.joined(separator: ", ") + ")"
        let prompt = localized("\(localized("App Memory Report")) wants to measure the memory of all users' processes.")
        return try await Task.detached {
            try HelperConnection.accept { socketPath in
                // In the background with its output redirected, so `do shell script` returns.
                let command = [executable, "--serve", socketPath, "-AppleLanguages", languages]
                    .map(shellQuoted).joined(separator: " ") + " >/dev/null 2>&1 &"
                try runAsAdministrator(command, prompt: prompt)
            }
        }.value
    }

    private static func runAsAdministrator(_ command: String, prompt: String) throws {
        let script = "do shell script \(appleScriptQuoted(command)) with prompt \(appleScriptQuoted(prompt)) "
            + "with administrator privileges"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        let errors = Pipe()
        process.standardError = errors
        process.standardOutput = FileHandle.nullDevice
        try process.run()
        let message = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            // -128: "User canceled."
            throw message.contains("-128") ? LaunchError.cancelled
                : LaunchError.failed(message.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    private static func shellQuoted(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func appleScriptQuoted(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}
