import FontoryCore
import SwiftUI

// MARK: - Editor state

/// The smart tag editor's draft: a new smart tag (`tagID` nil, not saved yet) or an existing one. Nothing is written
/// until Save; Cancel drops the draft. Owned by `AppModel.smartTagEditor` while the sheet is shown.
@MainActor @Observable
final class SmartTagEditorState: Identifiable {
    struct Row: Identifiable, Hashable {
        let id = UUID()
        /// Editing the row clears `changedFromUnsupported`.
        var condition: SmartRule.Condition { didSet { changedFromUnsupported = false } }
        /// The stored condition had an operator its field does not take and was reset; the row shows a warning.
        var changedFromUnsupported = false

        init(condition: SmartRule.Condition, changedFromUnsupported: Bool = false) {
            self.condition = condition
            self.changedFromUnsupported = changedFromUnsupported
        }
    }

    /// The tag being edited; nil for a new smart tag.
    let tagID: Int64?
    var name: String
    var match: SmartRule.Match
    var inverted: Bool
    var rows: [Row]
    /// Faces matching the draft (nil until the first count arrives).
    var matchCount: Int?
    var isSaving = false

    /// Bumped by every count request; an older result is dropped.
    @ObservationIgnored var countGeneration = 0
    /// The pending debounced count (the smoke check awaits it).
    @ObservationIgnored var countTask: Task<Void, Never>?

    nonisolated var id: ObjectIdentifier { ObjectIdentifier(self) }

    init(tagID: Int64?, name: String, rule: SmartRule) {
        self.tagID = tagID
        self.name = name
        match = rule.match
        inverted = rule.inverted
        // Rows the editor cannot show (an operator the field does not take) are reset to the field's first valid
        // operator (such a condition matched nothing anyway) and marked, so Save is not a silent rewrite.
        rows = rule.conditions.map { cond in
            var cond = cond
            guard !SmartRuleSchema.ops(for: cond.field).contains(cond.op) else { return Row(condition: cond) }
            cond.op = SmartRuleSchema.ops(for: cond.field)[0]
            cond.value = SmartRuleSchema.defaultValue(for: cond.field, tags: [], locations: [])
            return Row(condition: cond, changedFromUnsupported: true)
        }
    }

    /// The rule as it would be saved. Invert only counts with at least one condition.
    var rule: SmartRule {
        var r = SmartRule()
        r.match = match
        r.conditions = rows.map(\.condition)
        r.inverted = inverted && !rows.isEmpty
        return r
    }

    /// "+": a Name contains "" row.
    func addRow() {
        rows.append(Row(condition: SmartRule.Condition(field: .name, op: .contains, value: .text(""))))
    }

    func removeRow(_ id: UUID) {
        rows.removeAll { $0.id == id }
    }
}

// MARK: - Schema (valid operators and value kinds per field, as `SmartRule.sqlClause` accepts them)

enum SmartRuleSchema {
    enum ValueKind { case text, styleClass, tag, format, outline, script, location, weight, width, days, none }

    static let fieldOrder: [SmartRule.Field] = [
        .name, .family, .styleName, .foundry, .designer,
        .styleClass, .tag, .activation, .variable, .italic, .color, .hasNote,
        .weight, .width, .format, .outlineType, .script, .location, .dateAdded,
    ]

    static func title(_ field: SmartRule.Field) -> String {
        switch field {
        case .name: "Name"
        case .family: "Family"
        case .styleName: "Style name"
        case .foundry: "Foundry"
        case .designer: "Designer"
        case .styleClass: "Style class"
        case .tag: "Tag"
        case .activation: "Activation"
        case .variable: "Variable"
        case .italic: "Italic"
        case .color: "Color"
        case .hasNote: "Has note"
        case .weight: "Weight"
        case .width: "Width"
        case .format: "Format"
        case .outlineType: "Outline type"
        case .script: "Script supported"
        case .location: "Location"
        case .dateAdded: "Date added"
        }
    }

    static func ops(for field: SmartRule.Field) -> [SmartRule.Op] {
        switch field {
        case .name, .family, .styleName, .foundry, .designer: [.contains, .is, .startsWith]
        case .styleClass, .format, .outlineType, .location: [.is, .isNot]
        case .tag, .script: [.has, .hasNot]
        case .activation, .variable, .italic, .color, .hasNote: [.yes, .no]
        case .weight, .width: [.between]
        case .dateAdded: [.withinDays]
        }
    }

