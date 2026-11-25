import AppKit
import FontoryCore
import UniformTypeIdentifiers

/// The Features tab's GSUB rules: per-feature counts of a face and selection, the rules of expanded features, and the
/// CoreText check of the rules on screen. Parsing, checking and rendering stay off the main actor; every result is
/// published only while it still belongs to the latest `load` (generation counter).
@MainActor @Observable
final class FeatureRulesModel {
    enum Phase: Equatable { case idle, reading, ready, failed }

    private(set) var phase: Phase = .idle
    /// GSUB tags of the current selection with at least one rule, and their counts.
    private(set) var counts: [String: Int] = [:]
    private(set) var hasAATLayout = false
    /// The output glyph the user clicked (set through `select`); cleared by `load`. Only the footer observes it; each
    /// rule cell observes its own `RuleCellState`.
    private(set) var selectedGlyph: RuleGlyph?
    /// Bumped by every `load`, so views keyed on it drop images of the previous face.
    private(set) var faceVersion = 0

    /// Published rules per tag (observed, so the list appears when read).
    private var rulesByTag: [String: GSUBFeatureRules] = [:]
    /// Per-rule statuses and selection. The dictionary is not observed; each cell observes only its own state, so a
    /// check batch or a click re-renders the cells it touches, not every cell on screen.
    @ObservationIgnored private var cellStates: [StatusKey: RuleCellState] = [:]

    @ObservationIgnored private let renderer: PreviewRenderer
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var face: Face?
    @ObservationIgnored private var labels: GlyphLabels?
    @ObservationIgnored private var selection: LayoutSelection = .all
    @ObservationIgnored private var language: String?
    /// Tags whose rules are being read.
    @ObservationIgnored private var reading: Set<String> = []
    /// Rules asked for and not yet checked; `queued` covers them and the batch in flight.
    @ObservationIgnored private var pending: [StatusKey] = []
    @ObservationIgnored private var queued: Set<StatusKey> = []
    @ObservationIgnored private var flushScheduled = false
    @ObservationIgnored private let promiseWriter = GlyphPromiseWriter()
    /// Rendered output glyphs of the current face, oldest first in `imageOrder`; bounded (the oldest quarter is
    /// dropped at the limit), cleared by `load`.
    @ObservationIgnored private var images: [ImageKey: ImageBox] = [:]
    @ObservationIgnored private var imageOrder: [ImageKey] = []
    /// Renders in flight, shared by every cell asking for the same image.
    @ObservationIgnored private var rendering: [ImageKey: Task<ImageBox, Never>] = [:]
    private static let imageCacheLimit = 600

    init(renderer: PreviewRenderer) {
        self.renderer = renderer
    }

    // MARK: Loading

    /// Loads the face's GSUB off the main thread; a newer call wins (generation counter).
    func load(fileURL: URL, faceIndex: Int, selection: LayoutSelection) async {
        generation &+= 1
        let current = generation
        face = nil
        labels = nil
        self.selection = selection
        if case .languageSystem(_, let lang?) = selection {
            language = FeatureCatalog.languageCode(lang)
        } else {
            language = nil
        }
        reading = []
        pending = []
        queued = []
        rulesByTag = [:]
        cellStates = [:]
        images = [:]
        imageOrder = []
        rendering = [:]
        selectedGlyph = nil
        faceVersion = current
        counts = [:]
        hasAATLayout = false
        phase = .reading

        let renderer = renderer
        let loaded = await Task.detached(priority: .userInitiated) { () -> Loaded? in
            guard let font = renderer.font(fileURL: fileURL, faceIndex: faceIndex, pointSize: 1) else { return nil }
            let reader = GSUBRuleReader.read(font)
            let labels = GlyphLabels(font: font)
            return Loaded(face: Face(font: font, reader: reader), labels: labels,
                          counts: reader?.counts(selection: selection) ?? [:],
                          hasAATLayout: GSUBRuleCheck.hasAATLayout(font))
        }.value
        guard current == generation else { return }
        guard let loaded else {
            phase = .failed
            return
        }
        face = loaded.face
        labels = loaded.labels
        counts = loaded.counts
        hasAATLayout = loaded.hasAATLayout
        phase = .ready
    }

