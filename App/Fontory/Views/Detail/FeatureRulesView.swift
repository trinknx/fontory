import AppKit
import FontoryCore
import SwiftUI

/// The help of every "in context only" mark (verbatim, spec §22).
let contextOnlyHelp =
    "This substitution needs neighbouring letters, a language or other features; typing these characters alone won't produce it"

/// The substitutions of one expanded GSUB feature: a grid of rule cells (input → output glyphs), the check marks,
/// and a footer with the overflow notes and Copy Glyph. Output glyphs are selectable (⌘C copies), have a context menu
/// and drag out as SVG files.
///
/// Its content is a `Group`, so inside the Features tab's `LazyVStack` the rule grid and the footer are children of
/// that lazy stack (no plain `VStack` around the `LazyVGrid`, which would build every cell).
struct FeatureRulesView: View {
    let tag: String
    let model: FeatureRulesModel

    private static let columns = [GridItem(.adaptive(minimum: 120), spacing: 8, alignment: .topLeading)]

    var body: some View {
        Group {
            if model.phase == .failed {
                message("Could not read this feature's rules.")
            } else if let rules = model.rules(for: tag) {
                if rules.isUnreadable {
                    message("Could not read this feature's rules.")
                } else {
                    LazyVGrid(columns: Self.columns, alignment: .leading, spacing: 8) {
                        ForEach(rules.rules.indices, id: \.self) { i in
                            let rule = rules.rules[i]
                            RuleCell(tag: tag, rule: rule, model: model, state: model.cellState(for: rule, tag: tag))
                        }
                    }
                    RulesFooter(tag: tag, rules: rules, model: model)
                }
            } else {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    message("Reading rules…")
                }
            }
        }
        .padding(.leading, 18)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func message(_ text: String) -> some View {
        Text(text).font(.callout).foregroundStyle(.secondary)
    }
}

/// The overflow notes and Copy Glyph; the only view of the rules that observes the selection.
private struct RulesFooter: View {
    let tag: String
    let rules: GSUBFeatureRules
    let model: FeatureRulesModel

    var body: some View {
        let selected = model.selectedGlyph.flatMap { $0.tag == tag ? $0 : nil }
        HStack(spacing: 10) {
            if rules.totalCount > rules.rules.count {
                Text("and \(rules.totalCount - rules.rules.count) more")
            }
            if rules.isIncomplete {
                Text("Some rules not shown")
                    .help("This feature's lookups are too large or partly unreadable; the rules found are listed")
            }
            Spacer(minLength: 0)
            Button("Copy Glyph") {
                guard let selected else { return }
                Task { await model.copyGlyphAsync(selected.glyph) }
            }
            .controlSize(.small)
            .disabled(selected == nil)
            .help("Copy the selected glyph as an image; drag it out for a vector shape")
        }
        .font(.callout)
        .foregroundStyle(.secondary)
    }
}

/// One rule: the input as text (characters, else glyph names), an arrow, and its output glyphs; a mark below when
/// typing the input alone does not give the output. When only some alternates are "in context only", each of those
/// glyphs also gets an orange dot.
///
/// The body reads only this rule's `state` (statuses, selection), never the model's shared caches, so a check batch
/// or a click re-renders only the cells it changes. The check is asked for when the cell appears.
private struct RuleCell: View {
    let tag: String
    let rule: GSUBRule
    let model: FeatureRulesModel
    let state: RuleCellState

