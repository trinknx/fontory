import FontoryCore
import SwiftUI

/// One selectable sidebar row. Tag rows are kept apart from the other scopes so several can be selected at once
/// (⌘-click union) while Library rows and locations stay single-select.
enum SidebarItem: Hashable, Sendable {
    case scope(LibraryQuery.Scope)
    case tag(Int64)
}

extension TagError {
    var message: String {
        switch self {
        case .duplicateName: "A tag with that name already exists at this level."
        case .cycle: "A tag cannot be moved into itself or one of its subtags."
        case .notFound: "The tag no longer exists."
        case .emptyName: "A tag needs a name."
        }
    }
}

/// Tags: sidebar selection, CRUD, assignment and the tag counts. Store calls run off the main actor.
extension AppModel {
    // MARK: Lookup

    func tag(_ id: Int64) -> TagRecord? { tags.first { $0.id == id } }

    /// Direct children of `parentID` (nil: top level), case-insensitive name order.
    func childTags(of parentID: Int64?) -> [TagRecord] {
        tags.filter { $0.parentID == parentID }
            .sorted {
                let order = $0.name.localizedCaseInsensitiveCompare($1.name)
                return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
            }
    }

    /// `id` and every tag below it.
    func descendantTagIDs(of id: Int64) -> Set<Int64> {
        var out: Set<Int64> = [id]
        var frontier = [id]
        while let next = frontier.popLast() {
            for child in tags where child.parentID == next && out.insert(child.id).inserted { frontier.append(child.id) }
        }
        return out
    }

    /// The row count: distinct faces with the tag or a subtag, or matching the smart rule.
    func tagCount(_ tag: TagRecord) -> Int {
        tag.kind == .smart ? smartTagCounts[tag.id] ?? 0 : organizationCounts.perTag[tag.id] ?? 0
    }

    /// The query pick for a tag; a smart tag carries its decoded rule.
    func tagPick(_ id: Int64, inverted: Bool = false) -> TagPick {
        let record = tag(id)
        let rule = record?.kind == .smart ? SmartRule.decode(record?.ruleJSON ?? "") : nil
        return TagPick(tagID: id, inverted: inverted, rule: rule)
    }

    /// The tag picks of the current view, empty when it is not a tag view.
    var selectedTagPicks: [TagPick] {
        if case .tags(let picks) = query.scope { return picks }
        return []
    }

    // MARK: Selection

    /// The sidebar's selection, derived from the query scope.
    var sidebarSelection: Set<SidebarItem> {
        if case .tags(let picks) = query.scope { return Set(picks.map { .tag($0.tagID) }) }
        return [.scope(query.scope)]
    }

    /// Applies a selection change made by the sidebar list. The list handles ⌘-click by itself; the clicked row is
    /// recovered from the difference, and `modifiers` decide the meaning (see `selectTag`).
    func applySidebarSelection(_ new: Set<SidebarItem>, modifiers: EventModifiers) {
        let old = sidebarSelection
        let added = new.subtracting(old)
        let removed = old.subtracting(new)
        let clicked: SidebarItem?
        if new.count == 1 && !modifiers.contains(.command) {
            clicked = new.first
        } else if added.count == 1 {
            clicked = added.first
        } else if added.isEmpty && removed.count == 1 {
            clicked = removed.first
        } else {
            clicked = nil
        }
        switch clicked {
        case .tag(let id)?:
            // ⌥-clicks are applied by the row's own click handler (the list may not report a click on a row that
            // is already selected).
            guard !modifiers.contains(.option) else { return }
            selectTag(id, modifiers: modifiers)
        case .scope(let scope)?:
            query.scope = scope
        case nil:
            // A range (shift-click): tags in it become a union, else the first other row wins.
            let tagIDs = new.compactMap { if case .tag(let id) = $0 { id } else { nil } }
            if !tagIDs.isEmpty {
                let current = Dictionary(selectedTagPicks.map { ($0.tagID, $0) }, uniquingKeysWith: { a, _ in a })
                query.scope = .tags(tagIDs.sorted().map { current[$0] ?? tagPick($0) })
            } else if case .scope(let scope)? = new.first {
                query.scope = scope
            }
        }
    }

