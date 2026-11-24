import AppKit
import FontoryCore
import Observation

/// The Compare window's state: reference face A, candidate B cycled through candidate families, the text, the
/// options and the rendered scene. Fonts resolve and render off the main thread, one render at a time.
@MainActor @Observable
final class CompareModel: CandidateStripSource {
    nonisolated static let windowID = "compare"
    nonisolated static let maxRecentTexts = 5
    nonisolated static let noFontsMessage = "Select fonts or add some to the Quick Collection, then press ⌥⌘K."
    nonisolated static let presets: [String] = [
        "Hamburgefonstiv 0123", "Tiếng Việt: Ẩm ướt, Ặc ợ, Hữu ích", "ABCDEFGHIJKLMNOPQRSTUVWXYZ",
        "abcdefghijklmnopqrstuvwxyz", "0123456789 $€%&",
    ]

    enum Key {
        static let text = "compare.text", recentTexts = "compare.recentTexts", mode = "compare.mode"
        static let sizeRule = "compare.sizeRule", outlines = "compare.outlines", guides = "compare.guides"
    }

    // MARK: State

    var a: FontReference?
    var b: FontReference?
    var candidates: [FontReference] = []
    private(set) var text: String
    private(set) var recentTexts: [String]
    private(set) var options: CompareOptions
    private(set) var scene: CompareScene?
    private(set) var renderedImage: CGImage?
    var fontsVersion = 0
    /// The no-fonts copy while there is nothing to compare, nil otherwise.
    private(set) var emptyMessage: String?
    @ObservationIgnored var fontStore: @MainActor () -> FontStore? = { nil }
    var isKey = false

