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
    /// Expanded feature tags, kept for the session across faces.
    var expanded: Set<String> = []

    /// Published rules per tag and statuses per rule (observed, so rows update as results arrive).
    private var rulesByTag: [String: GSUBFeatureRules] = [:]
    private var statusCache: [StatusKey: [GSUBRuleStatus]] = [:]

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
        statusCache = [:]
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

    /// Statuses for a visible rule; nil until checked. Calling it schedules the check (batched, off main, cached).
    func statuses(for rule: GSUBRule, tag: String) -> [GSUBRuleStatus]? {
        let key = StatusKey(tag: tag, rule: rule)
        if let statuses = statusCache[key] { return statuses }
        guard face != nil, !queued.contains(key) else { return nil }
        queued.insert(key)
        pending.append(key)
        scheduleFlush()
        return nil
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
            self.statusCache.merge(results) { _, new in new }
            self.queued.subtract(results.keys)
        }
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

    /// The rule's input as plain text. False when it has no characters.
    func copyCharacters(_ rule: GSUBRule, to pasteboard: NSPasteboard = .general) -> Bool {
        guard let text = characters(for: rule), !text.isEmpty else { return false }
        pasteboard.clearContents()
        return pasteboard.setString(text, forType: .string)
    }

    /// The glyph's SVG document as plain text. False when the glyph has no outline.
    func copySVGCode(_ glyph: CGGlyph, to pasteboard: NSPasteboard = .general) -> Bool {
        guard let font = face?.font, let svg = GlyphSVG.document(font: font, glyph: glyph) else { return false }
        return GlyphExport.copySVGCode(svg, to: pasteboard)
    }

    /// File promise provider for dragging `glyph` out: SVG file, or PNG for colour/bitmap glyphs; no string item.
    func dragItem(for glyph: CGGlyph) -> NSPasteboardWriting? {
        guard let face else { return nil }
        let font = face.font
        let psName = CTFontCopyPostScriptName(font) as String
        let glyphName = CTFontCopyGraphicsFont(font, nil).name(for: glyph) as String?
        let scalar = labels?.character(for: glyph)?.unicodeScalars.first?.value
        let provider: GlyphPromiseProvider
        if let svg = GlyphSVG.document(font: font, glyph: glyph) {
            provider = GlyphPromiseProvider(fileType: UTType.svg.identifier, delegate: promiseWriter)
            provider.userInfo = GlyphPromiseProvider.Payload(
                fileName: GlyphExport.fileName(postScriptName: psName, glyphName: glyphName, scalar: scalar,
                                               glyph: glyph, extension: "svg"),
                svg: svg)
        } else {
            // Colour or bitmap glyph: the PNG renders on the promise writer's queue when the drop asks for it.
            provider = GlyphPromiseProvider(fileType: UTType.png.identifier, delegate: promiseWriter)
            provider.userInfo = GlyphPromiseProvider.Payload(
                fileName: GlyphExport.fileName(postScriptName: psName, glyphName: glyphName, scalar: scalar,
                                               glyph: glyph, extension: "png"),
                contents: { GlyphImage.png(font: face.font, glyph: glyph) })
        }
        return provider
    }
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
