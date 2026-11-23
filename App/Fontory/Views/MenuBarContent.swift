import AppKit
import SwiftUI

struct MenuBarContent: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let own = model.counts.fontoryActive
        Text("\(own.formatted()) font\(own == 1 ? "" : "s") activated by Fontory")
        Text("\(model.counts.activated.formatted()) active on this Mac")
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
