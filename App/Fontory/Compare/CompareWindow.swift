import AppKit
import FontoryCore
import SwiftUI

/// Window ▸ Compare: the text and options on top, the A/B legend, the canvas, the readout and the candidates strip.
struct CompareWindow: View {
    @Environment(AppModel.self) private var model

    private var compare: CompareModel { model.compare }

    var body: some View {
        VStack(spacing: 0) {
            CompareHeader(compare: compare)
            Divider()
            CompareCanvas(model: compare, image: compare.renderedImage, scene: compare.scene)
                .overlay {
                    if let message = compare.emptyMessage {
                        Text(message)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .padding()
                    }
                }
            Divider()
            CompareReadoutView(scene: compare.scene)
            Divider()
            CandidatesStrip(source: compare)
        }
        .background(CompareWindowReader(compare: compare))
        .frame(minWidth: 720, minHeight: 520)
        .navigationTitle("Compare")
    }
}

// MARK: - Header

private struct CompareHeader: View {
    let compare: CompareModel
    @State private var field = ""

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 12) {
                HStack(spacing: 4) {
                    TextField("Text", text: $field)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { compare.commitText(field) }
                    Menu {
                        ForEach(CompareModel.presets, id: \.self) { preset in
                            Button(preset) { pick(preset) }
                        }
                        if !compare.recentTexts.isEmpty {
                            Divider()
                            Section("Recent") {
                                ForEach(compare.recentTexts, id: \.self) { recent in
                                    Button(recent) { pick(recent) }
                                }
                            }
                        }
                    } label: {
                        Image(systemName: "chevron.down.circle")
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .help("Preset and recent texts")
                }
                .frame(minWidth: 220)
                Picker("Mode", selection: modeBinding) {
                    Text("Overlay").tag(CompareMode.overlay)
                    Text("Side by Side").tag(CompareMode.sideBySide)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                Picker("Size", selection: sizeRuleBinding) {
                    Text("Same point size").tag(CompareSizeRule.sameSize)
                    Text("Match x-height").tag(CompareSizeRule.matchXHeight)
                    Text("Match cap height").tag(CompareSizeRule.matchCapHeight)
                }
                .fixedSize()
                .help("How B is scaled against A")
                Toggle("Outlines", isOn: outlinesBinding)
                    .help("Draw both fonts as outlines")
                Toggle("Guides", isOn: guidesBinding)
                    .help("Baseline, x-height, cap height, ascender and descender")
                Spacer(minLength: 0)
            }
            HStack(spacing: 8) {
                legend(color: .blue, tag: "A", name: compare.a == nil ? nil : (compare.scene?.a.label ?? compare.a?.family))
                Button { Task { await compare.swap() } } label: { Image(systemName: "arrow.left.arrow.right") }
                    .help("Swap A and B")
                    .disabled(compare.a == nil || compare.b == nil)
                legend(color: .red, tag: "B", name: compare.b == nil ? nil : (compare.scene?.b.label ?? compare.b?.family))
                Spacer(minLength: 0)
                Text("←→ family  ↑↓ style  ⇧↑↓ A's style  ⌘C copy")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .onAppear { field = compare.text }
        .onChange(of: compare.text) { _, new in if new != field { field = new } }
        .onChange(of: field) { _, new in if new != compare.text { compare.setText(new) } }
    }

    private func pick(_ text: String) {
        field = text
        compare.commitText(text)
    }

    private func legend(color: Color, tag: String, name: String?) -> some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 9, height: 9)
            Text(tag).fontWeight(.semibold)
            Text(name ?? "—")
                .foregroundStyle(name == nil ? .tertiary : .primary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
    }

    private var modeBinding: Binding<CompareMode> { option(\.mode) }
    private var sizeRuleBinding: Binding<CompareSizeRule> { option(\.sizeRule) }
    private var outlinesBinding: Binding<Bool> { option(\.outlines) }
    private var guidesBinding: Binding<Bool> { option(\.guides) }

    private func option<T>(_ path: WritableKeyPath<CompareOptions, T>) -> Binding<T> {
        Binding(get: { compare.options[keyPath: path] },
                set: { value in
                    var options = compare.options
                    options[keyPath: path] = value
                    compare.setOptions(options)
                })
    }
}

// MARK: - Readout

/// The numbers under the canvas, formatted: fractions of the em, widths in points, B's difference from A in %.
enum CompareReadout {
    struct Row: Equatable {
        var title: String
        var a: String
        var b: String
        var delta: String
    }

    /// "−6%", "+4%", "0%"; "—" when A is zero or a side is missing.
    nonisolated static func percent(_ value: Double?) -> String {
        guard let value else { return "—" }
        let rounded = value.rounded()
        if rounded == 0 { return "0%" }
        return (rounded > 0 ? "+" : "−") + String(format: "%.0f", abs(rounded)) + "%"
    }

    nonisolated static func fraction(_ value: Double?) -> String {
        value.map { String(format: "%.2f", $0) } ?? "—"
    }