    // MARK: Rules

    /// Rules of an expanded tag; nil while reading (reads off main on first call).
    func rules(for tag: String) -> GSUBFeatureRules? {
        if let rules = rulesByTag[tag] { return rules }
        guard let reader = face?.reader, !reading.contains(tag) else { return nil }
        reading.insert(tag)
        let current = generation, selection = selection
        Task { [weak self] in
            let rules = await Task.detached(priority: .userInitiated) {
                reader.rules(for: tag, selection: selection)
            }.value
            guard let self, current == self.generation else { return }
            self.reading.remove(tag)
            self.rulesByTag[tag] = rules
        }
        return nil
    }

    /// The observable state of one rule's cell (statuses, selected glyph); made on first use, replaced by `load`.
    /// Never schedules work, so a view body may call it.
    func cellState(for rule: GSUBRule, tag: String) -> RuleCellState {
        let key = StatusKey(tag: tag, rule: rule)
        if let state = cellStates[key] { return state }
        let state = RuleCellState()
        if let selectedGlyph, selectedGlyph.tag == tag, selectedGlyph.rule == rule { state.selected = selectedGlyph }
        cellStates[key] = state
        return state
    }

    /// Schedules the check of a rule on screen (batched, off main, cached); the result lands in its `cellState`.
    func requestCheck(_ rule: GSUBRule, tag: String) {
        let key = StatusKey(tag: tag, rule: rule)
        guard face != nil, cellStates[key]?.statuses == nil, !queued.contains(key) else { return }
        queued.insert(key)
        pending.append(key)
        scheduleFlush()
    }

    /// Statuses for a rule; nil until checked. Calling it schedules the check (see `requestCheck`).
    func statuses(for rule: GSUBRule, tag: String) -> [GSUBRuleStatus]? {
        requestCheck(rule, tag: tag)
        return cellStates[StatusKey(tag: tag, rule: rule)]?.statuses
    }

    /// Selects an output glyph (nil clears), updating only the cells it leaves and enters.
    func select(_ item: RuleGlyph?) {
        guard item != selectedGlyph else { return }
        if let old = selectedGlyph { cellStates[StatusKey(tag: old.tag, rule: old.rule)]?.selected = nil }
        selectedGlyph = item
        if let item { cellState(for: item.rule, tag: item.tag).selected = item }
    }

    /// Runs the rules requested in this main-actor turn as one detached batch.
    private func scheduleFlush() {
        guard !flushScheduled else { return }
        flushScheduled = true
        Task { [weak self] in
            await Task.yield()
            self?.flush()
        }
    }

    private func flush() {
        flushScheduled = false
        guard let face, let labels, !pending.isEmpty else { return }
        let batch = pending
        pending = []
        let current = generation, language = language
        Task { [weak self] in
            let results = await Task.detached(priority: .userInitiated) { () -> [StatusKey: [GSUBRuleStatus]] in
                var out: [StatusKey: [GSUBRuleStatus]] = [:]
                for key in batch {
                    out[key] = GSUBRuleCheck.check(key.rule, tag: key.tag, font: face.font, labels: labels,
                                                   language: language)
                }
                return out
            }.value
            guard let self, current == self.generation else { return }
            for (key, statuses) in results {
                self.cellState(for: key.rule, tag: key.tag).statuses = statuses
            }
            self.queued.subtract(results.keys)
        }
    }

    // MARK: Glyph images

    /// `glyph` drawn at `pointSize` (in points; the bitmap is `scale` times larger) in the primary text colour of the
    /// appearance, colour glyphs in colour, on a transparent background. The box spans the face's ascent and descent
    /// (grown to the ink) so a rule's glyphs line up. Renders off the main actor; cached; nil when the face changed
    /// meanwhile or there is no face. Cells asking for an image already rendering share that render.
    func glyphImage(_ glyph: CGGlyph, pointSize: CGFloat, scale: CGFloat, dark: Bool) async -> CGImage? {
        let key = ImageKey(glyph: glyph, pointSize: pointSize, scale: scale, dark: dark)
        if let cached = images[key] { return cached.image }
        guard let face else { return nil }
        let current = generation
        let task: Task<ImageBox, Never>
        if let running = rendering[key] {
            task = running
        } else {
            task = Task.detached(priority: .userInitiated) {
                ImageBox(image: Self.renderGlyph(font: face.font, glyph: glyph, pointSize: pointSize, scale: scale,
                                                 foreground: CGColor(gray: dark ? 1 : 0, alpha: 0.85)))
            }
            rendering[key] = task
        }
        let rendered = await task.value
        guard current == generation else { return nil }
        if rendering[key] == task { rendering[key] = nil }
        if images[key] == nil {
            if images.count >= Self.imageCacheLimit {
                let dropped = imageOrder.prefix(Self.imageCacheLimit / 4)
                for old in dropped { images[old] = nil }
                imageOrder.removeFirst(dropped.count)
            }
            images[key] = rendered
            imageOrder.append(key)
        }
        return rendered.image
    }

