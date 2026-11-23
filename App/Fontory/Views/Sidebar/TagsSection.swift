import AppKit
import FontoryCore
import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    /// A sidebar tag being dragged (its id as UTF-8 text). Declared in Info.plist; never leaves the process.
    static let fontoryTag = UTType(exportedAs: "local.fontory.tag", conformingTo: .data)
}

/// The Tags section: user and smart tags as a tree in name order, then the automatic Style group.
struct TagsSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Section {
            ForEach(model.childTags(of: nil)) { TagNode(tag: $0) }
            StyleGroup()
        } header: {
            TagsHeader()
        }
    }
}

/// `#` Tags. Dropping a tag here moves it to the top level.
private struct TagsHeader: View {
    @Environment(AppModel.self) private var model
    @State private var isTargeted = false

    var body: some View {
        Label("Tags", systemImage: "number")
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .padding(.vertical, 1)
            .background(RoundedRectangle(cornerRadius: 4).fill(isTargeted ? Color.accentColor.opacity(0.25) : .clear))
            .onDrop(of: [.fontoryTag], isTargeted: $isTargeted) { providers in
                TagDrag.loadTagID(providers) { id in Task { await model.moveTag(id, toParent: nil) } }
            }
            .help("Drop a tag here to move it to the top level")
    }
}

private struct TagNode: View {
    @Environment(AppModel.self) private var model
    let tag: TagRecord

    var body: some View {
        let children = model.childTags(of: tag.id)
        if children.isEmpty {
            TagRow(tag: tag)
        } else {
            DisclosureGroup(isExpanded: expanded) {
                ForEach(children) { TagNode(tag: $0) }
            } label: {
                TagRow(tag: tag)
            }
        }
    }

    private var expanded: Binding<Bool> {
        Binding(get: { model.expandedTagIDs.contains(tag.id) },
                set: { if $0 { model.expandedTagIDs.insert(tag.id) } else { model.expandedTagIDs.remove(tag.id) } })
    }
}

private struct TagRow: View {
    @Environment(AppModel.self) private var model
    let tag: TagRecord
    @State private var isTargeted = false

    private var pick: TagPick? { model.selectedTagPicks.first { $0.tagID == tag.id } }

    private var symbol: String {
        if pick?.inverted == true { return "tag.slash" }
        return tag.kind == .smart ? "gearshape" : "tag"
    }

    var body: some View {
        Group {
            if model.renamingTagID == tag.id {
                TagNameField(tag: tag)
            } else {
                Label(tag.name, systemImage: symbol)
            }
        }
        .badge(model.tagCount(tag))
        .tag(SidebarItem.tag(tag.id))
        .help(pick?.inverted == true ? "Showing fonts without “\(tag.name)”" : "")
        .background(RoundedRectangle(cornerRadius: 4).fill(isTargeted ? Color.accentColor.opacity(0.25) : .clear))
        // ⌥-click inverts. The list does not report modifiers, so the click itself is watched; the list's own
        // selection change ignores ⌥ (see `AppModel.applySidebarSelection`).
        .simultaneousGesture(TapGesture().onEnded {
            let flags = NSApp.currentEvent?.modifierFlags ?? []
            if flags.contains(.option) { model.selectTag(tag.id, modifiers: EventModifiers(flags)) }
        })
        .onDrag { TagDrag.provider(for: tag.id) }
        .modifier(TagDropTarget(tag: tag, isTargeted: $isTargeted))
        .contextMenu { TagMenu(tag: tag) }
    }
}

/// Plain tags accept dropped tags (nesting). Smart tags accept nothing. Font drops (Task 6) go here too.
private struct TagDropTarget: ViewModifier {
    @Environment(AppModel.self) private var model
    let tag: TagRecord
    @Binding var isTargeted: Bool

