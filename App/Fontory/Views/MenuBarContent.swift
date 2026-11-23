import AppKit
import SwiftUI

struct MenuBarContent: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text("\(model.counts.activated.formatted()) font\(model.counts.activated == 1 ? "" : "s") activated")
        Text("\(model.counts.temporary.formatted()) temporarily activated")
        Divider()
        Button("Clear Temporary Fonts") { Task { await model.clearTemporary() } }
            .disabled(model.counts.temporary == 0)
        Divider()
        Button("Open Fontory") {
            NSApp.setActivationPolicy(.regular)
            openWindow(id: MainWindow.id)
            NSApp.activate()
        }
        Button("Quit Fontory") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}