    /// Click: shows the tag alone. ⌘: adds it to (or removes it from) the union of selected tags.
    /// ⌥: shows the fonts without it (again: back to with it). ⌘⌥: adds it inverted, or flips it in the union.
    func selectTag(_ id: Int64, modifiers: EventModifiers) {
        guard tag(id) != nil else { return }
        var picks = selectedTagPicks
        let index = picks.firstIndex { $0.tagID == id }
        switch (modifiers.contains(.command), modifiers.contains(.option)) {
        case (false, false):
            picks = [tagPick(id)]
        case (false, true):
            let wasInverted = picks.count == 1 && index != nil && picks[0].inverted
            picks = [tagPick(id, inverted: !wasInverted)]
        case (true, false):
            if let index {
                guard picks.count > 1 else { return }  // the last tag stays selected
                picks.remove(at: index)
            } else {
                picks.append(tagPick(id))
            }
        case (true, true):
            if let index { picks[index].inverted.toggle() } else { picks.append(tagPick(id, inverted: true)) }
        }
        query.scope = .tags(picks)
    }

    // MARK: Loading

    /// Reloads the tags and their counts (also run by `refreshCounts`). Results of an older call are dropped.
    func reloadOrganization() async {
        guard let backend else { return }
        organizationGeneration += 1
        let generation = organizationGeneration
        let includeSystem = query.includeSystem
        guard let org = await runBackground({ try backend.organization(includeSystem: includeSystem) }),
              generation == organizationGeneration else { return }
        if org.tags != tags { tags = org.tags }
        if org.counts != organizationCounts { organizationCounts = org.counts }
        if org.smartCounts != smartTagCounts { smartTagCounts = org.smartCounts }
        expandedTagIDs.formIntersection(org.tags.map(\.id))
    }

    /// After tags or assignments change: counts, and the browser when it shows something tag-based.
    private func afterTagChange() async {
        await reloadOrganization()
        switch query.scope {
        case .tags(let picks):
            // Keep smart picks' rules in step with the stored ones.
            let fresh = picks.map { tagPick($0.tagID, inverted: $0.inverted) }
            if fresh != picks { query.scope = .tags(fresh) } else { scheduleRefresh() }
        case .untagged: scheduleRefresh()
        default: break
        }
    }

    private func tagFailure(_ error: Error, title: String) {
        let message = (error as? TagError)?.message ?? error.localizedDescription
        alert = AlertItem(title: title, message: message)
    }

    /// Runs a store write off the main actor; on failure shows an alert titled `title`. Returns success.
    private func tagWrite<T: Sendable>(_ title: String, _ work: @escaping @Sendable (FontStore) throws -> T) async -> T? {
        guard let backend else { return nil }
        let store = backend.store
        let result = await Task.detached(priority: .userInitiated) { Result { try work(store) } }.value
        switch result {
        case .success(let value): return value
        case .failure(let error):
            tagFailure(error, title: title)
            return nil
        }
    }

    // MARK: CRUD

    /// Creates a tag; on `TagError` shows an alert and returns nil.
    @discardableResult
    func createTag(name: String, parentID: Int64?, kind: TagKind = .tag, ruleJSON: String? = nil) async -> Int64? {
        let id = await tagWrite("The tag could not be created") {
            try $0.createTag(name: name, parentID: parentID, kind: kind, ruleJSON: ruleJSON)
        }
        if id != nil {
            if let parentID { expandedTagIDs.insert(parentID) }
            await afterTagChange()
        }
        return id
    }

    /// A free "Untitled Tag" name (numbered when taken) among the children of `parentID`.
    private func untitledName(_ base: String, parentID: Int64?) -> String {
        let taken = Set(tags.filter { $0.parentID == parentID }.map { $0.name.lowercased() })
        if !taken.contains(base.lowercased()) { return base }
        var n = 2
        while taken.contains("\(base) \(n)".lowercased()) { n += 1 }
        return "\(base) \(n)"
    }

    /// ⊕ New Tag / New Subtag: creates "Untitled Tag" and starts its inline rename.
    func newTag(parentID: Int64? = nil) async {
        guard let id = await createTag(name: untitledName("Untitled Tag", parentID: parentID), parentID: parentID) else { return }
        renamingTagID = id
    }

