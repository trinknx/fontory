import SwiftUI

/// One sheet for Rename Family, Merge Families and Move to New Family: a name field (for a merge, a picker of the
/// selected families' names plus "Other…"), the live clash warning (it does not block) and the editor note.
struct FamilyNameSheet: View {
    let model: AppModel
    let request: FamilyNameRequest
    @Environment(\.dismiss) private var dismiss

    @State private var name: String
    /// Merge: the picked name's index in `request.names`, or `Self.other` for a typed one.
    @State private var choice = 0
    /// The existing family the name clashes with (as shown), checked as the name changes.
    @State private var clash: String?

    private static let other = -1

    init(model: AppModel, request: FamilyNameRequest) {
        self.model = model
        self.request = request
        _name = State(initialValue: request.kind == .merge ? "" : request.initialName)
    }

    /// The name Save applies.
    private var effectiveName: String {
        if request.kind == .merge, choice != Self.other, request.names.indices.contains(choice) { return request.names[choice] }
        return name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A rename may be blank (it clears the override, back to the original names); merge and split need a name.
    private var canSave: Bool {
        request.kind == .rename || !effectiveName.isEmpty
    }

    private var showsField: Bool {
        request.kind != .merge || choice == Self.other
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(request.title).font(.headline)
            if request.kind == .merge {
                Picker("Name:", selection: $choice) {
                    ForEach(Array(request.names.enumerated()), id: \.offset) { index, name in
                        Text(name).tag(index)
                    }
                    Divider()
                    Text("Other…").tag(Self.other)
                }
                .fixedSize()
            }
            if showsField {
                TextField("Family Name", text: $name, prompt: Text(request.kind == .rename ? "Original names" : "Family Name"))
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(save)
            }
            if let clash {
                Label(AppModel.clashWarning(clash), systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(AppModel.familyEditorNote)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save", action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSave)
            }
        }
        .padding(20)
        .frame(width: 400)
        .task(id: effectiveName) {
            let candidate = effectiveName
            guard !candidate.isEmpty else { clash = nil; return }
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            let found = await model.familyClashName(name: candidate, excluding: Set(request.faceIDs))
            guard !Task.isCancelled else { return }
            clash = found
        }
    }

    private func save() {
        guard canSave else { return }
        let request = request
        let name = effectiveName
        dismiss()
        Task { await model.commitFamilyName(request, name: name) }
    }
}