    var body: some View {
        let label = model.label(for: rule.input)
        let statuses = state.statuses
        let selected = state.selected
        let perGlyph = Self.marksPerGlyph(statuses)
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .center, spacing: 6) {
                Text(label)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .help(label)
                Text("→").foregroundStyle(.tertiary)
                CenteredFlow(spacing: 4) {
                    ForEach(glyphs, id: \.self) { item in
                        RuleOutputGlyph(item: item, model: model, isSelected: selected == item,
                                        contextMark: perGlyph ? statuses?[item.output] == .contextOnly : nil)
                    }
                }
            }
            if let mark = Self.mark(statuses) {
                Text(mark.text)
                    .font(.caption)
                    .foregroundStyle(mark.isContext ? AnyShapeStyle(Color.orange) : AnyShapeStyle(.secondary))
                    .help(mark.help)
            }
        }
        .padding(6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 6).fill(.quaternary.opacity(0.4)))
        .onAppear { model.requestCheck(rule, tag: tag) }
        .onChange(of: ObjectIdentifier(state)) { model.requestCheck(rule, tag: tag) }
    }

    /// Every output glyph; each glyph of a multiple substitution's sequence is its own item.
    private var glyphs: [RuleGlyph] {
        rule.outputs.enumerated().flatMap { o, sequence in
            sequence.indices.map { RuleGlyph(tag: tag, rule: rule, output: o, index: $0) }
        }
    }

    /// Whether the outputs differ in being "in context only", so the caption alone cannot say which alternate is.
    static func marksPerGlyph(_ statuses: [GSUBRuleStatus]?) -> Bool {
        guard let statuses, statuses.count > 1, statuses.contains(.contextOnly) else { return false }
        return !statuses.allSatisfy { $0 == .contextOnly }
    }

    static func mark(_ statuses: [GSUBRuleStatus]?) -> (text: String, help: String, isContext: Bool)? {
        guard let statuses else { return nil }
        if statuses.contains(.contextOnly) {
            return ("in context only", contextOnlyHelp, true)
        }
        if statuses.contains(.noCharacters) {
            return ("no characters", "The input glyphs have no characters, so this substitution cannot be typed or checked",
                    false)
        }
        return nil
    }
}

/// One output glyph, drawn in the primary text colour (colour glyphs in colour). Click selects it (accent ring) and
/// gives it the keyboard for ⌘C; right click shows the copy menu; dragging gives an SVG file (PNG for colour faces).
/// `contextMark` (when not nil) adds a row below: an orange dot when this alternate is "in context only".
private struct RuleOutputGlyph: View {
    let item: RuleGlyph
    let model: FeatureRulesModel
    let isSelected: Bool
    var contextMark: Bool?

    @Environment(\.displayScale) private var scale
    @Environment(\.colorScheme) private var colorScheme
    @State private var image: CGImage?

    static let pointSize: CGFloat = 40
    static let maxHeight: CGFloat = 72

    private struct Key: Equatable {
        let glyph: CGGlyph
        let faceVersion: Int
        let scale: CGFloat
        let dark: Bool
    }

    var body: some View {
        VStack(spacing: 1) {
            glyphView
            if let contextMark {
                Circle()
                    .fill(Color.orange)
                    .frame(width: 5, height: 5)
                    .opacity(contextMark ? 1 : 0)
                    .help(contextMark ? contextOnlyHelp : "")
                    .accessibilityHidden(true)
            }
        }
    }

    private var glyphView: some View {
        let glyph = item.glyph
        return Group {
            if let image {
                let natural = CGSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale)
                let fit = min(1, Self.maxHeight / max(natural.height, 1))
                Image(decorative: image, scale: scale)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: natural.width * fit, height: natural.height * fit)
            } else {
                Color.clear.frame(width: 24, height: 52)
            }
        }
        .padding(2)
        .overlay {
            RoundedRectangle(cornerRadius: 5)
                .strokeBorder(Color.accentColor, lineWidth: 2)
                .opacity(isSelected ? 1 : 0)
        }
        .overlay {
            GlyphInteraction(
                help: contextMark == true ? "In context only. " + contextOnlyHelp
                    : "Drag into Pixelmator Pro for a vector shape",
                accessibilityLabel: "Glyph \(model.label(for: [glyph]))" + (contextMark == true ? ", in context only" : ""),
                image: image.map { NSImage(cgImage: $0, size: NSSize(width: CGFloat($0.width) / scale,
                                                                       height: CGFloat($0.height) / scale)) },
                select: { model.select(item) },
                copy: { Task { await model.copyGlyphAsync(glyph) } },
                dragItem: { model.dragItem(for: glyph) },
                menu: { menu(glyph) })
        }
        .task(id: Key(glyph: glyph, faceVersion: model.faceVersion, scale: scale, dark: colorScheme == .dark)) {
            let rendered = await model.glyphImage(glyph, pointSize: Self.pointSize, scale: scale,
                                                  dark: colorScheme == .dark)
            if !Task.isCancelled { image = rendered }
        }
    }

    private func menu(_ glyph: CGGlyph) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.addItem(ClosureMenuItem("Copy Glyph") { Task { await model.copyGlyphAsync(glyph) } })
        let characters = ClosureMenuItem("Copy Characters") { _ = model.copyCharacters(item.rule) }
        characters.isEnabled = model.characters(for: item.rule) != nil
        menu.addItem(characters)
        let svg = ClosureMenuItem("Copy SVG Code") { _ = model.copySVGCode(glyph) }
        svg.isEnabled = model.hasOutline(glyph)
        menu.addItem(svg)
        return menu
    }
}