    /// ⊕ New Smart Tag…: creates an empty smart tag (matches every font) and opens its editor.
    func newSmartTag() async {
        guard let id = await createTag(name: untitledName("Untitled Smart Tag", parentID: nil), parentID: nil,
                                       kind: .smart, ruleJSON: SmartRule().encoded()) else { return }
        renamingTagID = id
        editSmartTag(id)
    }

    /// Opens the smart tag editor. Task 8 presents its sheet from `editingSmartTagID`.
    func editSmartTag(_ id: Int64) {
        guard tag(id)?.kind == .smart else { return }
        editingSmartTagID = id
    }

    func renameTag(_ id: Int64, to name: String) async {
        if renamingTagID == id { renamingTagID = nil }
        guard let current = tag(id), current.name != name.trimmingCharacters(in: .whitespacesAndNewlines) else { return }
        if await tagWrite("The tag could not be renamed", { try $0.renameTag(id, to: name) }) != nil {
            await afterTagChange()
        }
    }

    /// Nests `id` under `parentID` (nil: top level).
    func moveTag(_ id: Int64, toParent parentID: Int64?) async {
        guard let current = tag(id), current.parentID != parentID, id != parentID else { return }
        if let parentID, tag(parentID)?.kind == .smart { return }  // smart tags take no subtags
        if await tagWrite("The tag could not be moved", { try $0.moveTag(id, toParent: parentID) }) != nil {
            if let parentID { expandedTagIDs.insert(parentID) }
            await afterTagChange()
        }
    }

    /// Deletes the tag and its subtags (their assignments go with them). A view showing any of them falls back to
    /// the remaining picks, or to All.
    func deleteTag(_ id: Int64) async {
        let doomed = descendantTagIDs(of: id)
        guard await tagWrite("The tag could not be deleted", { try $0.deleteTag(id) }) != nil else { return }
        if let renaming = renamingTagID, doomed.contains(renaming) { renamingTagID = nil }
        if let editing = editingSmartTagID, doomed.contains(editing) { editingSmartTagID = nil }
        let picks = selectedTagPicks
        if !picks.isEmpty {
            let kept = picks.filter { !doomed.contains($0.tagID) }
            if kept.count != picks.count { query.scope = kept.isEmpty ? .all : .tags(kept) }
        }
        await afterTagChange()
    }

    /// Delete…: asks first when the tag has fonts or subtags.
    func confirmDeleteTag(_ id: Int64) {
        guard let record = tag(id) else { return }
        let subtags = descendantTagIDs(of: id).count - 1
        let fonts = record.kind == .tag ? organizationCounts.perTag[id] ?? 0 : 0
        guard subtags > 0 || fonts > 0 else {
            Task { await deleteTag(id) }
            return
        }
        var parts: [String] = []
        if fonts > 0 { parts.append("\(fonts.formatted()) font\(fonts == 1 ? " is" : "s are") tagged with it.") }
        if subtags > 0 { parts.append("Its \(subtags.formatted()) subtag\(subtags == 1 ? "" : "s") will be deleted too.") }
        parts.append("The fonts themselves stay in the library.")
        var item = AlertItem(title: "Delete the tag “\(record.name)”?", message: parts.joined(separator: " "))
        item.actionTitle = "Delete"
        item.isDestructive = true
        item.action = { [weak self] in Task { await self?.deleteTag(id) } }
        alert = item
    }

    // MARK: Assignment

    /// Adds (`included`) or removes a plain tag on faces.
    func setTag(_ tagID: Int64, onFaces faceIDs: [Int64], included: Bool) async {
        guard !faceIDs.isEmpty, tag(tagID)?.kind == .tag else { return }
        let ok = await tagWrite(included ? "The fonts could not be tagged" : "The tag could not be removed") {
            if included { try $0.addTag(tagID, toFaces: faceIDs) } else { try $0.removeTag(tagID, fromFaces: faceIDs) }
        }
        if ok != nil { await afterTagChange() }
    }

    /// Activate All / Deactivate All: every face showing under the tag (system fonts are locked anyway).
    func activateTag(_ id: Int64, on: Bool) async {
        guard let backend else { return }
        let query = LibraryQuery(scope: .tags([tagPick(id)]), includeSystem: query.includeSystem)
        guard let ids = await runBackground({ try backend.store.faceIDs(for: query) }), !ids.isEmpty else { return }
        await setActivation(ids, on ? .on : .off)
    }
}
