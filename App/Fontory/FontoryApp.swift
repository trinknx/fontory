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
                Divider()
                Button("Back Up Library…") { model.showBackUpPanel() }
                RestoreLibraryMenuItem(model: model)
            }
            CommandGroup(after: .undoRedo) {
                // ⌘Z itself reaches it through the key monitor below (only in the browser, outside text fields),
                // so the standard Undo keeps working for text.
                Button("Undo Family Edit") { if model.browserIsKey { Task { await model.undoLastFamilyEdit() } } }
                    .disabled(!model.isBrowserKey || !model.canUndoFamilyEdit)
                // Likewise ⌘Z / ⇧⌘Z reach these in the Layouts window outside text fields.
                // Disabled while the in-place text editor is open: it has its own undo, and would commit over the result.
                Button("Undo Layout Edit") { if model.layouts.windowIsKey, !model.layouts.isEditingText { model.layouts.undo() } }
                    .disabled(!model.layouts.isKey || !model.layouts.canUndo || model.layouts.isEditingText)
                Button("Redo Layout Edit") { if model.layouts.windowIsKey, !model.layouts.isEditingText { model.layouts.redo() } }
                    .disabled(!model.layouts.isKey || !model.layouts.canRedo || model.layouts.isEditingText)
            }
            CommandGroup(before: .toolbar) {
                // On the family page both close it and show the browser in that mode, whichever mode is current.
                Button("as Grid") { model.showBrowser(as: .grid) }
                    .keyboardShortcut("1")
                Button("as List") { model.showBrowser(as: .list) }
                    .keyboardShortcut("3")
                Divider()
                // In the Layouts window these zoom the page (Actual Size fits it); elsewhere, the browser.
                Button("Zoom In") { model.layouts.windowIsKey ? model.layouts.zoomIn() : model.adjustZoom(by: 0.1) }
                    .keyboardShortcut("+")
                Button("Zoom Out") { model.layouts.windowIsKey ? model.layouts.zoomOut() : model.adjustZoom(by: -0.1) }
                    .keyboardShortcut("-")
                Button("Actual Size") { model.layouts.windowIsKey ? model.layouts.zoomToFit() : model.resetZoom() }
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
            CommandMenu("Font") {
                Button("Tags…") { if model.browserIsKey { model.showTagPanel() } }
                    .keyboardShortcut("t")
                    .disabled(!model.isBrowserKey || (model.selection.isEmpty && (model.detail == nil || model.detailSelection.isEmpty)))
                // Same targets as ⌘T; the title follows them (Remove when all are in the collection).
                Button(model.quickCollectionMenuTitle) {
                    if model.browserIsKey { Task { await model.toggleQuickCollection() } }
                }
                .keyboardShortcut("j")
                .disabled(!model.isBrowserKey || model.quickCollectionTargetSet.isEmpty)
                Button("Export Fonts…") { if model.browserIsKey { Task { await model.exportSelection() } } }
                    .keyboardShortcut("e", modifiers: [.command, .shift])
                    .disabled(!model.isBrowserKey || (model.selection.isEmpty && (model.detail == nil || model.detailSelection.isEmpty)))
                Divider()
                Button("Find Duplicates") { model.applySidebarSelection([.duplicates], modifiers: []) }
                    .keyboardShortcut("d", modifiers: [.command, .shift])
            }
        }

        Window("Layouts", id: LayoutsModel.windowID) {
            LayoutsWindow()
                .environment(model)
        }
        .defaultSize(width: 1200, height: 800)

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

/// File ▸ Restore Library…: opens Settings on the Backups tab.
private struct RestoreLibraryMenuItem: View {
    let model: AppModel
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Button("Restore Library…") {
            model.settingsTab = .backups
            openSettings()
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
        // ⌘Z undoes the last family edit when the browser is key, no text is being edited there and there is an
        // edit to undo (`AppModel.handlesFamilyUndoKey`); otherwise it goes on to the standard Undo (text fields,
        // the Text tab, sheets, Settings). The Edit menu's Undo item is left alone.
        // In the Layouts window ⌘= zooms the page, and ⌘Z / ⇧⌘Z undo and redo layout edits unless a text field is
        // being edited there (it keeps its own undo).
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            let isZoomIn = mods == .command && event.charactersIgnoringModifiers == "="
            let isEscape = event.keyCode == 53 && mods.subtracting([.function, .numericPad]).isEmpty
            let isUndo = mods == .command && event.charactersIgnoringModifiers?.lowercased() == "z"
            let isRedo = mods == [.command, .shift] && event.charactersIgnoringModifiers?.lowercased() == "z"
            guard isZoomIn || isEscape || isUndo || isRedo else { return event }
            let handled = MainActor.assumeIsolated { () -> Bool in
                let layouts = self.model.layouts
                if let key = NSApp.keyWindow, key === layouts.window {
                    if isZoomIn {
                        layouts.zoomIn()
                        return true
                    }
                    guard isUndo || isRedo,
                          LayoutsModel.handlesUndoKey(windowIsKey: true, editingText: key.firstResponder is NSText) else { return false }
                    if isUndo { layouts.undo() } else { layouts.redo() }
                    return true
                }
                guard !isRedo, let key = NSApp.keyWindow, key === self.model.browserWindow else { return false }
                if isUndo {
                    guard AppModel.handlesFamilyUndoKey(isCommandZ: true, browserIsKey: true,
                                                        editingText: key.firstResponder is NSText,
                                                        canUndo: self.model.canUndoFamilyEdit) else { return false }
                    Task { await self.model.undoLastFamilyEdit() }
                } else if isEscape {
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
            await awaitAtMost(.seconds(5), Task { await model.prepareForQuit() })
            quitPrepared = true
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