    // MARK: Private

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var canvas: CGSize = .zero
    @ObservationIgnored private var scale: CGFloat = 1
    @ObservationIgnored private var renderTask: Task<Void, Never>?
    @ObservationIgnored private var renderPending = false
    @ObservationIgnored private var pairingChain: Task<Void, Never>?
    @ObservationIgnored private var resolved: [FontReference: ResolvedFont] = [:]
    @ObservationIgnored private var familyStyleCache: [String: [PairingStyle]] = [:]
    @ObservationIgnored private var cacheGeneration = 0
    @ObservationIgnored private var candidateImageCache: [LayoutsModel.CandidateImageKey: CGImage] = [:]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        text = defaults.string(forKey: Key.text) ?? Self.presets[0]
        recentTexts = Array((defaults.stringArray(forKey: Key.recentTexts) ?? []).prefix(Self.maxRecentTexts))
        options = CompareOptions(
            mode: defaults.string(forKey: Key.mode).flatMap(CompareMode.init(rawValue:)) ?? .overlay,
            sizeRule: defaults.string(forKey: Key.sizeRule).flatMap(CompareSizeRule.init(rawValue:)) ?? .sameSize,
            outlines: defaults.object(forKey: Key.outlines) as? Bool ?? false,
            guides: defaults.object(forKey: Key.guides) as? Bool ?? true)
    }

    // MARK: Opening

    /// Replaces A, B and the candidates: A is `referenceFaceID`'s face (else the first candidate's), the candidates
    /// are one per family of `candidateFaceIDs` except A's, and B is the first candidate's style closest to A.
    func open(referenceFaceID: Int64?, candidateFaceIDs: [Int64], text newText: String? = nil) async {
        if let newText { setText(newText) }
        var ids = candidateFaceIDs
        let referenceID: Int64? = referenceFaceID ?? (ids.isEmpty ? nil : ids.removeFirst())
        guard let referenceID, let store = fontStore() else {
            a = nil; b = nil; candidates = []
            emptyMessage = Self.noFontsMessage
            renderedImage = nil; scene = nil
            return
        }
        let found = await Task.detached(priority: .userInitiated) { () -> (FontReference, [FontReference])? in
            guard let ref = try? store.reference(forFace: referenceID) else { return nil }
            return (ref, (try? store.candidateReferences(faceIDs: ids)) ?? [])
        }.value
        guard let (ref, refs) = found else {
            a = nil; b = nil; candidates = []
            emptyMessage = Self.noFontsMessage
            renderedImage = nil; scene = nil
            return
        }
        emptyMessage = nil
        a = ref
        candidates = PairingCycler.merge([], adding: refs).filter { $0.family.lowercased() != ref.family.lowercased() }
        if let first = candidates.first { b = await closestStyle(in: first, to: ref) } else { b = nil }
        refreshRender()
    }

    /// The family of A goes into the candidates (if not there), B's face becomes A and A's face becomes B.
    func swap() async {
        guard let oldA = a, let oldB = b, let store = fontStore() else { return }
        let representative = await Task.detached(priority: .userInitiated) { () -> FontReference? in
            guard let face = (try? store.resolve([oldA]))?[oldA]?.faceID else { return nil }
            return try? store.candidateReferences(faceIDs: [face]).first
        }.value
        candidates = PairingCycler.merge(candidates, adding: [representative ?? oldA])
        a = oldB
        b = oldA
        refreshRender()
    }

    // MARK: Text and options

    /// Sets the text (remembered) and, when it is a custom one, pushes it to the front of the recent texts.
    func setText(_ s: String) {
        text = s
        defaults.set(s, forKey: Key.text)
        if !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !Self.presets.contains(s) {
            recentTexts.removeAll { $0 == s }
            recentTexts.insert(s, at: 0)
            if recentTexts.count > Self.maxRecentTexts { recentTexts.removeLast(recentTexts.count - Self.maxRecentTexts) }
            defaults.set(recentTexts, forKey: Key.recentTexts)
        }
        refreshRender()
    }

    func setOptions(_ o: CompareOptions) {
        guard o != options else { return }
        options = o
        defaults.set(o.mode.rawValue, forKey: Key.mode)
        defaults.set(o.sizeRule.rawValue, forKey: Key.sizeRule)
        defaults.set(o.outlines, forKey: Key.outlines)
        defaults.set(o.guides, forKey: Key.guides)
        refreshRender()
    }

    func canvasDidResize(_ size: CGSize, scale newScale: CGFloat) {
        guard size != canvas || newScale != scale else { return }
        canvas = size
        scale = newScale
        refreshRender()
    }

    /// Re-resolves every font (the library may have changed, e.g. a drive came back) and re-renders.
    func refreshFonts() {
        cacheGeneration += 1
        familyStyleCache = [:]
        candidateImageCache = [:]
        resolved = [:]
        fontsVersion += 1
        refreshRender()
    }

    // MARK: Cycling

    /// ←/→ B's family, ↑/↓ B's style, ⇧↑/⇧↓ A's style.
    func cycle(_ key: CycleKey) {
        enqueue { model in
            switch key {
            case .family(let step):
                guard let a = model.a else { return }
                let next = PairingCycler.nextFamily(from: model.b ?? a, candidates: model.candidates, step: step)
                guard let next else { return }
                let chosen = await model.closestStyle(in: next, to: a)
                model.b = chosen
                model.refreshRender()
            case .style(let step):
                guard let b = model.b else { return }
                let next = PairingCycler.nextStyle(current: b, styles: await model.familyStyles(of: b), step: step)
                guard next != b else { return }
                model.b = next
                model.refreshRender()
            case .referenceStyle(let step):
                guard let a = model.a else { return }
                let next = PairingCycler.nextStyle(current: a, styles: await model.familyStyles(of: a), step: step)
                guard next != a else { return }
                model.a = next
                model.refreshRender()
            }
        }
    }

    // MARK: Copy

    /// A 2× PNG of the canvas on the general pasteboard; false when nothing is drawn.
    @discardableResult
    func copyImage() -> Bool {
        guard let scene, scene.a.path != nil || scene.b.path != nil else { return false }
        let (colorA, colorB, guide, background) = Self.colors()
        guard let image = CompareRenderer.image(scene, options: options, colorA: colorA, colorB: colorB, guideColor: guide,
                                                background: background, scale: 2),
              let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { return false }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        return pasteboard.setData(png, forType: .png)
    }

    // MARK: Rendering

    private func refreshRender() {
        guard a != nil, canvas.width > 0, canvas.height > 0 else { return }
        if renderTask != nil {
            renderPending = true
            return
        }
        startRender()
    }

    private func startRender() {
        guard let a, canvas.width > 0, canvas.height > 0 else { return }
        renderPending = false
        let b = b, text = text, options = options, canvas = canvas, scale = scale
        let store = fontStore()
        let known = resolved
        let cacheGen = cacheGeneration
        let (colorA, colorB, guide, _) = Self.colors()
        renderTask = Task { [weak self] in
            let aLabel = await self?.label(for: a) ?? a.family
            let bLabel: String
            if let b { bLabel = await self?.label(for: b) ?? b.family } else { bLabel = "" }
            let wanted = [a] + (b.map { [$0] } ?? [])
            let missing = wanted.filter { known[$0] == nil }
            var fonts = known
            if let store, !missing.isEmpty {
                let found = await Task.detached(priority: .userInitiated) { try? store.resolve(missing) }.value ?? [:]
                fonts.merge(found) { _, new in new }
                if let self, cacheGen == self.cacheGeneration { self.resolved.merge(found) { _, new in new } }
            }
            let fontA = fonts[a] ?? ResolvedFont(reference: a, faceID: nil, url: nil, faceIndex: 0, isMissing: true)
            let fontB = b.map { fonts[$0] ?? ResolvedFont(reference: $0, faceID: nil, url: nil, faceIndex: 0, isMissing: true) }
            let out = await Task.detached(priority: .userInitiated) { () -> (CompareScene, CompareImageBox?) in
                let scene = CompareRenderer.scene(a: fontA, aLabel: aLabel, b: fontB, bLabel: bLabel, text: text,
                                                  options: options, canvas: canvas)
                let image = CompareRenderer.image(scene, options: options, colorA: colorA, colorB: colorB, guideColor: guide,
                                                  background: nil, scale: scale)
                return (scene, image.map(CompareImageBox.init))
            }.value
            self?.renderFinished(scene: out.0, image: out.1?.image)
        }
    }

    private func renderFinished(scene newScene: CompareScene, image: CGImage?) {
        renderTask = nil
        // Nothing to show any more (opened with no fonts meanwhile).
        guard a != nil else { renderPending = false; return }
        scene = newScene
        renderedImage = image
        if renderPending { startRender() }
    }

    /// Smoke: waits until the cycling and rendering are idle.
    func waitForRenderForSmoke() async {
        while true {
            if let task = pairingChain { await task.value; if pairingChain == task { pairingChain = nil }; continue }
            if let task = renderTask { await task.value; continue }
            return
        }
    }

    /// System blue/red for A/B, the secondary label for the guides and the text background, resolved for the
    /// current appearance.
    private static func colors() -> (CGColor, CGColor, CGColor, CGColor) {
        var out: (CGColor, CGColor, CGColor, CGColor) = (CGColor(gray: 0, alpha: 1), CGColor(gray: 0, alpha: 1),
                                                         CGColor(gray: 0.5, alpha: 1), CGColor(gray: 1, alpha: 1))
        NSAppearance.currentDrawing().performAsCurrentDrawingAppearance {
            out = (NSColor.systemBlue.cgColor, NSColor.systemRed.cgColor, NSColor.secondaryLabelColor.cgColor,
                   NSColor.textBackgroundColor.cgColor)
        }
        return out
    }

    // MARK: Helpers

    private func enqueue(_ work: @escaping @MainActor (CompareModel) async -> Void) {
        let previous = pairingChain
        pairingChain = Task { [weak self] in
            await previous?.value
            guard let self else { return }
            await work(self)
        }
    }

    /// "Family Style" for the readout and the missing-font line.
    private func label(for ref: FontReference) async -> String {
        let styles = await familyStyles(of: ref)
        let style = styles.first { $0.reference == ref }
            ?? styles.first { $0.reference.postScriptName == ref.postScriptName && $0.reference.variations == nil }
        guard let name = style?.name, !name.isEmpty else { return ref.family }
        return "\(ref.family) \(name)"
    }

    private func familyStyles(of ref: FontReference) async -> [PairingStyle] {
        let key = ref.family.lowercased()
        if let cached = familyStyleCache[key] { return cached }
        guard let store = fontStore() else { return [] }
        let generation = cacheGeneration
        let styles = await Task.detached(priority: .userInitiated) { (try? store.styles(ofFamilyOf: ref)) ?? [] }.value
        if generation == cacheGeneration, !styles.isEmpty { familyStyleCache[key] = styles }
        return styles
    }

    private func closestStyle(in family: FontReference, to font: FontReference) async -> FontReference {
        let target = await familyStyles(of: family)
        let own = await familyStyles(of: font)
        return LayoutsModel.closestStyle(in: family, target: target, to: font, own: own)
    }
}

