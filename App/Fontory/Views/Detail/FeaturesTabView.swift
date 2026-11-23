import AppKit
import FontoryCore
import SwiftUI

/// The Features tab: the focused style's OpenType layout features (or AAT features for fonts without OpenType
/// layout), grouped, each with a switch; a live sample line set with the switched features, the default rendering
/// below it for comparison; a bottom bar with the style, the Script/Language picker, the sample text, Reset and
/// Copy CSS.
///
/// Features are read off the main actor (`FontFeatureSet.read`); the sample lines render off the main actor through
/// the shared `PreviewRenderer` and its font cache.
struct FeaturesTabView: View {
    @Bindable var model: AppModel
    let detail: FamilyDetail
    let faceID: Int64

    @State private var loaded: LoadedFace?
    @State private var failure: String?
    @State private var loadedID: Int64?
    /// The user's switches by feature id; kept across styles of the family (only listed features apply).
    @State private var states: [String: Bool] = [:]
    @State private var selection: LayoutSelection = .all
    /// Every feature of the face, and those the selection lists; sorted once per face/selection, not per body.
    @State private var allFeatures: [LayoutFeature] = []
    @State private var features: [LayoutFeature] = []
    /// Typed sample text; empty uses the last switched feature's demo string, else the preview text.
    @State private var sampleText = ""
    @State private var lastSwitched: String?
    @State private var styleNames: [Int64: String] = [:]
    @State private var copied = false

    struct LoadedFace: Equatable {
        let face: SpecimenFace
        let features: FontFeatureSet
    }

    private struct LoadKey: Equatable {
        let faceID: Int64
        let rowsVersion: Int
    }

    var body: some View {
        VStack(spacing: 0) {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            bottomBar
        }
        .task(id: LoadKey(faceID: faceID, rowsVersion: model.rowsVersion)) { await load() }
        .onChange(of: selection) { updateFeatures() }
        .onAppear { updateStyleNames() }
        .onReceive(NotificationCenter.default.publisher(for: AppModel.rowsLoadedNotification, object: model)) { _ in
            updateStyleNames()
        }
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        if let failure, loadedID == faceID {
            ContentUnavailableView(failure, systemImage: "textformat.alt")
        } else if let loaded {
            if loaded.features.isEmpty {
                ContentUnavailableView("No Layout Features", systemImage: "textformat.alt",
                                       description: Text("This style declares no OpenType or AAT features."))
            } else {
                VStack(spacing: 0) {
                    featureList(loaded)
                    Divider()
                    FeatureSampleLines(renderer: model.previewRenderer, face: loaded.face, text: resolvedSampleText,
                                       settings: settings, language: sampleLanguage,
                                       foreground: model.preview.foreground, background: model.preview.background,
                                       showGuides: model.preview.showGuides)
                        .frame(height: 150)
                }
                .opacity(loadedID == faceID ? 1 : 0.5)
            }
        } else {
            ProgressView().controlSize(.small)
        }
    }

    /// Settings of every switched feature, including those the script filter hides.
    private var settings: [FontFeatureSetting] {
        FeatureToggles.settings(allFeatures, states: states)
    }

    /// Switched features the script filter hides.
    private var hiddenChanges: Int {
        FeatureToggles.hiddenChanges(all: allFeatures, listed: features, states: states)
    }

    /// The chosen language system's language, so the sample shows its `locl` forms.
    private var sampleLanguage: String? {
        if case let .languageSystem(_, language?) = selection { return FeatureCatalog.languageCode(language) }
        return nil
    }

    private func updateFeatures() {
        allFeatures = loaded?.features.features(for: .all) ?? []
        features = loaded?.features.features(for: selection) ?? []
    }

