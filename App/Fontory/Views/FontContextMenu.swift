import AppKit
import FontoryCore

/// The face context menu (items are enabled explicitly: menus built here set `autoenablesItems = false`), built as an `NSMenu` so AppKit views (grid, list) can share it.
@MainActor
enum FontContextMenu {
    /// Full menu for the faces `ids` (the clicked face, or the selection when the click was inside it).
    static func make(for ids: [Int64], model: AppModel) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        for item in activationItems(for: ids, model: model) { menu.addItem(item) }
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem("Reveal in Finder") { model.revealInFinder(ids) })
        menu.addItem(ClosureMenuItem("Copy Details") { model.copyDetails(ids) })
        if ids.count == 1, let id = ids.first {
            menu.addItem(.separator())
            menu.addItem(ClosureMenuItem("Set as Family Representative") { model.setFamilyRepresentative(id) })
        }
        return menu
    }

    /// Activate / Activate Temporarily / Deactivate. Disabled when every face is a locked system font.
    static func activationItems(for ids: [Int64], model: AppModel) -> [NSMenuItem] {
        let rows = ids.compactMap(model.cachedRow)
        let allLocked = !rows.isEmpty && rows.count == ids.count && rows.allSatisfy(model.isActivationLocked)
        let states = Set(rows.map(\.activation))
        let items: [(String, ActivationState)] = [("Activate", .on), ("Activate Temporarily", .temporary), ("Deactivate", .off)]
        return items.map { title, state in
            let item = ClosureMenuItem(title) { Task { await model.setActivation(ids, state) } }
            item.isEnabled = !allLocked
            if states == [state] { item.state = .on }
            return item
        }
    }
}

/// A menu item that runs a closure; it is its own target.
final class ClosureMenuItem: NSMenuItem {
    private let handler: @MainActor () -> Void

    init(_ title: String, handler: @escaping @MainActor () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    @objc @MainActor private func run() {
        handler()
    }
}