private struct CompareImageBox: @unchecked Sendable {
    let image: CGImage
}

// MARK: - Candidates strip source

extension CompareModel {
    var emptyCandidatesMessage: String { "Add candidates: drag fonts here or add them to the Quick Collection" }
    var stripHelp: String {
        "Candidates: click one to make it B; ⌫ removes the selected one. ←/→ on the page cycle them."
    }

    func isCurrentCandidate(_ ref: FontReference) -> Bool {
        b?.family.lowercased() == ref.family.lowercased()
    }

    /// B becomes that family, in its style closest to A.
    func pickCandidate(_ ref: FontReference) async {
        let chosen = if let a { await closestStyle(in: ref, to: a) } else { ref }
        b = chosen
        refreshRender()
    }

    func removeCandidate(_ ref: FontReference) {
        let key = ref.family.lowercased()
        candidates.removeAll { $0.family.lowercased() == key }
    }

    /// Dragged or added fonts: their families (A's excluded) join the candidates; with no B yet the first becomes B.
    func addCandidates(faceIDs: [Int64]) async {
        guard !faceIDs.isEmpty, let store = fontStore() else { return }
        let refs = await Task.detached(priority: .userInitiated) { (try? store.candidateReferences(faceIDs: faceIDs)) ?? [] }.value
        let own = a?.family.lowercased()
        candidates = PairingCycler.merge(candidates, adding: refs.filter { $0.family.lowercased() != own })
        if b == nil, let a, let first = candidates.first {
            b = await closestStyle(in: first, to: a)
            refreshRender()
        }
    }