    private func featureList(_ loaded: LoadedFace) -> some View {
        let groups = FontFeatureSet.grouped(features)
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                if !loaded.features.usesOpenType {
                    Label("This font uses Apple Advanced Typography (AAT) features; CSS lists only those with an "
                          + "OpenType equivalent.", systemImage: "info.circle")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                if groups.isEmpty {
                    Text("No features for this script and language.").foregroundStyle(.secondary)
                }
                ForEach(groups, id: \.group) { entry in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(entry.group.title).font(.headline)
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), spacing: 16, alignment: .leading)],
                                  alignment: .leading, spacing: 8) {
                            ForEach(entry.features) { feature in
                                FeatureRow(feature: feature, isOn: binding(feature))
                            }
                        }
                    }
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func binding(_ feature: LayoutFeature) -> Binding<Bool> {
        Binding(
            get: { FeatureToggles.isOn(feature, states) },
            set: { on in
                states = FeatureToggles.toggled(feature, on: on, in: allFeatures, states: states)
                lastSwitched = feature.id
            })
    }

    /// The typed text, else the demo string of the last switched feature, else the preview text.
    private var resolvedSampleText: String {
        if !sampleText.isEmpty { return sampleText }
        if let id = lastSwitched, let demo = allFeatures.first(where: { $0.id == id })?.demoText { return demo }
        let preview = model.text(of: .previewText, row: model.cachedRow(faceID))
        return preview.isEmpty ? "Hamburgefonstiv 0123456789" : preview
    }

    // MARK: Loading

    private func load() async {
        let id = faceID
        model.prefetchRows(detail.faceIDs)
        guard let info = await model.faceInfo(id), !Task.isCancelled else {
            if !Task.isCancelled { fail("This style is no longer in the library.", id) }
            return
        }
        guard info.online else { return fail("The file of this style is offline.", id) }
        let renderer = model.previewRenderer
        let url = info.fileURL, index = info.faceIndex
        let set = await Task.detached(priority: .userInitiated) { () -> FontFeatureSet? in
            renderer.font(fileURL: url, faceIndex: index, pointSize: 1).map(FontFeatureSet.read)
        }.value
        guard !Task.isCancelled else { return }
        guard let set else { return fail("This font file could not be read.", id) }
        failure = nil
        loaded = LoadedFace(face: SpecimenFace(faceID: id, fileURL: url, faceIndex: index), features: set)
        loadedID = id
        if case let .languageSystem(script, language) = selection,
           !set.inventory.scripts.contains(script) || (language.map { !set.inventory.languages(script: script).contains($0) } ?? false) {
            selection = .all
        }
        updateFeatures()
        updateStyleNames()
    }

    private func fail(_ message: String, _ id: Int64) {
        failure = message
        loadedID = id
    }

    // MARK: Bottom bar

    private var bottomBar: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                leadingControls
                Spacer(minLength: 4)
                trailingControls
            }
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 10) {
                    leadingControls
                    Spacer(minLength: 0)
                }
                HStack(spacing: 10) {
                    trailingControls
                    Spacer(minLength: 0)
                }
            }
        }
        .controlSize(.small)
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private var leadingControls: some View {
        if detail.faceIDs.count > 1 { stylePicker }
        scriptMenu
        TextField("Sample text", text: $sampleText, prompt: Text(resolvedSampleText))
            .textFieldStyle(.roundedBorder)
            .frame(minWidth: 140, idealWidth: 220, maxWidth: 260)
            .help("Text of the sample line; empty shows the last switched feature's demo, or the preview text")
    }

    @ViewBuilder
    private var trailingControls: some View {
        let css = FeatureToggles.css(allFeatures, states: states)
        if hiddenChanges > 0 {
            Text(hiddenChanges == 1 ? "1 hidden change" : "\(hiddenChanges) hidden changes")
                .font(.callout)
                .foregroundStyle(.secondary)
                .help("Switched features of other scripts or languages; they still apply to the sample and the CSS")
        }
        Button("Reset") { states = [:] }
            .disabled(states.isEmpty)
            .help("Switch every feature back to the font's default")
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(css, forType: .string)
            copied = true
        } label: {
            Label(copied ? "Copied" : "Copy CSS", systemImage: copied ? "checkmark" : "doc.on.doc")
        }
        .help(css)
        .disabled(loaded == nil)
        .task(id: copied) {
            guard copied else { return }
            try? await Task.sleep(for: .seconds(1.5))
            copied = false
        }
    }

    private var scriptMenu: some View {
        let inventory = loaded?.features.inventory ?? .empty
        return Menu {
            Toggle("Default (All Features)", isOn: selectionBinding(.all))
            if !inventory.scripts.isEmpty { Divider() }
            ForEach(inventory.scripts, id: \.self) { script in
                let languages = inventory.languages(script: script)
                if languages.isEmpty {
                    Toggle(scriptTitle(script), isOn: selectionBinding(.languageSystem(script: script, language: nil)))
                } else {
                    Menu(scriptTitle(script)) {
                        Toggle("Default Language", isOn: selectionBinding(.languageSystem(script: script, language: nil)))
                        Divider()
                        ForEach(languages, id: \.self) { language in
                            Toggle("\(FeatureCatalog.languageName(language)) (\(language))",
                                   isOn: selectionBinding(.languageSystem(script: script, language: language)))
                        }
                    }
                }
            }
        } label: {
            Text(selectionTitle)
        }
        .fixedSize()
        .disabled(inventory.scripts.isEmpty)
        .help("Show the features of one script and language")
    }

    private func selectionBinding(_ value: LayoutSelection) -> Binding<Bool> {
        Binding(get: { selection == value }, set: { if $0 { selection = value } })
    }

    private func scriptTitle(_ tag: String) -> String {
        "\(FeatureCatalog.scriptName(tag)) (\(tag.trimmingCharacters(in: .whitespaces)))"
    }

    private var selectionTitle: String {
        switch selection {
        case .all: "Default"
        case let .languageSystem(script, nil): FeatureCatalog.scriptName(script)
        case let .languageSystem(script, language?):
            "\(FeatureCatalog.scriptName(script)) · \(FeatureCatalog.languageName(language))"
        }
    }

    private var stylePicker: some View {
        Picker("Style", selection: Binding(get: { faceID }, set: { model.detailSelection = [$0] })) {
            ForEach(detail.faceIDs, id: \.self) { id in
                Text(styleNames[id] ?? "Style \(detail.faceIDs.firstIndex(of: id).map { $0 + 1 } ?? 0)").tag(id)
            }
        }
        .labelsHidden()
        .fixedSize()
        .help("The style whose features are listed")
    }

    private func updateStyleNames() {
        var names = styleNames
        for id in detail.faceIDs {
            if let row = model.cachedRow(id) { names[id] = row.style.isEmpty ? row.fullName : row.style }
        }
        if names != styleNames { styleNames = names }
    }
}