    static func opTitle(_ op: SmartRule.Op, for field: SmartRule.Field) -> String {
        switch (field, op) {
        case (.activation, .yes): "is active"
        case (.activation, .no): "is not active"
        case (.script, .has): "is"
        case (.script, .hasNot): "is not"
        case (_, .contains): "contains"
        case (_, .is): "is"
        case (_, .isNot): "is not"
        case (_, .startsWith): "starts with"
        case (_, .has): "has"
        case (_, .hasNot): "has not"
        case (_, .yes): "yes"
        case (_, .no): "no"
        case (_, .between): "is between"
        case (_, .withinDays): "is within the last"
        }
    }

    static func valueKind(_ field: SmartRule.Field) -> ValueKind {
        switch field {
        case .name, .family, .styleName, .foundry, .designer: .text
        case .styleClass: .styleClass
        case .tag: .tag
        case .format: .format
        case .outlineType: .outline
        case .script: .script
        case .location: .location
        case .weight: .weight
        case .width: .width
        case .dateAdded: .days
        case .activation, .variable, .italic, .color, .hasNote: .none
        }
    }

    /// The value a row gets when its field changes. `tags` are plain tags, `locations` the library's.
    static func defaultValue(for field: SmartRule.Field, tags: [TagRecord], locations: [LocationRecord]) -> SmartRule.Value {
        switch valueKind(field) {
        case .text: .text("")
        case .styleClass: .int(Int64(StyleClass.browsable[0].rawValue))
        case .tag: .int(tags.first?.id ?? 0)
        case .format: .text(formats[0])
        case .outline: .text(outlineTypes[0].value)
        case .script: .int(0)
        case .location: .int(locations.first?.id ?? 0)
        case .weight: .range(weightStops.first!.value, weightStops.last!.value)
        case .width: .range(widthStops.first!.value, widthStops.last!.value)
        case .days: .int(7)
        case .none: .none
        }
    }

    /// File formats the scanner records (`files.format`: the extension, or "sfnt"/"ttc"/... when sniffed).
    static let formats = ["otf", "ttf", "ttc", "otc", "woff", "woff2", "dfont", "sfnt", "pfb", "pfa", "pfm", "lwfn", "suit"]

    static let outlineTypes: [(title: String, value: String)] = [
        ("TrueType", "truetype"), ("CFF", "cff"), ("CFF2", "cff2"), ("Bitmap", "bitmap"),
    ]

    struct Stop: Hashable {
        let title: String
        let value: Double
    }

    /// Stored weight is OS/2-style, 100–900 (see `FontParser`).
    static let weightStops: [Stop] = [
        Stop(title: "Thin", value: 100), Stop(title: "Extra Light", value: 200), Stop(title: "Light", value: 300),
        Stop(title: "Regular", value: 400), Stop(title: "Medium", value: 500), Stop(title: "Semibold", value: 600),
        Stop(title: "Bold", value: 700), Stop(title: "Extra Bold", value: 800), Stop(title: "Black", value: 900),
    ]

    /// Stored width is OS/2-style, 1–9 (see `FontParser`).
    static let widthStops: [Stop] = [
        Stop(title: "Ultra Condensed", value: 1), Stop(title: "Extra Condensed", value: 2), Stop(title: "Condensed", value: 3),
        Stop(title: "Semi Condensed", value: 4), Stop(title: "Normal", value: 5), Stop(title: "Semi Expanded", value: 6),
        Stop(title: "Expanded", value: 7), Stop(title: "Extra Expanded", value: 8), Stop(title: "Ultra Expanded", value: 9),
    ]

    /// The stop nearest to a stored value (a rule saved elsewhere may hold an in-between value).
    static func stopIndex(for value: Double, in stops: [Stop]) -> Int {
        stops.indices.min { abs(stops[$0].value - value) < abs(stops[$1].value - value) } ?? 0
    }
}

// MARK: - Sheet

struct SmartTagEditor: View {
    @Bindable var editor: SmartTagEditorState
    let model: AppModel

