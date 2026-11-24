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
            QuickCollectionRow()
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
                TagDrag.loadTagID(providers) { id in Task { await model.dropTag(id, onto: nil) } }
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
        // The count is part of the row content (not `.badge`, which the list draws outside it), and the whole row
        // width takes clicks, so the ⌥-click handler below sees clicks anywhere on the row.
        HStack(spacing: 4) {
            if model.renamingTagID == tag.id {
                TagNameField(tag: tag)
            } else {
                Label(tag.name, systemImage: symbol)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            Text(model.tagCount(tag).formatted())
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .tag(SidebarItem.tag(tag.id))
        .help(pick?.inverted == true ? "Showing fonts without “\(tag.name)”" : "")
        .background(RoundedRectangle(cornerRadius: 4).fill(isTargeted ? Color.accentColor.opacity(0.25) : .clear))
        // ⌥-click inverts. The list may not report a click on a row that is already selected, so the click is
        // watched here too; `optionClickTag` applies each click once, whichever path reports it first.
        .simultaneousGesture(TapGesture().onEnded {
            guard let event = NSApp.currentEvent, event.modifierFlags.contains(.option) else { return }
            model.optionClickTag(tag.id, modifiers: EventModifiers(event.modifierFlags), time: event.timestamp)
        })
        .onDrag { TagDrag.provider(for: tag.id) }
        .modifier(TagDropTarget(tag: tag, isTargeted: $isTargeted))
        .contextMenu { TagMenu(tag: tag) }
    }
}

/// Plain tags accept dropped tags (nesting) and dropped fonts (tagged; ⌥-drop untags). Smart tags accept nothing.
private struct TagDropTarget: ViewModifier {
    @Environment(AppModel.self) private var model
    let tag: TagRecord
    @Binding var isTargeted: Bool

    func body(content: Content) -> some View {
        if model.acceptsFaceDrop(on: .tag(tag.id)) {
            content.onDrop(of: [.fontoryTag, .fontoryFaceIDs], isTargeted: $isTargeted) { providers in
                let target = tag.id
                // ⌥ held when the mouse is released: remove the tag instead.
                let removing = NSEvent.modifierFlags.contains(.option)
                if FaceDrag.load(providers, { ids in
                    Task { await model.dropFaces(ids, on: .tag(target), removing: removing) }
                }) { return true }
                return TagDrag.loadTagID(providers) { id in Task { await model.dropTag(id, onto: target) } }
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
        Button("Export Fonts…") { Task { await model.exportTag(tag.id) } }
        Divider()
        Button("Delete…") { model.confirmDeleteTag(tag.id) }
    }
}

/// The Quick Collection (⌘J), first in Tags: a scratch set that can be saved as a tag.
private struct QuickCollectionRow: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Label("Quick Collection", systemImage: "bookmark")
            .badge(model.organizationCounts.quickCollection)
            .tag(SidebarItem.scope(.quickCollection))
            .contextMenu {
                Button("Save as Tag…") { promptSaveQuickCollectionAsTag(model: model) }
                    .disabled(model.quickCollectionIDs.isEmpty)
                Button("Export Fonts…") { Task { await model.exportQuickCollection() } }
                    .disabled(model.quickCollectionIDs.isEmpty)
                Button("Clear…") { model.confirmClearQuickCollection() }
                    .disabled(model.quickCollectionIDs.isEmpty)
            }
    }
}

/// Automatic style classes, read-only, collapsed by default.
private struct StyleGroup: View {
    @Environment(AppModel.self) private var model
    @AppStorage("sidebar.styleExpanded") private var isExpanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            ForEach(StyleClass.browsable, id: \.self) { style in
                Label { Text(style.title) } icon: { StyleSampleIcon(style: style) }
                    .badge(model.organizationCounts.perStyle[style] ?? 0)
                    .tag(SidebarItem.scope(.styleClass(style)))
            }
        } label: {
            Label("Style", systemImage: "textformat.alt")
        }
        .help("Classified automatically from each font’s design")
    }
}

/// "Ag" drawn in a typical face of the class, so each Style row shows what the class looks like.
/// Fonts that ship with macOS; a missing one falls back to the system font.
private struct StyleSampleIcon: View {
    let style: StyleClass

    var body: some View {
        if style == .symbol {
            Image(systemName: "staroflife")
        } else {
            Text("Ag")
                .font(font)
                .lineLimit(1)
                .fixedSize()
                .accessibilityHidden(true)
        }
    }

    private var font: Font {
        switch style {
        case .serif: .custom("Baskerville", size: 15, relativeTo: .body)
        case .sans: .custom("Avenir Next", size: 13, relativeTo: .body).weight(.medium)
        case .slab: .custom("Rockwell", size: 13, relativeTo: .body)
        case .script: .custom("Snell Roundhand", size: 16, relativeTo: .body).weight(.semibold)
        case .mono: .system(size: 12, weight: .medium, design: .monospaced)
        case .display: .custom("Copperplate", size: 13, relativeTo: .body).weight(.bold)
        case .symbol, .unknown: .body
        }
    }
}

/// ⊕ at the bottom of the sidebar.
struct SidebarAddButton: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack {
            Menu {
                Button("New Tag") { Task { await model.newTag() } }
                Button("New Smart Tag…") { model.newSmartTag() }
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
