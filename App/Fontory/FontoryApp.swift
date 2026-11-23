import AppKit
import SwiftUI

@main
struct FontoryApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        let model = appDelegate.model
        Window("Fontory", id: MainWindow.id) {
            MainWindow()
                .environment(model)
        }
        .commands {
            CommandGroup(after: .newItem) {
                Button("Add Fonts…") { model.showImportPanel() }
                    .keyboardShortcut("o")
            }
            CommandGroup(before: .toolbar) {
                Button("as Grid") { model.viewMode = .grid }
                    .keyboardShortcut("1")
                Button("as List") { model.viewMode = .list }
                    .keyboardShortcut("3")
                Divider()
            }
            CommandMenu("Fonts") {
                Button("Clear Temporary Fonts") { Task { await model.clearTemporary() } }
            }
        }

        Settings {
            SettingsView()
                .environment(model)
        }

        MenuBarExtra("Fontory", systemImage: "textformat") {
            MenuBarContent()
                .environment(model)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()
    private var quitPrepared = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        let center = NotificationCenter.default
        center.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { note in
            let closing = note.object as? NSWindow
            MainActor.assumeIsolated { self.windowWillClose(closing) }
        }
        center.addObserver(forName: NSWindow.didBecomeMainNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                if NSApp.activationPolicy() != .regular { NSApp.setActivationPolicy(.regular) }
            }
        }
        Task { await model.start() }
    }

    private var keepRunningInMenuBar: Bool {
        UserDefaults.standard.bool(forKey: SettingsKey.keepRunningInMenuBar)
    }

    /// Closing the last window keeps the app alive in the menu bar (no Dock icon) when that setting is on.
    private func windowWillClose(_ closing: NSWindow?) {
        guard keepRunningInMenuBar else { return }
        let remaining = NSApp.windows.filter { $0 !== closing && $0.isVisible && $0.styleMask.contains(.titled) && !($0 is NSPanel) }
        if remaining.isEmpty { NSApp.setActivationPolicy(.accessory) }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        !keepRunningInMenuBar
    }

    /// Temporary activations are cleared before quitting. That work is async, so termination waits for it
    /// (at most 5 s) instead of running it in `applicationWillTerminate`, which cannot await.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if quitPrepared { return .terminateNow }
        Task {
            let prepare = Task { await model.prepareForQuit() }
            let timeout = Task { try? await Task.sleep(for: .seconds(5)) }
            await withTaskGroup(of: Void.self) { group in
                group.addTask { await prepare.value }
                group.addTask { await timeout.value }
                await group.next()
                group.cancelAll()
            }
            timeout.cancel()
            quitPrepared = true
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