    private static let rowHeight: CGFloat = 32
    private static let visibleRows = 8

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Name:")
                TextField("Smart Tag Name", text: $editor.name)
                    .textFieldStyle(.roundedBorder)
            }
            HStack(spacing: 6) {
                Text("Match")
                Picker("Match", selection: $editor.match) {
                    Text("all").tag(SmartRule.Match.all)
                    Text("any").tag(SmartRule.Match.any)
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
                Text("of the following:")
            }
            rowList
            HStack {
                Button {
                    editor.addRow()
                } label: {
                    Image(systemName: "plus")
                }
                .help("Add a condition")
                Spacer()
            }
            VStack(alignment: .leading, spacing: 2) {
                Toggle("Invert (match the fonts these conditions do not)", isOn: $editor.inverted)
                    .disabled(editor.rows.isEmpty)
                if editor.rows.isEmpty {
                    Text("With no conditions, every font matches.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Divider()
            HStack {
                Text(countText)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Spacer()
                Button("Cancel", role: .cancel) { model.cancelSmartTagEditor() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") { Task { await model.saveSmartTag(editor) } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(editor.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || editor.isSaving)
            }
        }
        .padding(20)
        .frame(width: 680)
        .onChange(of: editor.rule, initial: true) { model.scheduleSmartTagCount(editor) }
        .modelAlert(model, inSettings: false, inSheet: true)
    }

    private var countText: String {
        guard let n = editor.matchCount else { return "Counting…" }
        return "\(n.formatted()) font\(n == 1 ? "" : "s") match\(n == 1 ? "es" : "")"
    }

    private var rowList: some View {
        let shown = min(max(editor.rows.count, 1), Self.visibleRows)
        return ScrollView(.vertical) {
            VStack(spacing: 0) {
                if editor.rows.isEmpty {
                    Text("No conditions. Click + to add one.")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: Self.rowHeight)
                }
                ForEach($editor.rows) { $row in
                    ConditionRow(condition: $row.condition, changedFromUnsupported: row.changedFromUnsupported, model: model) {
                        editor.removeRow(row.id)
                    }
                        .frame(height: Self.rowHeight)
                }
            }
            .padding(.horizontal, 8)
        }
        .frame(height: CGFloat(shown) * Self.rowHeight + 8)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color(nsColor: .separatorColor)))
    }
}