/// The AppKit layer over an output glyph: click, ⌘C (as first responder), the context menu and the file-promise drag
/// (SwiftUI's `onDrag` takes only item providers, not the `NSFilePromiseProvider` the drag needs).
private struct GlyphInteraction: NSViewRepresentable {
    let help: String
    let accessibilityLabel: String
    let image: NSImage?
    let select: @MainActor () -> Void
    let copy: @MainActor () -> Void
    let dragItem: @MainActor () -> NSPasteboardWriting?
    let menu: @MainActor () -> NSMenu

    func makeNSView(context: Context) -> GlyphInteractionView {
        let view = GlyphInteractionView()
        update(view)
        return view
    }

    func updateNSView(_ view: GlyphInteractionView, context: Context) {
        update(view)
    }

    private func update(_ view: GlyphInteractionView) {
        view.toolTip = help
        view.setAccessibilityLabel(accessibilityLabel)
        view.image = image
        view.onSelect = select
        view.onCopy = copy
        view.makeDragItem = dragItem
        view.makeMenu = menu
    }
}

final class GlyphInteractionView: NSView, NSDraggingSource {
    var image: NSImage?
    var onSelect: (@MainActor () -> Void)?
    var onCopy: (@MainActor () -> Void)?
    var makeDragItem: (@MainActor () -> NSPasteboardWriting?)?
    var makeMenu: (@MainActor () -> NSMenu)?

    private var downPoint: NSPoint?

    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        downPoint = convert(event.locationInWindow, from: nil)
        onSelect?()
        window?.makeFirstResponder(self)
    }

    override func mouseUp(with event: NSEvent) {
        downPoint = nil
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = downPoint else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard hypot(point.x - start.x, point.y - start.y) > 3 else { return }
        downPoint = nil
        guard let writer = makeDragItem?() else { return }
        let item = NSDraggingItem(pasteboardWriter: writer)
        let frame = image.map { image in
            NSRect(x: (bounds.width - image.size.width) / 2, y: (bounds.height - image.size.height) / 2,
                   width: image.size.width, height: image.size.height)
        } ?? bounds
        item.setDraggingFrame(frame, contents: image)
        beginDraggingSession(with: [item], event: event, source: self)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        onSelect?()
        window?.makeFirstResponder(self)
        return makeMenu?()
    }

    @objc func copy(_ sender: Any?) {
        onCopy?()
    }

    override func accessibilityPerformPress() -> Bool {
        onSelect?()
        window?.makeFirstResponder(self)
        return true
    }

    func draggingSession(_ session: NSDraggingSession,
                         sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        .copy
    }
}

extension GlyphInteractionView: NSMenuItemValidation {
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(copy(_:)) { return onCopy != nil }
        return true
    }
}

/// Lays its subviews out left to right, wrapping when the width runs out; each line's items are centred vertically.
private struct CenteredFlow: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let frames = place(subviews, width: proposal.width ?? .infinity)
        return CGSize(width: frames.map(\.maxX).max() ?? 0, height: frames.map(\.maxY).max() ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (frame, subview) in zip(place(subviews, width: bounds.width), subviews) {
            subview.place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY), proposal: .unspecified)
        }
    }

    private func place(_ subviews: Subviews, width: CGFloat) -> [CGRect] {
        var frames: [CGRect] = []
        var line: [Int] = []
        var x: CGFloat = 0, y: CGFloat = 0, lineHeight: CGFloat = 0
        func closeLine() {
            for i in line { frames[i].origin.y = y + (lineHeight - frames[i].height) / 2 }
            y += lineHeight + spacing
            line = []
            x = 0
            lineHeight = 0
        }
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > width { closeLine() }
            frames.append(CGRect(origin: CGPoint(x: x, y: 0), size: size))
            line.append(frames.count - 1)
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
        if !line.isEmpty { closeLine() }
        return frames
    }
}
