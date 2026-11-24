import AppKit
import FontoryCore
import Foundation

/// What the family name sheet edits.
struct FamilyNameRequest: Identifiable, Sendable {
    enum Kind: Sendable { case rename, merge, split }

    let id = UUID()
    var kind: Kind
    /// The faces whose `custom_family` the sheet sets: the family's (rename), all selected families' (merge), or the
    /// selected styles (split).
    var faceIDs: [Int64]
    /// Merge only: the selected families' keys and their names as shown (the picker's choices).
    var familyKeys: [String] = []
    var names: [String] = []
    /// The name the field starts with.
    var initialName: String

    var title: String {
        switch kind {
        case .rename: "Rename Family"
        case .merge: "Merge Families"
        case .split: "Move to New Family"
        }
    }
}

/// Family Editor (spec §19): rename, merge and split families by setting `faces.custom_family`, inside Fontory only
/// (files are never modified), with one level of undo kept in memory. Store access runs off the main actor.
extension AppModel {
    static let familyEditorNote = "Names change only in Fontory. Other apps still show the original names."

    static func clashWarning(_ name: String) -> String {
        "A family named \(name) already exists. Its fonts and these will show as one family."
    }

    /// The edited mark's tooltip.
    static func editedTooltip(_ originals: [String]) -> String {
        "Original: " + originals.joined(separator: ", ")
    }

    /// The original names of an edited family (by its shown name), nil when no face of it has a custom name.
    func editedOriginals(ofFamily name: String) -> [String]? {
        editedFamilies[name.lowercased()]
    }

    var canUndoFamilyEdit: Bool { familyUndo != nil }

    /// ⌘Z is taken for the family edit only when it is plain ⌘Z, the browser window is key, no text is being edited
    /// there (a field editor or text view is not first responder) and there is an edit to undo. Otherwise it keeps
    /// its normal meaning (text undo in the Text tab, the search field, sheets).
    static func handlesFamilyUndoKey(isCommandZ: Bool, browserIsKey: Bool, editingText: Bool, canUndo: Bool) -> Bool {
        isCommandZ && browserIsKey && !editingText && canUndo
    }

    // MARK: Edits

    func renameFamily(faceIDs: [Int64], to name: String) async {
        await applyFamilyEdit(faceIDs: faceIDs, split: false) { try $0.setCustomFamily(name, faceIDs: faceIDs) }
    }

    func mergeFamilies(_ familyKeys: [String], into name: String) async {
        var ids: [Int64] = []
        for key in familyKeys { ids += await familyFaceIDs(named: key) }
        guard !ids.isEmpty else { return }
        await renameFamily(faceIDs: ids, to: name)
    }

    func moveToNewFamily(faceIDs: [Int64], name: String) async {
        await applyFamilyEdit(faceIDs: faceIDs, split: true) { try $0.setCustomFamily(name, faceIDs: faceIDs) }
    }

    /// Clears the override only on the faces that have one.
    func useOriginalNames(faceIDs: [Int64]) async {
        await applyFamilyEdit(faceIDs: faceIDs, split: false) { try $0.clearCustomFamilies(faceIDs: faceIDs) }
    }

    func undoLastFamilyEdit() async {
        guard let backend, let previous = familyUndo else { return }
        familyUndo = nil
        await whileFollowingFamilyEdit {
            let ok: Bool? = await runBackground({ try backend.store.restoreCustomFamilies(previous); return true },
                                                failureTitle: "The family edit could not be undone")
            if ok == true { await afterFamilyEdit(changed: Array(previous.keys), split: false) }
        }
    }

    /// Whether another family (faces outside `excluding`) already has this name, compared case-insensitively.
    func familyClash(name: String, excluding: Set<Int64>) async -> Bool {
        await familyClashName(name: name, excluding: excluding) != nil
    }

