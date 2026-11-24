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
        menu.addItem(tagsItem(for: ids, model: model))
        menu.addItem(quickCollectionItem(for: ids, model: model))
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem("Reveal in Finder") { model.revealInFinder(ids) })
        menu.addItem(ClosureMenuItem("Export Fonts…") { Task { await model.exportFonts(faceIDs: ids, suggestedName: "Fonts") } })
        menu.addItem(ClosureMenuItem("Copy Details") { model.copyDetails(ids) })
        if ids.count == 1, let id = ids.first {
            menu.addItem(.separator())
            menu.addItem(ClosureMenuItem("Set as Family Representative") { model.setFamilyRepresentative(id) })
        }
        return menu
    }

    /// Activate / Deactivate (always persistent). Disabled when every face is read-only: a system font or a font
    /// active outside Fontory.
    static func activationItems(for ids: [Int64], model: AppModel) -> [NSMenuItem] {
        let rows = ids.compactMap(model.cachedRow)
        let allLocked = !rows.isEmpty && rows.count == ids.count && rows.allSatisfy(model.isActivationLocked)
        let states = Set(rows.map(\.activation))
        let items: [(String, ActivationState)] = [("Activate", .on), ("Deactivate", .off)]
        return items.map { title, state in
            let item = ClosureMenuItem(title) { Task { await model.setActivation(ids, state) } }
            item.isEnabled = !allLocked
            if states == [state] { item.state = .on }
            return item
        }
    }

    /// Tags ▸: every plain tag as a checkbox (subtags indented under their parent; mixed when only some of the
    /// faces have it), then "New Tag…". The states are read off the main actor; until they arrive the checkboxes
    /// are disabled (the menu updates while open).
    static func tagsItem(for ids: [Int64], model: AppModel) -> NSMenuItem {
        let item = NSMenuItem(title: "Tags", action: nil, keyEquivalent: "")
        let submenu = NSMenu(title: "Tags")
        submenu.autoenablesItems = false
        var tagItems: [Int64: NSMenuItem] = [:]
        for (tag, depth) in model.plainTagTree() {
            let tagID = tag.id
            let tagItem = ClosureMenuItem(tag.name) { sender in
                let state: TagCheckState = switch sender.state {
                case .on: .on
                case .mixed: .mixed
                default: .off
                }
                Task { await model.toggleTag(tagID, onFaces: ids, from: state) }
            }
            tagItem.indentationLevel = min(depth, 15)
            tagItem.isEnabled = false
            tagItems[tagID] = tagItem
            submenu.addItem(tagItem)
        }
        if !tagItems.isEmpty { submenu.addItem(.separator()) }
        submenu.addItem(ClosureMenuItem("New Tag…") { promptNewTag(for: ids, model: model) })
        item.submenu = submenu
        Task {
            guard let map = await model.faceTagMap(ids) else { return }
            let states = AppModel.tagStates(map, faces: ids)
            for (id, tagItem) in tagItems {
                switch states[id] {
                case .on?: tagItem.state = .on
                case .mixed?: tagItem.state = .mixed
                default: tagItem.state = .off
                }
                tagItem.isEnabled = true
            }
        }
        return item
    }

    /// Add to / Remove from Quick Collection (⌘J): Remove when every face is in it.
    static func quickCollectionItem(for ids: [Int64], model: AppModel) -> NSMenuItem {
        let item = ClosureMenuItem(model.quickCollectionTitle(for: ids)) { Task { await model.toggleQuickCollection(ids) } }
        item.keyEquivalent = "j"
        item.keyEquivalentModifierMask = .command
        return item
    }

    /// Asks for a name, then creates the tag at the top level and tags `ids` with it.
    static func promptNewTag(for ids: [Int64], model: AppModel) {
        let alert = NSAlert()
        alert.messageText = "New Tag"
        alert.informativeText = ids.count == 1 ? "The font will be tagged with it."
            : "The \(ids.count.formatted()) fonts will be tagged with it."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.placeholderString = "Tag Name"
        alert.accessoryView = field
        alert.addButton(withTitle: "Create")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let name = field.stringValue
        Task { await model.createTagAndAssign(name: name, faces: ids) }
    }
}

/// A menu item that runs a closure; it is its own target.
final class ClosureMenuItem: NSMenuItem {
    private let handler: @MainActor (ClosureMenuItem) -> Void

    init(_ title: String, handler: @escaping @MainActor (ClosureMenuItem) -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
    }

    convenience init(_ title: String, handler: @escaping @MainActor () -> Void) {
        self.init(title, handler: { (_: ClosureMenuItem) in handler() })
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    @objc @MainActor private func run() {
        handler(self)
    }
}