    /// Cached images and renders in flight (smoke checks).
    var imageCacheCountForSmoke: (images: Int, rendering: Int) { (images.count, rendering.count) }

    /// Pure: see `glyphImage`. At least a quarter em wide, so an inkless glyph (space) still shows a cell.
    nonisolated static func renderGlyph(font: CTFont, glyph: CGGlyph, pointSize: CGFloat, scale: CGFloat,
                                        foreground: CGColor) -> CGImage? {
        guard pointSize > 0, scale > 0 else { return nil }
        let sized = CTFontCreateCopyWithAttributes(font, pointSize, nil, nil)
        var g = glyph
        var advance = CGSize.zero
        CTFontGetAdvancesForGlyphs(sized, .horizontal, &g, &advance, 1)
        var ink = CGRect.zero
        CTFontGetBoundingRectsForGlyphs(sized, .horizontal, &g, &ink, 1)
        let hasInk = !ink.isNull && !ink.isInfinite && ink.width > 0 && ink.height > 0
            && ink.minX.isFinite && ink.minY.isFinite && ink.width.isFinite && ink.height.isFinite
        let advanceWidth = advance.width.isFinite ? advance.width : 0
        let limit = pointSize * 8
        let left = max(-limit, hasInk ? min(0, ink.minX) : 0)
        let right = min(limit, max(advanceWidth, hasInk ? ink.maxX : 0, pointSize * 0.25))
        let top = min(limit, max(CTFontGetAscent(sized), hasInk ? ink.maxY : 0))
        let bottom = min(limit, max(CTFontGetDescent(sized), hasInk ? -ink.minY : 0))
        let pad: CGFloat = 2
        let width = Int(((right - left + 2 * pad) * scale).rounded(.up))
        let height = Int(((top + bottom + 2 * pad) * scale).rounded(.up))
        guard width > 0, height > 0,
              let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.scaleBy(x: scale, y: scale)
        ctx.setAllowsAntialiasing(true)
        ctx.setShouldAntialias(true)
        ctx.setFillColor(foreground)
        var position = CGPoint(x: pad - left, y: pad + bottom)
        CTFontDrawGlyphs(sized, &g, &position, 1, ctx)
        return ctx.makeImage()
    }

    /// Whether the glyph has an exportable outline (Copy SVG Code); false for every glyph of a colour or bitmap face.
    func hasOutline(_ glyph: CGGlyph) -> Bool {
        guard let font = face?.font else { return false }
        return GlyphSVG.hasExportableOutline(font: font, glyph: glyph)
    }

    // MARK: Labels

    /// The glyphs' labels (character, else glyph name, else #gid) joined by spaces.
    func label(for glyphs: [CGGlyph]) -> String {
        glyphs.map { labels?.label(for: $0) ?? "#\($0)" }.joined(separator: " ")
    }

    /// The text of the rule's input, when every input glyph has a character.
    func characters(for rule: GSUBRule) -> String? {
        labels?.characters(for: rule.input)
    }

    // MARK: Copy and drag

    /// PNG + SVG, no text (see `GlyphExport.copyGlyph`). False when nothing was written.
    func copyGlyph(_ glyph: CGGlyph, to pasteboard: NSPasteboard = .general) -> Bool {
        guard let font = face?.font else { return false }
        return GlyphExport.copyGlyph(font: font, glyph: glyph, to: pasteboard)
    }

