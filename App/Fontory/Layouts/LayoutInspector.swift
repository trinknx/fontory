import AppKit
import FontoryCore
import SwiftUI

/// The Layouts window's inspector: the selected block's font (family menu from the candidates plus Choose Font…,
/// style menu), size, line height, tracking, alignment and colour, waterfall sizes, the report's notes, and the
/// layout's Show Missing Characters. Every change goes through the model, so undo covers it.
struct LayoutInspector: View {
    let layouts: LayoutsModel

    var body: some View {
        Form {
            if let doc = layouts.current {
                if let block = layouts.selectedBlock {
                    BlockSection(layouts: layouts, block: block, foreground: doc.foreground)
                } else {
                    Section {
                        Text("Select a block on the page.")
                            .foregroundStyle(.secondary)
                    }
                }
                Section("Layout") {
                    Toggle("Show Missing Characters", isOn: Binding(get: { doc.showMissing },
                                                                   set: { layouts.setShowMissing($0) }))
                        .help("Draw ◌ for any character a block's font lacks")
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct BlockSection: View {
    let layouts: LayoutsModel
    let block: LayoutBlock
    let foreground: String
    @State private var styles: [PairingStyle] = []
    @State private var choosingFont = false

    var body: some View {
        Section("Font") {
            LabeledContent("Family") {
                Menu(familyName) {
                    ForEach(layouts.candidates, id: \.self) { candidate in
                        Button(candidate.family) { Task { await layouts.applyCandidate(candidate) } }
                    }
                    if !layouts.candidates.isEmpty { Divider() }
                    Button("Choose Font…") { choosingFont = true }
                }
                .fixedSize()
            }
            LabeledContent("Style") {
                Menu(styleName) {
                    ForEach(styles, id: \.self) { style in
                        Button(style.name) { layouts.setFont(style.reference, for: block.id) }
                    }
                }
                .fixedSize()
                .disabled(styles.count < 2)
            }
            Button("Apply to All Blocks") { Task { await layouts.applyFamilyToAll(block.font) } }
                .help("Every block takes this family, keeping its weight where a matching style exists")
                .disabled(block.font.family.isEmpty)
            if layouts.isFontMissing(block.id) {
                Label("Missing font", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .help("Not found in the library, or on a drive that isn't connected. It draws in the system font.")
                Text(block.font.postScriptName.isEmpty ? block.font.family : block.font.postScriptName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            let missing = layouts.missingCharacters(in: block.id)
            if missing > 0 {
                Label("\(missing) character\(missing == 1 ? "" : "s") missing", systemImage: "circle.dotted")
                    .foregroundStyle(.secondary)
            }
        }
        .task(id: block.font) { styles = await layouts.styles(for: block.font) }
        .sheet(isPresented: $choosingFont) {
            ChooseFontSheet(layouts: layouts, isPresented: $choosingFont)
        }

        Section("Text") {
            LabeledContent("Size") {
                HStack(spacing: 4) {
                    TextField("Size", value: Binding(get: { block.size }, set: { layouts.setSize($0, for: block.id) }), format: .number)
                        .labelsHidden()
                        .multilineTextAlignment(.trailing)
                        .frame(width: 56)
                    Stepper("Size", value: Binding(get: { block.size }, set: { layouts.setSize($0, for: block.id) }),
                            in: LayoutsModel.sizeRange, step: 1)
                        .labelsHidden()
                    Text("pt").foregroundStyle(.secondary)
                }
            }
            LabeledContent("Line Height") {
                HStack(spacing: 4) {
                    TextField("Line Height", value: Binding(get: { block.lineHeight }, set: { layouts.setLineHeight($0, for: block.id) }),
                              format: .number.precision(.fractionLength(0...2)))
                        .labelsHidden()
                        .multilineTextAlignment(.trailing)
                        .frame(width: 56)
                    Stepper("Line Height", value: Binding(get: { block.lineHeight }, set: { layouts.setLineHeight($0, for: block.id) }),
                            in: LayoutsModel.lineHeightRange, step: 0.05)
                        .labelsHidden()
                    Text("×").foregroundStyle(.secondary)
                }
            }
            LabeledContent("Tracking") {
                HStack(spacing: 4) {
                    TextField("Tracking", value: Binding(get: { block.tracking }, set: { layouts.setTracking($0, for: block.id) }), format: .number)
                        .labelsHidden()
                        .multilineTextAlignment(.trailing)
                        .frame(width: 56)
                    Stepper("Tracking", value: Binding(get: { block.tracking }, set: { layouts.setTracking($0, for: block.id) }),
                            in: LayoutsModel.trackingRange, step: 10)
                        .labelsHidden()
                    Text("‰ em").foregroundStyle(.secondary)
                }
            }
            Picker("Alignment", selection: Binding(get: { block.alignment }, set: { layouts.setAlignment($0, for: block.id) })) {
                Image(systemName: "text.alignleft").help("Left").tag(LayoutAlignment.left)
                Image(systemName: "text.aligncenter").help("Centre").tag(LayoutAlignment.center)
                Image(systemName: "text.alignright").help("Right").tag(LayoutAlignment.right)
                Image(systemName: "text.justify").help("Justified").tag(LayoutAlignment.justified)
            }
            .pickerStyle(.segmented)
            LabeledContent("Colour") {
                HStack {
                    if block.color != nil {
                        Button("Default") { layouts.setColor(nil, for: block.id) }
                            .controlSize(.small)
                            .help("Use the layout's text colour")
                    }
                    ColorPicker("Colour", selection: colorBinding, supportsOpacity: false)
                        .labelsHidden()
                }
            }
            if block.kind == .waterfall {
                SizesField(layouts: layouts, blockID: block.id, sizes: block.sizes)
                    .id(block.id)
            }
        }
    }

    private var familyName: String {
        block.font.family.isEmpty ? "System Font" : block.font.family
    }

    private var styleName: String {
        styles.first { $0.reference == block.font }?.name
            ?? styles.first { $0.reference.postScriptName == block.font.postScriptName && $0.reference.variations == nil }?.name
            ?? (block.font.postScriptName.isEmpty ? "Regular" : block.font.postScriptName)
    }

    private var colorBinding: Binding<Color> {
        Binding(get: {
            let hex = block.color ?? foreground
            return LayoutColor.cgColor(hex).flatMap { NSColor(cgColor: $0) }.map(Color.init(nsColor:)) ?? .black
        }, set: { color in
            if let hex = Self.hex(NSColor(color)) { layouts.setColor(hex, for: block.id) }
        })
    }

    /// `#RRGGBB` in sRGB.
    static func hex(_ color: NSColor) -> String? {
        guard let c = color.usingColorSpace(.sRGB) else { return nil }
        func byte(_ v: CGFloat) -> Int { Int((min(1, max(0, v)) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", byte(c.redComponent), byte(c.greenComponent), byte(c.blueComponent))
    }
}

/// The waterfall sizes as a comma-separated field; a value that doesn't parse is reverted.
private struct SizesField: View {
    let layouts: LayoutsModel
    let blockID: UUID
    let sizes: [Double]
    @State private var text = ""

    var body: some View {
        TextField("Sizes", text: $text, prompt: Text("12, 16, 24"))
            .help("Point sizes, separated by commas")
            .onSubmit(commit)
            .onAppear { text = LayoutsModel.formatSizes(sizes) }
            .onChange(of: sizes) { _, new in text = LayoutsModel.formatSizes(new) }
    }

    private func commit() {
        if !layouts.setSizes(text, for: blockID) || LayoutsModel.parseSizes(text) == sizes {
            text = LayoutsModel.formatSizes(sizes)
        }
    }
}

/// Choose Font…: searches the library by name (the browser's search, off the main thread) and lists families;
/// choosing one gives the selected block that family's representative face.
private struct ChooseFontSheet: View {
    static let resultLimit = 500

    let layouts: LayoutsModel
    @Binding var isPresented: Bool
    @State private var query = ""
    @State private var results: [FamilyGroup] = []
    @State private var selection: FamilyGroup.ID?
    @State private var searching = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Choose Font").font(.headline)
            TextField("Search the library by name", text: $query)
                .textFieldStyle(.roundedBorder)
            List(results, selection: $selection) { family in
                Text(family.name)
            }
            .contextMenu(forSelectionType: FamilyGroup.ID.self, menu: { _ in }, primaryAction: { ids in
                if let id = ids.first { choose(id) }
            })
            .overlay {
                if results.isEmpty, !searching {
                    Text(query.trimmingCharacters(in: .whitespaces).isEmpty ? "Type a font or family name." : "No fonts found.")
                        .foregroundStyle(.secondary)
                }
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { isPresented = false }
                    .keyboardShortcut(.cancelAction)
                Button("Choose") { if let selection { choose(selection) } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(selection == nil)
            }
        }
        .padding()
        .frame(width: 380, height: 440)
        .task(id: query) {
            // A short pause so typing doesn't query on every key.
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            searching = true
            let found = await layouts.searchFamilies(query)
            guard !Task.isCancelled else { return }
            results = Array(found.prefix(Self.resultLimit))
            if let selection, !results.contains(where: { $0.id == selection }) { self.selection = nil }
            searching = false
        }
    }

    private func choose(_ id: FamilyGroup.ID) {
        guard let family = results.first(where: { $0.id == id }) else { return }
        isPresented = false
        Task { await layouts.chooseFamily(family) }
    }
}