/// One feature: its name, tag (or AAT type) and a switch.
private struct FeatureRow: View {
    let feature: LayoutFeature
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            VStack(alignment: .leading, spacing: 1) {
                Text(feature.name).lineLimit(1).truncationMode(.tail)
                Text(caption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .toggleStyle(.switch)
        .controlSize(.small)
        .help(help)
    }

    private var caption: String {
        guard feature.isOnByDefault else { return feature.detail }
        return feature.previewsWhenOff ? "\(feature.detail) · on by default" : "\(feature.detail) · always on in previews"
    }

    private var help: String {
        let title = feature.tag.map { "\(feature.name) (\($0))" } ?? feature.name
        return feature.previewsWhenOff ? title
            : "\(title). CoreText applies it even when switched off, so the sample cannot show it off; the CSS still does."
    }
}

/// The sample with the switched features, and below it, dimmed, the font's default rendering.
private struct FeatureSampleLines: View {
    let renderer: PreviewRenderer
    let face: SpecimenFace
    let text: String
    let settings: [FontFeatureSetting]
    let language: String?
    let foreground: CGColor
    let background: CGColor
    let showGuides: Bool

    @Environment(\.displayScale) private var scale

    var body: some View {
        GeometryReader { geo in
            VStack(alignment: .leading, spacing: 4) {
                FeatureSampleImage(renderer: renderer, request: request(width: geo.size.width - 40, height: 80,
                                                                        pointSize: 48, settings: settings),
                                   face: face)
                    .frame(height: 80)
                    .accessibilityLabel("Sample with the switched features: \(text)")
                HStack(spacing: 8) {
                    Text("Default").font(.caption).foregroundStyle(.secondary).frame(width: 52, alignment: .leading)
                    FeatureSampleImage(renderer: renderer, request: request(width: geo.size.width - 100, height: 40,
                                                                            pointSize: 24, settings: []),
                                       face: face)
                        .frame(height: 40)
                        .opacity(0.55)
                        .accessibilityLabel("Sample with the default features")
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .background(Color(cgColor: background))
    }

    private func request(width: CGFloat, height: CGFloat, pointSize: CGFloat, settings: [FontFeatureSetting]) -> PreviewRequest {
        var r = PreviewRequest(text: text, pointSize: pointSize, foreground: foreground, background: background,
                               size: CGSize(width: max(1, width.rounded(.down)), height: height), scale: scale)
        r.featureSettings = settings
        // CoreText ignores "kern" 0; the renderer switches kerning off through the kerning attribute instead.
        r.disablesKerning = FeatureToggles.disablesKerning(settings)
        r.language = language
        r.showGuides = showGuides
        return r
    }
}

/// One rendered line; renders off the main actor whenever the request changes, keeping the previous image meanwhile.
private struct FeatureSampleImage: View {
    let renderer: PreviewRenderer
    let request: PreviewRequest
    let face: SpecimenFace

    @State private var image: CGImage?

    private struct Key: Equatable {
        let request: PreviewRequest
        let face: SpecimenFace
    }

    var body: some View {
        Group {
            if let image {
                Image(decorative: image, scale: request.scale)
                    .resizable()
                    .frame(width: CGFloat(image.width) / request.scale, height: CGFloat(image.height) / request.scale)
            } else {
                Color.clear
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task(id: Key(request: request, face: face)) {
            let renderer = renderer, request = request, url = face.fileURL, index = face.faceIndex
            let rendered = await Task.detached(priority: .userInitiated) {
                ImageBox(image: renderer.render(fileURL: url, faceIndex: index, request: request))
            }.value
            guard !Task.isCancelled else { return }
            image = rendered.image
        }
    }
}

/// A CGImage crossing actors (immutable).
private struct ImageBox: @unchecked Sendable {
    let image: CGImage?
}
