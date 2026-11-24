import AppKit
import FontoryCore
import SwiftUI

/// The Compare canvas: the rendered scene bitmap on the text background, with the "Missing font" lines of an offline
/// side drawn over it. Keys (when it is first responder): ←/→ B's family, ↑/↓ B's style, ⇧↑/⇧↓ A's style, ⌘C copies
/// the canvas as an image. A click makes it first responder (the candidates strip does not take focus on click, so
/// the arrows keep working after picking a candidate).
struct CompareCanvas: NSViewRepresentable {
    let model: CompareModel
    let image: CGImage?
    let scene: CompareScene?

    func makeNSView(context: Context) -> CompareCanvasView {
        let view = CompareCanvasView()
        view.model = model
        return view
    }

    func updateNSView(_ view: CompareCanvasView, context: Context) {
        view.update(image: image, scene: scene)
    }
}

/// What a key press on the canvas does.
enum CompareCanvasCommand: Equatable {
    case cycle(CycleKey)
    case copy
}

final class CompareCanvasView: NSView {
    weak var model: CompareModel?
    private var image: CGImage?
    private var scene: CompareScene?
    private var lastReported: (CGSize, CGFloat)?

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// keyCode + modifiers → command: ←/→ ↑/↓ with no modifier cycle B; ⇧↑/⇧↓ step A's style; ⌘C copies.
    nonisolated static func command(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> CompareCanvasCommand? {
        let mods = modifiers.intersection(.deviceIndependentFlagsMask).subtracting([.function, .numericPad])
        if mods.isEmpty {
            switch keyCode {
            case 123: return .cycle(.family(-1))
            case 124: return .cycle(.family(1))
            case 126: return .cycle(.style(-1))
            case 125: return .cycle(.style(1))
            default: return nil
            }
        }
        if mods == .shift {
            switch keyCode {
            case 126: return .cycle(.referenceStyle(-1))
            case 125: return .cycle(.referenceStyle(1))
            default: return nil
            }
        }
        if mods == .command, keyCode == 8 { return .copy }
        return nil
    }

    func update(image newImage: CGImage?, scene newScene: CompareScene?) {
        image = newImage
        scene = newScene
        needsDisplay = true
    }

    // MARK: Size and appearance

    override func layout() {
        super.layout()
        reportSize()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        reportSize()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        let appearance = effectiveAppearance
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.model?.appearanceDidChange(appearance) }
        }
        needsDisplay = true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { return }
        let appearance = effectiveAppearance
        // Arrows work as soon as the window opens, without a click (unless a text field is being edited).
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.model?.appearanceDidChange(appearance)
                if let window = self.window, !(window.firstResponder is NSText) { window.makeFirstResponder(self) }
            }
        }
    }

    private func reportSize() {
        let value = (bounds.size, window?.backingScaleFactor ?? 2)
        guard value.0.width > 0, value.0.height > 0, lastReported.map({ $0 != value }) ?? true else { return }
        lastReported = value
        // After the layout pass, never while SwiftUI updates the view.
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.model?.canvasDidResize(value.0, scale: value.1) }
        }
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        NSColor.textBackgroundColor.setFill()
        bounds.fill()
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        if let image { context.draw(image, in: bounds) }
        guard let scene else { return }
        let sides: [(CompareSide, NSColor, Int)] = [(scene.a, .systemBlue, 0), (scene.b, .systemRed, 1)]
        for (side, color, index) in sides where side.isMissing {
            let text = "Missing font — \(side.label)" as NSString
            let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 15, weight: .medium), .foregroundColor: color]
            let size = text.size(withAttributes: attributes)
            // Side by side each line has its own baseline; in an overlay A sits above the baseline and B below it.
            let baseline = scene.baselines.count > 1 ? scene.baselines[index] : scene.baselines.first ?? bounds.midY
            let y = scene.baselines.count > 1 ? baseline : baseline + (index == 0 ? 8 : -8 - size.height)
            text.draw(at: NSPoint(x: (bounds.width - size.width) / 2, y: y), withAttributes: attributes)
        }
    }

    // MARK: Keys

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
    }

    override func keyDown(with event: NSEvent) {
        guard let command = Self.command(keyCode: event.keyCode, modifiers: event.modifierFlags), let model else {
            super.keyDown(with: event)
            return
        }
        perform(command, on: model)
    }

    /// ⌘C when the canvas has focus (a text field being edited has its own copy, and is not the first responder here).
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.firstResponder === self,
              Self.command(keyCode: event.keyCode, modifiers: event.modifierFlags) == .copy, let model else {
            return super.performKeyEquivalent(with: event)
        }
        perform(.copy, on: model)
        return true
    }

    private func perform(_ command: CompareCanvasCommand, on model: CompareModel) {
        switch command {
        case .cycle(let key): model.cycle(key)
        case .copy: if !model.copyImage() { NSSound.beep() }
        }
    }
}
