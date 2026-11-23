import AppKit
import FontoryCore
import SwiftUI

/// ⌘T: assigns tags to a set of faces from the keyboard. A search field (case- and diacritic-insensitive
/// subsequence match on the tag's full path) over the plain tags with their checkbox for these faces (on, off, mixed).
/// ↑/↓ move the highlight; Tab toggles the highlighted tag for every face (Space too, once the highlight was moved
/// with the arrows or while the field is empty, so names with spaces can still be typed); Return toggles it, or
/// creates and assigns the typed name when no tag matches (the "Create" row); Esc closes.
struct TagPanel: View {
    let model: AppModel
    let request: TagPanelRequest
    @Environment(\.dismiss) private var dismiss

    @State private var query = ""
    @State private var highlighted = 0
    /// The arrows moved the highlight since the last keystroke: Space toggles instead of typing.
    @State private var navigating = false
    /// Direct tags of the faces; nil until loaded.
    @State private var map: [Int64: Set<Int64>]?

    enum Row: Hashable {
        case tag(Int64)
        case create(String)
    }

    private var faces: [Int64] { request.faceIDs }

    private var states: [Int64: TagCheckState] {
        AppModel.tagStates(map ?? [:], faces: faces)
    }

    /// Matching tags (best first, tree order within a rank), then "Create “…”" when the typed name is no tag's
    /// name or path.
    private var rows: [Row] {
        let tree = model.plainTagTree()
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        var out: [Row] = []
        if trimmed.isEmpty {
            out = tree.map { .tag($0.tag.id) }
        } else {
            let scored = tree.enumerated().compactMap { index, entry -> (Int, Int, Int64)? in
                TagSearch.score(trimmed, in: model.tagPath(entry.tag.id)).map { ($0, index, entry.tag.id) }
            }
            out = scored.sorted { ($0.0, $0.1) < ($1.0, $1.1) }.map { .tag($0.2) }
            if !model.plainTagExists(named: trimmed) { out.append(.create(trimmed)) }
        }
        return out
    }

