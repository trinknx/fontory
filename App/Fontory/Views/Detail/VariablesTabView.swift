import AppKit
import FontoryCore
import SwiftUI

/// The Variables tab: one slider per `fvar` axis (min, default and max marked, the value editable as a number,
/// Option-drag snapping to the named instances), a live sample set at those coordinates with the default instance
/// below it for comparison, and a bottom bar with the style, the named-instance menu, Show Hidden Axes, the sample
/// text and size, Reset and Copy CSS.
///
/// Axes are read off the main actor (`VariationInfo.read`); the coordinates live in `AppModel.variationStates`, per
/// face for the session.
struct VariablesTabView: View {
    @Bindable var model: AppModel
    let detail: FamilyDetail
    let faceID: Int64

    @State private var loaded: LoadedFace?
    @State private var failure: String?
    @State private var loadedID: Int64?
    @State private var sampleText = ""
    @State private var styleNames: [Int64: String] = [:]
    @State private var copied = false

    struct LoadedFace: Equatable {
        let face: SpecimenFace
        let info: VariationInfo
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
        .onAppear { updateStyleNames() }
        .onReceive(NotificationCenter.default.publisher(for: AppModel.rowsLoadedNotification, object: model)) { _ in
            updateStyleNames()
        }
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        if let failure, loadedID == faceID {
            ContentUnavailableView(failure, systemImage: "slider.horizontal.3")
        } else if let loaded {
            if !loaded.info.isVariable {
                ContentUnavailableView("Not a Variable Font", systemImage: "slider.horizontal.3",
                                       description: Text("This style has no variation axes."))
            } else {
                VStack(spacing: 0) {
                    axisList(loaded.info)
                    Divider()
                    VariationSampleLines(renderer: model.previewRenderer, face: loaded.face, text: resolvedSampleText,
                                         pointSize: model.variationSamplePointSize,
                                         variations: effectiveValues(loaded.info), defaults: loaded.info.defaults,
                                         preview: model.preview)
                        .frame(height: sampleHeight)
                }
                .opacity(loadedID == faceID ? 1 : 0.5)
            }
        } else {
            ProgressView().controlSize(.small)
        }
    }

    private var sampleHeight: CGFloat {
        (model.variationSamplePointSize * 1.6).rounded() + 64
    }