    /// The existing family's name as shown when `name` clashes with it (for the warning), else nil.
    func familyClashName(name: String, excluding: Set<Int64>) async -> String? {
        guard let backend else { return nil }
        return await runBackground { () -> String? in
            guard let id = try backend.store.existingFamilyFaceIDs(named: name, excluding: excluding).first else { return nil }
            return try backend.store.rows(ids: [id])[id]?.family ?? name
        } ?? nil
    }

    /// Every face of a family (system ones included, so the whole family moves), by name or key.
    func familyFaceIDs(named name: String) async -> [Int64] {
        guard let backend else { return [] }
        return await runBackground { try backend.store.family(named: name, includeSystem: true)?.faceIDs ?? [] } ?? []
    }

    func reloadEditedFamilies() async {
        guard let backend, let map = await runBackground({ try backend.store.editedFamilies() }) else { return }
        guard map != editedFamilies else { return }
        editedFamilies = map
        // Cards draw the mark when they are configured: reconfigure the visible ones.
        invalidateRows()
    }

    // MARK: Sheet requests (menus and the family page)

    func beginRenameFamily(named name: String) {
        Task {
            let ids = await familyFaceIDs(named: name)
            guard !ids.isEmpty else { return }
            familyNameRequest = FamilyNameRequest(kind: .rename, faceIDs: ids, initialName: name)
        }
    }

    /// `names`: the selected families as shown, in order (one per family).
    func beginMergeFamilies(named names: [String]) {
        guard names.count >= 2 else { return }
        Task {
            var ids: [Int64] = []
            for name in names { ids += await familyFaceIDs(named: name) }
            guard !ids.isEmpty else { return }
            familyNameRequest = FamilyNameRequest(kind: .merge, faceIDs: ids, familyKeys: names.map { $0.lowercased() },
                                                  names: names, initialName: names[0])
        }
    }

    func beginMoveToNewFamily(faceIDs: [Int64]) {
        guard !faceIDs.isEmpty else { return }
        familyNameRequest = FamilyNameRequest(kind: .split, faceIDs: faceIDs, initialName: "")
    }

    func useOriginalNames(ofFamilies names: [String]) {
        Task {
            var ids: [Int64] = []
            for name in names { ids += await familyFaceIDs(named: name) }
            await useOriginalNames(faceIDs: ids)
        }
    }

    /// The sheet's Save.
    func commitFamilyName(_ request: FamilyNameRequest, name: String) async {
        switch request.kind {
        case .rename: await renameFamily(faceIDs: request.faceIDs, to: name)
        case .merge: await mergeFamilies(request.familyKeys, into: name)
        case .split: await moveToNewFamily(faceIDs: request.faceIDs, name: name)
        }
    }

    // MARK: Private

    private func applyFamilyEdit(faceIDs: [Int64], split: Bool,
                                 _ work: @escaping @Sendable (FontStore) throws -> [Int64: String?]) async {
        guard let backend, !faceIDs.isEmpty else { return }
        await whileFollowingFamilyEdit {
            guard let previous = await runBackground({ try work(backend.store) },
                                                     failureTitle: "The family names could not be changed") else { return }
            // A no-op ("Use Original Names" on a family without edits) keeps the previous undo.
            if !previous.isEmpty { familyUndo = previous }
            await afterFamilyEdit(changed: faceIDs, split: split)
        }
    }

    /// Reloads what shows family names: rows (grid, list, family page), the edited marks, counts and organization,
    /// the browser, and the open family page (under its new name after a rename; a split keeps it on the old family).
    private func afterFamilyEdit(changed: [Int64], split: Bool) async {
        invalidateRows()
        await reloadEditedFamilies()
        if let current = detail {
            let moved = Set(changed)
            let follow = split ? current.faceIDs.first { !moved.contains($0) } ?? current.representativeID
                : current.representativeID
            await reopenFamilyDetail(following: follow)
        }
        refreshCounts()
        scheduleRefresh(delay: .zero)
    }
}