    var body: some View {
        let rows = rows
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                Text(title).font(.headline).lineLimit(1).truncationMode(.middle)
                TagPanelField(text: $query, placeholder: "Search or create a tag",
                              spaceToggles: { navigating || query.isEmpty },
                              onCommand: handle)
                    .frame(height: 22)
            }
            .padding(12)
            .glassBackground(in: Rectangle(), fallback: .clear)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(rows.enumerated()), id: \.element) { index, row in
                            rowView(row, highlighted: index == highlighted)
                                .id(row)
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    highlighted = index
                                    activate(row)
                                }
                        }
                    }
                    .padding(.vertical, 4)
                }
                .onChange(of: highlighted) { _, new in
                    if rows.indices.contains(new) { proxy.scrollTo(rows[new]) }
                }
            }
            .frame(height: 260)
            .overlay {
                if rows.isEmpty {
                    Text("No tags yet. Type a name and press Return to create one.")
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding()
                }
            }
            Divider()
            HStack {
                Text("Tab toggles · Return creates · Esc closes")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Done") { dismiss() }
            }
            .padding(10)
            .glassBackground(in: Rectangle(), fallback: .clear)
        }
        .frame(width: 380)
        .onChange(of: query) { _, _ in
            navigating = false
            highlighted = 0
        }
        .onChange(of: rows.count) { _, count in
            if highlighted >= count { highlighted = max(0, count - 1) }
        }
        .task(id: model.tagAssignmentVersion) {
            if let loaded = await model.faceTagMap(faces) { map = loaded }
        }
        .onExitCommand { dismiss() }
    }

    private var title: String {
        if faces.count == 1, let row = model.cachedRow(faces[0]) { return "Tags for \(row.fullName)" }
        return "Tags for \(faces.count.formatted()) fonts"
    }

    @ViewBuilder
    private func rowView(_ row: Row, highlighted: Bool) -> some View {
        HStack(spacing: 8) {
            switch row {
            case .tag(let id):
                Image(systemName: symbol(states[id] ?? .off))
                    .foregroundStyle(states[id] == nil ? Color.secondary : Color.accentColor)
                    .opacity(map == nil ? 0.4 : 1)
                Text(model.tagPath(id)).lineLimit(1).truncationMode(.head)
            case .create(let name):
                Image(systemName: "plus.circle")
                Text("Create “\(name)”").lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .foregroundStyle(highlighted ? Color.white : Color.primary)
        .background(highlighted ? Color.accentColor : Color.clear, in: RoundedRectangle(cornerRadius: 5))
        .padding(.horizontal, 6)
    }

    private func symbol(_ state: TagCheckState) -> String {
        switch state {
        case .on: "checkmark.square.fill"
        case .mixed: "minus.square.fill"
        case .off: "square"
        }
    }

    private func handle(_ command: TagPanelField.Command) {
        let rows = rows
        switch command {
        case .up:
            navigating = true
            if highlighted > 0 { highlighted -= 1 }
        case .down:
            navigating = true
            if highlighted < rows.count - 1 { highlighted += 1 }
        case .toggle:
            if rows.indices.contains(highlighted) { activate(rows[highlighted]) }
        case .submit:
            if rows.indices.contains(highlighted) { activate(rows[highlighted]) }
        case .cancel:
            dismiss()
        }
    }

    /// A tag row toggles the tag for every face (mixed or off: add, on: remove); the create row creates and assigns.
    private func activate(_ row: Row) {
        switch row {
        case .tag(let id):
            guard map != nil else { return }
            let state = states[id] ?? .off
            let adding = state != .on
            var updated = map ?? [:]
            for face in faces {
                if adding { updated[face, default: []].insert(id) } else { updated[face]?.remove(id) }
            }
            map = updated
            let faces = faces
            Task { await model.toggleTag(id, onFaces: faces, from: state) }
        case .create(let name):
            let faces = faces
            Task {
                guard let id = await model.createTagAndAssign(name: name, faces: faces) else { return }
                var updated = map ?? [:]
                for face in faces { updated[face, default: []].insert(id) }
                map = updated
                query = ""
            }
        }
    }
}

/// The panel's search field: an `NSTextField` so ↑/↓, Tab, Return, Esc and Space reach the panel.
struct TagPanelField: NSViewRepresentable {
    enum Command { case up, down, toggle, submit, cancel }

    @Binding var text: String
    let placeholder: String
    /// Whether a Space toggles the highlighted tag instead of typing a space.
    let spaceToggles: () -> Bool
    let onCommand: (Command) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> FocusingTextField {
        let field = FocusingTextField()
        field.placeholderString = placeholder
        field.delegate = context.coordinator
        field.bezelStyle = .roundedBezel
        field.focusRingType = .default
        field.stringValue = text
        context.coordinator.field = field
        context.coordinator.installSpaceMonitor()
        return field
    }

    func updateNSView(_ field: FocusingTextField, context: Context) {
        context.coordinator.parent = self
        if field.stringValue != text { field.stringValue = text }
    }

    static func dismantleNSView(_ field: FocusingTextField, coordinator: Coordinator) {
        coordinator.removeSpaceMonitor()
    }

    /// Takes the keyboard as soon as it is in a window.
    final class FocusingTextField: NSTextField {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.window === window else { return }
                    window.makeFirstResponder(self)
                }
            }
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: TagPanelField
        weak var field: NSTextField?
        private var monitor: Any?

        init(_ parent: TagPanelField) { self.parent = parent }

        func controlTextDidChange(_ notification: Notification) {
            guard let field else { return }
            if parent.text != field.stringValue { parent.text = field.stringValue }
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.moveUp(_:)): parent.onCommand(.up)
            case #selector(NSResponder.moveDown(_:)): parent.onCommand(.down)
            case #selector(NSResponder.insertTab(_:)): parent.onCommand(.toggle)
            case #selector(NSResponder.insertBacktab(_:)): break
            case #selector(NSResponder.insertNewline(_:)): parent.onCommand(.submit)
            case #selector(NSResponder.cancelOperation(_:)): parent.onCommand(.cancel)
            default: return false
            }
            return true
        }

        /// Space while editing this field: toggles when `spaceToggles` says so, else types a space.
        func installSpaceMonitor() {
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                let handled = MainActor.assumeIsolated { () -> Bool in
                    guard let self, let field = self.field, let window = field.window, event.window === window,
                          event.charactersIgnoringModifiers == " ",
                          event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
                          let editor = field.currentEditor(), window.firstResponder === editor,
                          self.parent.spaceToggles() else { return false }
                    self.parent.onCommand(.toggle)
                    return true
                }
                return handled ? nil : event
            }
        }

        func removeSpaceMonitor() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }
    }
}