    private func axisList(_ info: VariationInfo) -> some View {
        let hidden = info.axes.filter(\.isHidden)
        let hiddenCount = hidden.count
        let values = effectiveValues(info)
        let hiddenChanged = hidden.filter { abs((values[$0.code] ?? $0.defaultValue) - $0.defaultValue) >= 0.005 }.count
        return ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                ForEach(info.axes.filter { model.showsHiddenAxes || !$0.isHidden }) { axis in
                    AxisRow(axis: axis, stops: info.stops(for: axis), value: valueBinding(axis, info),
                            auto: axis.code == VariationInfo.opticalSize ? autoBinding(info) : nil,
                            autoValue: axis.clamped(model.variationSamplePointSize))
                }
                if hiddenCount > 0, !model.showsHiddenAxes {
                    Text((hiddenCount == 1 ? "1 hidden axis" : "\(hiddenCount) hidden axes")
                         + (hiddenChanged == 0 ? ""
                            : hiddenChanged == 1 ? ", 1 not at its default (it applies to the sample and the CSS)"
                            : ", \(hiddenChanged) not at their defaults (they apply to the sample and the CSS)"))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Text("Hold Option while dragging to snap to the named instances.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(20)
            .frame(maxWidth: 820, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: State

    /// The face's coordinates; defaults until the user changes one (or when the stored ones no longer fit the axes).
    private func state(_ info: VariationInfo) -> VariationState {
        if let s = model.variationStates[faceID], Set(s.values.keys) == Set(info.axes.map(\.code)) { return s }
        return VariationState(values: info.defaults)
    }

    private func setState(_ s: VariationState) {
        model.variationStates[faceID] = s
    }

    /// The coordinates as drawn: an automatic optical size is the sample's point size.
    private func effectiveValues(_ info: VariationInfo) -> [UInt32: Double] {
        let s = state(info)
        var values = s.values
        if s.autoOpticalSize, let opsz = info.axes.first(where: { $0.code == VariationInfo.opticalSize }) {
            values[opsz.code] = opsz.clamped(model.variationSamplePointSize)
        }
        return values
    }

    private func valueBinding(_ axis: VariationInfo.Axis, _ info: VariationInfo) -> Binding<Double> {
        Binding(
            get: { effectiveValues(info)[axis.code] ?? axis.defaultValue },
            set: { newValue in
                guard newValue.isFinite else { return }
                // Rounded to the axis step, so a drag does not fill the font cache with near-identical instances.
                var v = axis.clamped((newValue / axis.step).rounded() * axis.step)
                if NSEvent.modifierFlags.contains(.option) {
                    v = VariationInfo.snap(v, to: info.stops(for: axis), threshold: (axis.maxValue - axis.minValue) * 0.08)
                }
                var s = state(info)
                s.values[axis.code] = v
                if axis.code == VariationInfo.opticalSize { s.autoOpticalSize = false }
                setState(s)
            })
    }

    private func autoBinding(_ info: VariationInfo) -> Binding<Bool> {
        Binding(
            get: { state(info).autoOpticalSize },
            set: { on in
                var s = state(info)
                s.autoOpticalSize = on
                setState(s)
            })
    }

    /// The typed text, else the preview text.
    private var resolvedSampleText: String {
        if !sampleText.isEmpty { return sampleText }
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
        let variations = await Task.detached(priority: .userInitiated) { () -> VariationInfo? in
            renderer.font(fileURL: url, faceIndex: index, pointSize: 1).map(VariationInfo.read)
        }.value
        guard !Task.isCancelled else { return }
        guard let variations else { return fail("This font file could not be read.", id) }
        failure = nil
        loaded = LoadedFace(face: SpecimenFace(faceID: id, fileURL: url, faceIndex: index), info: variations)
        loadedID = id
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

    /// The loaded axes of the face shown, when it is a variable font.
    private var current: VariationInfo? {
        guard let info = loaded?.info, loadedID == faceID, info.isVariable else { return nil }
        return info
    }

    @ViewBuilder
    private var leadingControls: some View {
        if detail.faceIDs.count > 1 { stylePicker }
        instanceMenu
        if let info = current, info.axes.contains(where: \.isHidden) {
            Toggle("Show hidden axes", isOn: $model.showsHiddenAxes)
                .toggleStyle(.checkbox)
                .help("List the axes the font asks apps not to show")
        }
        TextField("Sample text", text: $sampleText, prompt: Text(resolvedSampleText))
            .textFieldStyle(.roundedBorder)
            .frame(minWidth: 120, idealWidth: 200, maxWidth: 240)
            .help("Text of the sample; empty shows the preview text")
    }

    @ViewBuilder
    private var trailingControls: some View {
        // Whole points: with an automatic optical size, every distinct size is a new font instance.
        Slider(value: $model.variationSamplePointSize, in: AppModel.variationSamplePointSizeRange, step: 1)
            .frame(width: 100)
            .accessibilityLabel("Sample size")
            .help("Point size of the sample; an automatic optical size follows it")
        Text("\(Int(model.variationSamplePointSize.rounded())) pt")
            .font(.callout)
            .monospacedDigit()
            .foregroundStyle(.secondary)
            .frame(width: 44, alignment: .trailing)
        let info = current
        let css = info.map { $0.css(values: effectiveValues($0), autoOpticalSize: state($0).autoOpticalSize) } ?? ""
        Button("Reset") {
            if let info { setState(VariationState(values: info.defaults)) }
        }
        .disabled(info.map { state($0) == VariationState(values: $0.defaults) } ?? true)
        .help("Set every axis back to its default")
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(css, forType: .string)
            copied = true
        } label: {
            Label(copied ? "Copied" : "Copy CSS", systemImage: copied ? "checkmark" : "doc.on.doc")
        }
        .help(css)
        .disabled(info == nil)
        .task(id: copied) {
            guard copied else { return }
            try? await Task.sleep(for: .seconds(1.5))
            copied = false
        }
    }

    private var instanceMenu: some View {
        let info = current
        return InstancePicker(faceID: faceID, instances: info?.instances ?? [],
                              selected: info.flatMap { $0.instance(matching: effectiveValues($0)) }?.index) { index in
            guard let info, let instance = info.instances.first(where: { $0.index == index }) else { return }
            var values = info.defaults
            for (code, v) in instance.coordinates { values[code] = v }
            setState(VariationState(values: values))
        }
        .equatable()
    }

    private var stylePicker: some View {
        Picker("Style", selection: Binding(get: { faceID }, set: { model.detailSelection = [$0] })) {
            ForEach(detail.faceIDs, id: \.self) { id in
                Text(styleNames[id] ?? "Style \(detail.faceIDs.firstIndex(of: id).map { $0 + 1 } ?? 0)").tag(id)
            }
        }
        .labelsHidden()
        .fixedSize()
        .help("The style whose axes are shown")
    }

    private func updateStyleNames() {
        var names = styleNames
        for id in detail.faceIDs {
            if let row = model.cachedRow(id) { names[id] = row.style.isEmpty ? row.fullName : row.style }
        }
        if names != styleNames { styleNames = names }
    }
}

/// The named-instance menu; "Custom" while the coordinates match no instance. Equatable on its instances and
/// selection, so a slider drag does not rebuild a menu of hundreds of instances on every step.
private struct InstancePicker: View, Equatable {
    /// The face the instances belong to; two faces can declare equal instance lists.
    let faceID: Int64
    let instances: [VariationInfo.Instance]
    let selected: Int?
    let choose: (Int) -> Void

    nonisolated static func == (a: InstancePicker, b: InstancePicker) -> Bool {
        a.faceID == b.faceID && a.selected == b.selected && a.instances == b.instances
    }

    var body: some View {
        Picker("Instance", selection: Binding<Int?>(get: { selected }, set: { if let index = $0 { choose(index) } })) {
            Text("Custom").tag(Int?.none)
            if !instances.isEmpty {
                Divider()
                ForEach(instances) { instance in
                    Text(instance.name).tag(Int?.some(instance.index))
                }
            }
        }
        .labelsHidden()
        .fixedSize()
        .disabled(instances.isEmpty)
        .help("Named instances: choosing one sets every axis to its coordinates")
    }
}

/// One axis: its name and tag, a slider with min/default/max (and instance) ticks, the value as an editable number,
/// and for `opsz` the Auto (match size) switch.
private struct AxisRow: View {
    let axis: VariationInfo.Axis
    let stops: [Double]
    @Binding var value: Double
    /// Non-nil for the optical-size axis.
    let auto: Binding<Bool>?
    /// The value an automatic optical size takes.
    let autoValue: Double

    private var isAuto: Bool { auto?.wrappedValue ?? false }

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 1) {
                Text(axis.name).lineLimit(1).truncationMode(.tail)
                Text(axis.isHidden ? "\(axis.tag) · hidden" : axis.tag)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
            .frame(width: 130, alignment: .leading)
            .help("\(axis.name) (\(axis.tag))")
            VStack(spacing: 2) {
                Slider(value: $value, in: axis.minValue...max(axis.maxValue, axis.minValue + 0.0001))
                    .controlSize(.small)
                    .disabled(isAuto || axis.minValue == axis.maxValue)
                    .accessibilityLabel(axis.name)
                    .accessibilityValue(VariationInfo.format(value))
                AxisTicks(axis: axis, stops: stops)
                    .frame(height: 18)
            }
            .frame(minWidth: 200)
            TextField(axis.tag, value: $value,
                      format: .number.precision(.fractionLength(0...2)).grouping(.never))
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .monospacedDigit()
                .frame(width: 70)
                .disabled(isAuto)
                .help("Value of \(axis.tag), from \(VariationInfo.format(axis.minValue)) to \(VariationInfo.format(axis.maxValue))")
            if let auto {
                Toggle("Auto", isOn: auto)
                    .toggleStyle(.checkbox)
                    .help("Auto (match size): the optical size follows the sample's point size (\(VariationInfo.format(autoValue)))")
            }
            Button {
                value = axis.defaultValue
            } label: {
                Image(systemName: "arrow.uturn.backward")
            }
            .buttonStyle(.borderless)
            .disabled(!isAuto && abs(value - axis.defaultValue) < 0.005)
            .help("Back to the default, \(VariationInfo.format(axis.defaultValue))")
            .accessibilityLabel("Reset \(axis.name)")
        }
    }
}

/// Ticks under an axis slider: min, default and max labelled, instance coordinates as short marks.
private struct AxisTicks: View {
    let axis: VariationInfo.Axis
    let stops: [Double]

    /// Approximate inset of the slider track from the control's edges (half the knob).
    private static let inset: CGFloat = 7

    var body: some View {
        GeometryReader { geo in
            let width = max(1, geo.size.width - Self.inset * 2)
            let span = axis.maxValue - axis.minValue
            let x: (Double) -> CGFloat = { v in
                Self.inset + (span > 0 ? CGFloat((v - axis.minValue) / span) : 0) * width
            }
            ZStack(alignment: .topLeading) {
                ForEach(stops, id: \.self) { stop in
                    Rectangle()
                        .fill(Color.secondary.opacity(0.45))
                        .frame(width: 1, height: 4)
                        .position(x: x(stop), y: 2)
                }
                Rectangle()
                    .fill(Color.accentColor)
                    .frame(width: 1.5, height: 6)
                    .position(x: x(axis.defaultValue), y: 3)
                Text(VariationInfo.format(axis.minValue))
                    .frame(width: Self.labelWidth, alignment: .leading)
                    .position(x: Self.labelWidth / 2, y: 12)
                Text(VariationInfo.format(axis.maxValue))
                    .frame(width: Self.labelWidth, alignment: .trailing)
                    .position(x: geo.size.width - Self.labelWidth / 2, y: 12)
                if axis.defaultValue != axis.minValue, axis.defaultValue != axis.maxValue {
                    Text("default \(VariationInfo.format(axis.defaultValue))")
                        .fixedSize()
                        .position(x: min(max(x(axis.defaultValue), 60), geo.size.width - 60), y: 12)
                }
            }
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.secondary)
        }
        .accessibilityElement()
        .accessibilityLabel("Minimum \(VariationInfo.format(axis.minValue)), default \(VariationInfo.format(axis.defaultValue)), "
                            + "maximum \(VariationInfo.format(axis.maxValue))")
    }

    private static let labelWidth: CGFloat = 60
}

/// The sample at the chosen coordinates, and below it, dimmed, the default instance.
private struct VariationSampleLines: View {
    let renderer: PreviewRenderer
    let face: SpecimenFace
    let text: String
    let pointSize: Double
    let variations: [UInt32: Double]
    let defaults: [UInt32: Double]
    let preview: PreviewSettings