    func candidateImage(for ref: FontReference, pointSize: CGFloat, scale: CGFloat) async -> CGImage? {
        let key = LayoutsModel.CandidateImageKey(reference: ref, pointSize: pointSize, scale: scale)
        if let cached = candidateImageCache[key] { return cached }
        let known = resolved[ref]
        let store = fontStore()
        let box = await Task.detached(priority: .userInitiated) { () -> (CompareImageBox, Bool)? in
            let found = known ?? store.flatMap { try? $0.resolve([ref])[ref] }
            var font: CTFont?
            if let found, !found.isMissing, let url = found.url {
                font = LayoutsModel.loadFont(url: url, faceIndex: found.faceIndex, size: pointSize, variations: ref.variations ?? [:])
            }
            let name = ref.family.isEmpty ? ref.postScriptName : ref.family
            let fallback = CTFontCreateUIFontForLanguage(.system, pointSize, nil) ?? CTFontCreateWithName("Helvetica" as CFString, pointSize, nil)
            guard let image = LayoutsModel.renderLine(name, font: font ?? fallback, scale: scale) else { return nil }
            return (CompareImageBox(image: image), font != nil)
        }.value
        guard let (imageBox, isReal) = box else { return nil }
        if isReal { candidateImageCache[key] = imageBox.image }
        return imageBox.image
    }
}