    /// Copy Glyph for the UI: renders the PNG and SVG off the main actor, then writes; beeps when there is neither.
    @discardableResult
    func copyGlyphAsync(_ glyph: CGGlyph, to pasteboard: NSPasteboard = .general) async -> Bool {
        guard let face else {
            NSSound.beep()
            return false
        }
        return await GlyphExport.copyGlyphAsync(font: { face.font }, glyph: glyph, to: pasteboard)
    }

    /// The rule's input as plain text. False when it has no characters.
    func copyCharacters(_ rule: GSUBRule, to pasteboard: NSPasteboard = .general) -> Bool {
        guard let text = characters(for: rule), !text.isEmpty else { return false }
        pasteboard.clearContents()
        return pasteboard.setString(text, forType: .string)
    }

    /// The glyph's SVG document as plain text. False when the glyph has no outline.
    func copySVGCode(_ glyph: CGGlyph, to pasteboard: NSPasteboard = .general) -> Bool {
        guard let font = face?.font, let svg = GlyphSVG.exportDocument(font: font, glyph: glyph) else { return false }
        return GlyphExport.copySVGCode(svg, to: pasteboard)
    }

    /// File promise provider for dragging `glyph` out: SVG file, or PNG for colour/bitmap glyphs; no string item.
    /// nil for an inkless glyph (zero bounds, e.g. space), which has nothing to drag.
    func dragItem(for glyph: CGGlyph) -> NSPasteboardWriting? {
        guard let face else { return nil }
        let font = face.font
        var g = glyph
        let bounds = CTFontGetBoundingRectsForGlyphs(font, .default, &g, nil, 1)
        guard bounds.width > 0, bounds.height > 0 else { return nil }
        let psName = CTFontCopyPostScriptName(font) as String
        let glyphName = CTFontCopyGraphicsFont(font, nil).name(for: glyph) as String?
        let scalar = labels?.character(for: glyph)?.unicodeScalars.first?.value
        let provider: GlyphPromiseProvider
        if let svg = GlyphSVG.exportDocument(font: font, glyph: glyph) {
            provider = GlyphPromiseProvider(fileType: UTType.svg.identifier, delegate: promiseWriter)
            provider.userInfo = GlyphPromiseProvider.Payload(
                fileName: GlyphExport.fileName(postScriptName: psName, glyphName: glyphName, scalar: scalar,
                                               glyph: glyph, extension: "svg"),
                svg: svg)
        } else {
            // Colour or bitmap face (its outlines are only a fallback): the PNG renders on the promise writer's queue when the drop asks for it.
            provider = GlyphPromiseProvider(fileType: UTType.png.identifier, delegate: promiseWriter)
            provider.userInfo = GlyphPromiseProvider.Payload(
                fileName: GlyphExport.fileName(postScriptName: psName, glyphName: glyphName, scalar: scalar,
                                               glyph: glyph, extension: "png"),
                contents: { GlyphImage.png(font: face.font, glyph: glyph) })
        }
        return provider
    }
}

/// What one rule cell shows that changes after it appears: the check's statuses (nil until checked) and the selected
/// output glyph of this rule, if any.
@MainActor @Observable
final class RuleCellState {
    var statuses: [GSUBRuleStatus]?
    var selected: RuleGlyph?
}

/// One output glyph of a rule on screen: the rule's `output`-th output, its `index`-th glyph.
struct RuleGlyph: Hashable {
    let tag: String
    let rule: GSUBRule
    let output: Int
    let index: Int

    var glyph: CGGlyph { rule.outputs[output][index] }
}

private struct ImageKey: Hashable {
    let glyph: CGGlyph
    let pointSize: CGFloat
    let scale: CGFloat
    let dark: Bool
}

/// A cached check: rules are compared by value, so the tag keeps equal rules of different features apart.
private struct StatusKey: Hashable, Sendable {
    let tag: String
    let rule: GSUBRule
}

/// The loaded face; `CTFont` is immutable and safe to share across threads.
private struct Face: @unchecked Sendable {
    let font: CTFont
    let reader: GSUBRuleReader?
}

private struct Loaded: Sendable {
    let face: Face
    let labels: GlyphLabels
    let counts: [String: Int]
    let hasAATLayout: Bool
}