/// field – operator – value – "−".
private struct ConditionRow: View {
    @Binding var condition: SmartRule.Condition
    let changedFromUnsupported: Bool
    let model: AppModel
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            if changedFromUnsupported {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.yellow)
                    .help("Changed from an unsupported operator")
                    .accessibilityLabel("Changed from an unsupported operator")
            }
            Picker("Field", selection: fieldBinding) {
                ForEach(SmartRuleSchema.fieldOrder, id: \.self) { Text(SmartRuleSchema.title($0)).tag($0) }
            }
            .labelsHidden()
            .frame(width: 140)
            let ops = SmartRuleSchema.ops(for: condition.field)
            if ops.count > 1 {
                Picker("Operator", selection: opBinding) {
                    ForEach(ops, id: \.self) { Text(SmartRuleSchema.opTitle($0, for: condition.field)).tag($0) }
                }
                .labelsHidden()
                .frame(width: 130)
            } else {
                Text(SmartRuleSchema.opTitle(condition.op, for: condition.field))
                    .frame(width: 130, alignment: .leading)
            }
            valueControl
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(action: remove) { Image(systemName: "minus") }
                .help("Remove this condition")
        }
    }

    private var fieldBinding: Binding<SmartRule.Field> {
        Binding(get: { condition.field }, set: { field in
            guard field != condition.field else { return }
            let keepsValue = SmartRuleSchema.valueKind(field) == SmartRuleSchema.valueKind(condition.field)
            condition = SmartRule.Condition(
                field: field, op: SmartRuleSchema.ops(for: field)[0],
                value: keepsValue ? condition.value
                    : SmartRuleSchema.defaultValue(for: field, tags: model.plainTagTree().map(\.tag), locations: libraryLocations))
        })
    }

    private var opBinding: Binding<SmartRule.Op> {
        Binding(get: { condition.op }, set: { condition.op = $0 })
    }

    private var libraryLocations: [LocationRecord] { model.locations.filter { !$0.autoIndexed } }

    private var textBinding: Binding<String> {
        Binding(get: { if case .text(let s) = condition.value { s } else { "" } }, set: { condition.value = .text($0) })
    }

    private var intBinding: Binding<Int64> {
        Binding(get: { if case .int(let i) = condition.value { i } else { 0 } }, set: { condition.value = .int($0) })
    }

    @ViewBuilder private var valueControl: some View {
        switch SmartRuleSchema.valueKind(condition.field) {
        case .text:
            TextField("Text", text: textBinding)
                .textFieldStyle(.roundedBorder)
        case .styleClass:
            menu(intBinding, StyleClass.browsable.map { (Int64($0.rawValue), $0.title) })
        case .tag:
            let tags = model.plainTagTree().map { ($0.tag.id, model.tagPath($0.tag.id)) }
            menu(intBinding, tags, missing: "No tag")
        case .format:
            menu(textBinding, SmartRuleSchema.formats.map { ($0, $0.uppercased()) })
        case .outline:
            menu(textBinding, SmartRuleSchema.outlineTypes.map { ($0.value, $0.title) })
        case .script:
            menu(intBinding, SmartRule.scriptNames.enumerated().map { (Int64($0.offset), $0.element) })
        case .location:
            menu(intBinding, libraryLocations.map { ($0.id, $0.displayName) }, missing: "No location")
        case .weight:
            StopRange(value: $condition.value, stops: SmartRuleSchema.weightStops)
        case .width:
            StopRange(value: $condition.value, stops: SmartRuleSchema.widthStops)
        case .days:
            HStack(spacing: 4) {
                TextField("Days", value: daysBinding, format: .number)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 60)
                Stepper("Days", value: daysBinding, in: 1...36_500)
                    .labelsHidden()
                Text(daysBinding.wrappedValue == 1 ? "day" : "days")
            }
        case .none:
            EmptyView()
        }
    }

    /// Days, at least 1.
    private var daysBinding: Binding<Int> {
        Binding(get: { if case .int(let i) = condition.value { Int(i) } else { 7 } },
                set: { condition.value = .int(Int64(min(36_500, max(1, $0)))) })
    }

    /// A popup over `items`; a value not among them (a deleted tag, an unknown format) shows as its own entry so
    /// the row never silently changes.
    private func menu<V: Hashable>(_ binding: Binding<V>, _ items: [(V, String)], missing: String = "Unknown") -> some View {
        let known = items.contains { $0.0 == binding.wrappedValue }
        return Picker("Value", selection: binding) {
            if !known {
                Text(items.isEmpty ? missing : "\(missing) (\(String(describing: binding.wrappedValue)))")
                    .tag(binding.wrappedValue)
            }
            ForEach(items.indices, id: \.self) { i in Text(items[i].1).tag(items[i].0) }
        }
        .labelsHidden()
        .fixedSize()
    }
}

/// "[stop] and [stop]" for weight or width, written as `.range(low, high)` in stored units.
private struct StopRange: View {
    @Binding var value: SmartRule.Value
    let stops: [SmartRuleSchema.Stop]

    var body: some View {
        HStack(spacing: 6) {
            stopPicker(lowBinding)
            Text("and")
            stopPicker(highBinding)
        }
    }

    private var bounds: (Int, Int) {
        guard case .range(let a, let b) = value else { return (0, stops.count - 1) }
        return (SmartRuleSchema.stopIndex(for: min(a, b), in: stops), SmartRuleSchema.stopIndex(for: max(a, b), in: stops))
    }

    private var lowBinding: Binding<Int> {
        Binding(get: { bounds.0 }, set: { i in value = .range(stops[i].value, stops[max(i, bounds.1)].value) })
    }

    private var highBinding: Binding<Int> {
        Binding(get: { bounds.1 }, set: { i in value = .range(stops[min(i, bounds.0)].value, stops[i].value) })
    }

    private func stopPicker(_ binding: Binding<Int>) -> some View {
        Picker("Stop", selection: binding) {
            ForEach(stops.indices, id: \.self) { Text(stops[$0].title).tag($0) }
        }
        .labelsHidden()
        .fixedSize()
    }
}