    nonisolated static func rows(_ scene: CompareScene) -> [Row] {
        let a = scene.a.metrics, b = scene.b.metrics
        func row(_ title: String, _ path: KeyPath<CompareMetrics, Double>, points: Bool = false) -> Row {
            let va = a?[keyPath: path], vb = b?[keyPath: path]
            return make(title, va, vb, points: points)
        }
        func optional(_ title: String, _ path: KeyPath<CompareMetrics, Double?>) -> Row {
            make(title, a?[keyPath: path], b?[keyPath: path], points: false)
        }
        func make(_ title: String, _ va: Double?, _ vb: Double?, points: Bool) -> Row {
            let format: (Double?) -> String = { v in
                guard let v else { return "—" }
                return points ? String(format: "%.0f pt", v) : fraction(v)
            }
            let delta = va.flatMap { x in vb.flatMap { y in CompareRenderer.percentDifference(x, y) } }
            return Row(title: title, a: format(va), b: format(vb), delta: percent(delta))
        }
        var rows = [row("x-height", \.xHeight), row("Cap height", \.capHeight), row("Ascender", \.ascender),
                    row("Descender", \.descender), row("Width", \.lineWidth, points: true)]
        if scene.isGlyphMode {
            rows += [optional("Advance", \.advance), optional("LSB", \.leftBearing), optional("RSB", \.rightBearing)]
        }
        return rows
    }

    nonisolated static func lacks(_ side: String, _ count: Int) -> String? {
        count > 0 ? "\(side) lacks \(count) character\(count == 1 ? "" : "s")" : nil
    }

    /// "B × 1.06" (only when the size rule scales B) and the missing-character counts.
    nonisolated static func notes(_ scene: CompareScene) -> [String] {
        var out: [String] = []
        if abs(scene.scaleB - 1) >= 0.005 { out.append(String(format: "B × %.2f", scene.scaleB)) }
        if let a = lacks("A", scene.a.missingCharacters) { out.append(a) }
        if let b = lacks("B", scene.b.missingCharacters) { out.append(b) }
        return out
    }
}

private struct CompareReadoutView: View {
    let scene: CompareScene?

    var body: some View {
        Group {
            if let scene {
                let rows = CompareReadout.rows(scene)
                let notes = CompareReadout.notes(scene)
                VStack(alignment: .leading, spacing: 4) {
                    Grid(alignment: .trailing, horizontalSpacing: 20, verticalSpacing: 1) {
                        GridRow {
                            Text("")
                            Text("A").foregroundStyle(Color(nsColor: .systemBlue)).fontWeight(.semibold)
                            Text("B").foregroundStyle(Color(nsColor: .systemRed)).fontWeight(.semibold)
                            Text("Δ%").foregroundStyle(.secondary)
                        }
                        ForEach(rows, id: \.title) { row in
                            GridRow {
                                Text(row.title).foregroundStyle(.secondary).gridColumnAlignment(.leading)
                                Text(row.a)
                                Text(row.b)
                                Text(row.delta).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .font(.caption.monospacedDigit())
                    if !notes.isEmpty {
                        Text(notes.joined(separator: "   ·   "))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if scene.a.isMissing {
                        Text("Missing font — \(scene.a.label)").font(.caption).foregroundStyle(Color(nsColor: .systemBlue))
                    }
                    if scene.b.isMissing {
                        Text("Missing font — \(scene.b.label)").font(.caption).foregroundStyle(Color(nsColor: .systemRed))
                    }
                }
            } else {
                Text(" ").font(.caption)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
    }
}

// MARK: - Window reader

/// Records whether the Compare window is key, and resolves the fonts again whenever it becomes key (a drive may have
/// come back meanwhile).
private struct CompareWindowReader: NSViewRepresentable {
    let compare: CompareModel

    func makeNSView(context: Context) -> ReaderView {
        let view = ReaderView()
        view.onWindow = { [weak compare] window in
            compare?.isKey = window?.isKeyWindow ?? false
        }
        view.onKeyChange = { [weak compare] isKey in
            guard let compare else { return }
            if compare.isKey != isKey { compare.isKey = isKey }
            if isKey { compare.refreshFonts() }
        }
        return view
    }

    func updateNSView(_ nsView: ReaderView, context: Context) {}

    final class ReaderView: NSView {
        var onWindow: ((NSWindow?) -> Void)?
        var onKeyChange: ((Bool) -> Void)?
        nonisolated(unsafe) private var observers: [NSObjectProtocol] = []

        deinit {
            for o in observers { NotificationCenter.default.removeObserver(o) }
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            for o in observers { NotificationCenter.default.removeObserver(o) }
            observers = []
            onWindow?(window)
            guard let window else { return }
            for (name, isKey) in [(NSWindow.didBecomeKeyNotification, true), (NSWindow.didResignKeyNotification, false)] {
                observers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.onKeyChange?(isKey) }
                })
            }
        }
    }
}