    @Environment(\.displayScale) private var scale

    var body: some View {
        GeometryReader { geo in
            let mainHeight = (pointSize * 1.6).rounded()
            VStack(alignment: .leading, spacing: 4) {
                SampleLineImage(renderer: renderer, request: request(width: geo.size.width - 40, height: mainHeight,
                                                                     pointSize: pointSize, variations: variations),
                                face: face)
                    .frame(height: mainHeight)
                    .accessibilityLabel("Sample at the chosen axis values: \(text)")
                HStack(spacing: 8) {
                    Text("Default").font(.caption).foregroundStyle(.secondary).frame(width: 52, alignment: .leading)
                    SampleLineImage(renderer: renderer, request: request(width: geo.size.width - 100, height: 40,
                                                                         pointSize: 24, variations: defaults),
                                    face: face)
                        .frame(height: 40)
                        .opacity(0.55)
                        .accessibilityLabel("Sample at the default instance")
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .background(Color(cgColor: preview.background))
    }

    private func request(width: CGFloat, height: CGFloat, pointSize: Double, variations: [UInt32: Double]) -> PreviewRequest {
        // The preview's colors, guides, tracking and features; this tab's text, size and alignment.
        var r = preview.request(pointSize: CGFloat(pointSize),
                                size: CGSize(width: max(1, width.rounded(.down)), height: height), scale: scale)
        r.text = text
        r.pointSize = CGFloat(pointSize)
        r.alignment = .left
        r.variations = variations
        return r
    }
}
