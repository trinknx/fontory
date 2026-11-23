import AppKit
import SwiftUI

@main
enum FontoryMain {
    @MainActor static func main() {
        #if DEBUG
        // Headless checks on a temporary library; they never open the user's library or any window.
        if CommandLine.arguments.contains(OrganizationSmoke.argument) { OrganizationSmoke.runAndExit() }
        #endif
        FontoryApp.main()
    }
}

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
                // On the family page both close it and show the browser in that mode, whichever mode is current.
                Button("as Grid") { model.showBrowser(as: .grid) }
                    .keyboardShortcut("1")
                Button("as List") { model.showBrowser(as: .list) }
                    .keyboardShortcut("3")
                Divider()
                Button("Zoom In") { model.adjustZoom(by: 0.1) }
                    .keyboardShortcut("+")
                Button("Zoom Out") { model.adjustZoom(by: -0.1) }
                    .keyboardShortcut("-")
                Button("Actual Size") { model.resetZoom() }
                    .keyboardShortcut("0")
                Divider()
                Button("Show Family") { if model.browserIsKey { model.showFamilyDetailForSelection() } }
                    .keyboardShortcut("i")
                    .disabled(!model.isBrowserKey || (model.detail == nil && model.selection.isEmpty))
                Button("Back") { if model.browserIsKey { model.closeFamilyDetail() } }
                    .keyboardShortcut("[")
                    .disabled(!model.isBrowserKey || model.detail == nil)
                Divider()
                Button("Preview Options…") { model.isShowingPreviewOptions.toggle() }
                    .keyboardShortcut("p", modifiers: [.option, .command])
                Divider()
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
        // ⌘= zooms in like ⌘+ (which needs Shift on many layouts). A local monitor sees the key before the
        // menu and regardless of the first responder; it acts only in the main browser window.
        // Esc leaves the family page from anywhere in it, except while a text field is being edited (the search
        // field clears itself on Esc).
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            let isZoomIn = mods == .command && event.charactersIgnoringModifiers == "="
            let isEscape = event.keyCode == 53 && mods.subtracting([.function, .numericPad]).isEmpty
            guard isZoomIn || isEscape else { return event }
            let handled = MainActor.assumeIsolated { () -> Bool in
                guard let key = NSApp.keyWindow, key === self.model.browserWindow else { return false }
                if isEscape {
                    // An empty text field (the search field) has nothing to clear: Esc goes Back from there too.
                    guard self.model.detail != nil, !self.model.isShowingPreviewOptions else { return false }
                    if let text = key.firstResponder as? NSText, !text.string.isEmpty { return false }
                    self.model.closeFamilyDetail()
                } else {
                    self.model.adjustZoom(by: 0.1)
                }
                return true
            }
            return handled ? nil : event
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

    /// Faces still temporary (left by an older version; the UI no longer creates them) are cleared before quitting. That work is async, so termination waits for it
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