    func body(content: Content) -> some View {
        if tag.kind == .tag {
            content.onDrop(of: [.fontoryTag], isTargeted: $isTargeted) { providers in
                let target = tag.id
                return TagDrag.loadTagID(providers) { id in
                    // Onto itself or a subtag of its own: nothing to do (the store would refuse the cycle).
                    guard !model.descendantTagIDs(of: id).contains(target) else { return }
                    Task { await model.moveTag(id, toParent: target) }
                }
            }
        } else {
            content
        }
    }
}

enum TagDrag {
    static func provider(for id: Int64) -> NSItemProvider {
        let provider = NSItemProvider()
        provider.registerDataRepresentation(for: .fontoryTag, visibility: .ownProcess) { completion in
            completion(Data(String(id).utf8), nil)
            return nil
        }
        return provider
    }

    /// Reads the dragged tag id and hands it to `handler` on the main actor. Returns whether a tag was dropped.
    static func loadTagID(_ providers: [NSItemProvider], _ handler: @escaping @MainActor @Sendable (Int64) -> Void) -> Bool {
        guard let provider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.fontoryTag.identifier) }) else {
            return false
        }
        _ = provider.loadDataRepresentation(for: .fontoryTag) { data, _ in
            guard let data, let id = Int64(String(decoding: data, as: UTF8.self)) else { return }
            Task { @MainActor in handler(id) }
        }
        return true
    }
}

/// Inline rename: Return commits, Esc cancels, clicking elsewhere commits.
private struct TagNameField: View {
    @Environment(AppModel.self) private var model
    let tag: TagRecord
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField("Tag Name", text: $draft)
            .textFieldStyle(.plain)
            .focused($focused)
            .onSubmit(commit)
            .onExitCommand { model.renamingTagID = nil }
            .onChange(of: focused) { _, isFocused in if !isFocused { commit() } }
            .task {
                draft = tag.name
                focused = true
            }
    }

    private func commit() {
        guard model.renamingTagID == tag.id else { return }
        model.renamingTagID = nil
        let name = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != tag.name else { return }
        Task { await model.renameTag(tag.id, to: name) }
    }
}

private struct TagMenu: View {
    @Environment(AppModel.self) private var model
    let tag: TagRecord

    var body: some View {
        if tag.kind == .tag {
            Button("New Subtag") { Task { await model.newTag(parentID: tag.id) } }
        }
        Button("Rename") { model.renamingTagID = tag.id }
        if tag.kind == .smart {
            Button("Edit…") { model.editSmartTag(tag.id) }
        }
        Divider()
        Button("Activate All") { Task { await model.activateTag(tag.id, on: true) } }
        Button("Deactivate All") { Task { await model.activateTag(tag.id, on: false) } }
        Divider()
        Button("Delete…") { model.confirmDeleteTag(tag.id) }
    }
}

/// Automatic style classes, read-only, collapsed by default.
private struct StyleGroup: View {
    @Environment(AppModel.self) private var model
    @AppStorage("sidebar.styleExpanded") private var isExpanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            ForEach(StyleClass.browsable, id: \.self) { style in
                Label(style.title, systemImage: "textformat")
                    .badge(model.organizationCounts.perStyle[style] ?? 0)
                    .tag(SidebarItem.scope(.styleClass(style)))
            }
        } label: {
            Label("Style", systemImage: "textformat.alt")
        }
        .help("Classified automatically from each font’s design")
    }
}

/// ⊕ at the bottom of the sidebar.
struct SidebarAddButton: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack {
            Menu {
                Button("New Tag") { Task { await model.newTag() } }
                Button("New Smart Tag…") { Task { await model.newSmartTag() } }
                Divider()
                Button("Import Fonts…") { model.showImportPanel() }
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 13, weight: .medium))
                    .frame(width: 28, height: 28)
                    .contentShape(Circle())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .glassBackground(in: Circle(), fallback: Color(nsColor: .quaternaryLabelColor).opacity(0.5))
            .help("New Tag, New Smart Tag or Import Fonts")
            .accessibilityLabel("Add")
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}
