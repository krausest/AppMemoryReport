import AppKit
import SwiftUI

@main
struct AppMemoryReport: App {
    @NSApplicationDelegateAdaptor private var appDelegate: AppDelegate
    @State private var model = MemoryModel()

    var body: some Scene {
        Window(localized("App Memory Report"), id: "main") {
            ContentView()
                .environment(model)
        }
        .defaultSize(width: 560, height: 640)
        .commands {
            CommandGroup(after: .toolbar) {
                Button(localized("Refresh")) {
                    Task { await model.refresh() }
                }
                .keyboardShortcut("r")
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Without an .app bundle (`swift run`) the process would start as a background app.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
