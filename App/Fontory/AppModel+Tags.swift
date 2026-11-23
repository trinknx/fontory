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
    /// recovered from the difference, and `modifiers` decide the meaning (see `selectTag`). `time` is the click's
    /// event timestamp (system uptime clock; see `optionClickTag`).
    func applySidebarSelection(_ new: Set<SidebarItem>, modifiers: EventModifiers,
                               time: TimeInterval = ProcessInfo.processInfo.systemUptime) {
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
            if modifiers.contains(.option) {
                optionClickTag(id, modifiers: modifiers, time: time)
            } else {
                selectTag(id, modifiers: modifiers)
            }
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

    /// Two reports of the same tag within this many seconds are one ⌥-click.
    static let optionClickWindow: TimeInterval = 0.4

    /// An ⌥-click on a tag row. Both the list's selection change (mouse-down) and the row's click handler
    /// (mouse-up) may report it: the list alone can stay silent on an already-selected row, the handler alone can
    /// miss the row's edges. A report for the same tag within `optionClickWindow` of the last applied one is the same
    /// click and is dropped. `time` uses the system uptime clock (`NSEvent.timestamp`).
    func optionClickTag(_ id: Int64, modifiers: EventModifiers, time: TimeInterval) {
        if let last = lastOptionClick, last.tagID == id, abs(time - last.time) < Self.optionClickWindow { return }
        lastOptionClick = (id, time)
        selectTag(id, modifiers: modifiers)
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
    func afterTagChange() async {
        tagAssignmentVersion += 1
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
    func tagWrite<T: Sendable>(_ title: String, _ work: @escaping @Sendable (FontStore) throws -> T) async -> T? {
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

    /// ⊕ New Smart Tag…: opens the editor on a new, unsaved smart tag (one "Name contains" row). Nothing is
    /// written until Save.
    func newSmartTag() {
        var rule = SmartRule()
        rule.conditions = [SmartRule.Condition(field: .name, op: .contains, value: .text(""))]
        smartTagEditor = SmartTagEditorState(tagID: nil, name: untitledName("Untitled Smart Tag", parentID: nil), rule: rule)
    }

    /// Edit…: opens the editor on an existing smart tag.
    func editSmartTag(_ id: Int64) {
        guard let record = tag(id), record.kind == .smart else { return }
        let rule = SmartRule.decode(record.ruleJSON ?? "") ?? SmartRule()
        smartTagEditor = SmartTagEditorState(tagID: id, name: record.name, rule: rule)
    }

    /// Cancel: drops the draft.
    func cancelSmartTagEditor() {
        smartTagEditor?.countTask?.cancel()
        smartTagEditor = nil
    }

    /// Save: writes the name and rule (a new smart tag is created at the top level). A `TagError` (empty or
    /// duplicate name) shows the alert and keeps the sheet and its draft. Returns success.
    @discardableResult
    func saveSmartTag(_ editor: SmartTagEditorState) async -> Bool {
        guard !editor.isSaving else { return false }
        editor.isSaving = true
        defer { editor.isSaving = false }
        let name = editor.name
        let json = editor.rule.encoded()
        let savedID: Int64?
        if let id = editor.tagID {
            savedID = await tagWrite("The smart tag could not be saved") { store in
                try store.renameTag(id, to: name)
                try store.setTagRule(id, ruleJSON: json)
                return id
            }
        } else {
            savedID = await tagWrite("The smart tag could not be created") {
                try $0.createTag(name: name, parentID: nil, kind: .smart, ruleJSON: json)
            }
        }
        guard let savedID else { return false }
        editor.countTask?.cancel()
        if smartTagEditor === editor { smartTagEditor = nil }
        await afterTagChange()
        // A new smart tag is shown at once.
        if editor.tagID == nil, tag(savedID) != nil { query.scope = .tags([tagPick(savedID)]) }
        return true
    }

    /// The editor's live count, debounced 150 ms; only the latest request's result is kept.
    func scheduleSmartTagCount(_ editor: SmartTagEditorState) {
        guard let backend else { return }
        editor.countGeneration += 1
        let generation = editor.countGeneration
        editor.countTask?.cancel()
        let countQuery = LibraryQuery(scope: .tags([TagPick(tagID: editor.tagID ?? -1, inverted: false, rule: editor.rule)]),
                                      includeSystem: query.includeSystem)
        editor.countTask = Task { [weak self, weak editor] in
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled, let self else { return }
            let count = await self.runBackground({ try backend.store.faceIDs(for: countQuery).count },
                                                 failureTitle: "smart tag count")
            guard let editor, let count, generation == editor.countGeneration else { return }
            editor.matchCount = count
        }
    }

    func renameTag(_ id: Int64, to name: String) async {
        if renamingTagID == id { renamingTagID = nil }
        guard let current = tag(id), current.name != name.trimmingCharacters(in: .whitespacesAndNewlines) else { return }
        if await tagWrite("The tag could not be renamed", { try $0.renameTag(id, to: name) }) != nil {
            await afterTagChange()
        }
    }

    /// A tag dropped on a tag row (`target`) or on the Tags header (nil). Dropping a tag on itself does nothing;
    /// onto its own subtag the store refuses the cycle and an alert says so.
    func dropTag(_ id: Int64, onto target: Int64?) async {
        guard id != target else { return }
        await moveTag(id, toParent: target)
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
        if let editing = smartTagEditor?.tagID, doomed.contains(editing) { cancelSmartTagEditor() }
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

    // MARK: Assigning (drag and drop, context menu, ⌘T panel, Info)

    /// Plain tags in sidebar tree order with their depth (smart tags take no assignments).
    func plainTagTree() -> [(tag: TagRecord, depth: Int)] {
        var out: [(tag: TagRecord, depth: Int)] = []
        func walk(_ parentID: Int64?, _ depth: Int) {
            for tag in childTags(of: parentID) where tag.kind == .tag {
                out.append((tag, depth))
                walk(tag.id, depth + 1)
            }
        }
        walk(nil, 0)
        return out
    }

    /// "Parent/Child" for a nested tag, the name alone at the top level.
    func tagPath(_ id: Int64) -> String {
        var parts: [String] = []
        var next: Int64? = id
        var seen: Set<Int64> = []
        while let current = next, seen.insert(current).inserted, let record = tag(current) {
            parts.append(record.name)
            next = record.parentID
        }
        return parts.reversed().joined(separator: "/")
    }

    /// Direct tags of each face (faces without tags are absent), read off the main actor. Nil on failure.
    func faceTagMap(_ faceIDs: [Int64]) async -> [Int64: Set<Int64>]? {
        guard let backend, !faceIDs.isEmpty else { return faceIDs.isEmpty ? [:] : nil }
        return await runBackground { try backend.store.tagIDs(forFaces: faceIDs) }
    }

    /// The checkbox state of every tag in `map` for the faces `faceIDs`: on when all have it, mixed when some do.
    /// Tags no face has are absent (off).
    nonisolated static func tagStates(_ map: [Int64: Set<Int64>], faces faceIDs: [Int64]) -> [Int64: TagCheckState] {
        let faces = Set(faceIDs)
        guard !faces.isEmpty else { return [:] }
        var counts: [Int64: Int] = [:]
        for face in faces { for tagID in map[face] ?? [] { counts[tagID, default: 0] += 1 } }
        return counts.mapValues { $0 == faces.count ? .on : .mixed }
    }

    /// A checkbox click: on removes the tag from every face, off or mixed adds it to every face.
    func toggleTag(_ tagID: Int64, onFaces faceIDs: [Int64], from state: TagCheckState) async {
        await setTag(tagID, onFaces: faceIDs, included: state != .on)
    }

    /// Whether the ⌘T panel's typed text names an existing plain tag: a top-level name or a full path, by identity
    /// (`TagSearch.identity`, not fuzzy matching), so "Mới" can be created next to "Môi".
    func plainTagExists(named text: String) -> Bool {
        let key = TagSearch.identity(text)
        return tags.contains {
            $0.kind == .tag && (($0.parentID == nil && TagSearch.identity($0.name) == key) || TagSearch.identity(tagPath($0.id)) == key)
        }
    }

    /// "New Tag…" and the panel's Create row: a top-level tag named `name` assigned to `faceIDs`. An existing
    /// top-level tag with the same identity (`TagSearch.identity`: case only, so "Mới" and "Môi" stay apart) is
    /// reused. Returns its id.
    @discardableResult
    func createTagAndAssign(name: String, faces faceIDs: [Int64]) async -> Int64? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let key = TagSearch.identity(trimmed)
        let id: Int64
        if let existing = tags.first(where: { $0.parentID == nil && $0.kind == .tag && TagSearch.identity($0.name) == key }) {
            id = existing.id
        } else {
            guard let created = await createTag(name: trimmed, parentID: nil) else { return nil }
            await assignNewTag(created, toFaces: faceIDs)
            return created
        }
        await setTag(id, onFaces: faceIDs, included: true)
        return id
    }

    /// Tags faces with a plain tag created just now. Unlike `setTag` it does not look the tag up in `tags`: a
    /// newer organization reload (the backfill's, say) can drop the one that would have listed it.
    func assignNewTag(_ tagID: Int64, toFaces faceIDs: [Int64]) async {
        guard !faceIDs.isEmpty else { return }
        if await tagWrite("The fonts could not be tagged", { try $0.addTag(tagID, toFaces: faceIDs) }) != nil {
            await afterTagChange()
        }
    }

    /// Fonts dragged from the browser may be dropped on plain tag rows only; Style rows, smart tags and Library
    /// rows refuse them.
    func acceptsFaceDrop(on item: SidebarItem) -> Bool {
        if case .tag(let id) = item { return tag(id)?.kind == .tag }
        return false
    }

    /// Fonts dropped on a sidebar row: a plain tag is added to them, or removed with ⌥ (`removing`). Returns
    /// whether the drop was taken.
    @discardableResult
    func dropFaces(_ faceIDs: [Int64], on item: SidebarItem, removing: Bool) async -> Bool {
        guard !faceIDs.isEmpty, acceptsFaceDrop(on: item), case .tag(let id) = item else { return false }
        await setTag(id, onFaces: faceIDs, included: !removing)
        return true
    }

    /// The faces ⌘T acts on: the selected styles on the family page, else the browser selection, in list order.
    var tagPanelTargets: [Int64] {
        if detail != nil, !detailSelection.isEmpty { return detailSelection.sorted() }
        guard !selection.isEmpty else { return [] }
        let ordered = faceIDs.filter(selection.contains)
        return ordered.count == selection.count ? ordered : selection.sorted()
    }

    /// ⌘T: the tag panel for `faceIDs` (default: `tagPanelTargets`). Does nothing without faces.
    func showTagPanel(for faceIDs: [Int64]? = nil) {
        let targets = faceIDs ?? tagPanelTargets
        guard !targets.isEmpty else { return }
        tagPanel = TagPanelRequest(faceIDs: targets)
    }
}

/// A tag's checkbox for a set of faces.
enum TagCheckState: Sendable, Hashable {
    case off, on, mixed
}

/// What the ⌘T panel is open for.
struct TagPanelRequest: Identifiable {
    let id = UUID()
    let faceIDs: [Int64]
}

/// Tag names. Matching (filtering the ⌘T list) ignores case and diacritics; identity (is this the same tag?)
/// ignores case only, like the store's sibling uniqueness, since diacritics tell Vietnamese words apart.
enum TagSearch {
    /// Identity key: trimmed, case folded (the store's `TagName.fold`), diacritics kept.
    static func identity(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespacesAndNewlines).folding(options: [.caseInsensitive], locale: nil)
    }

    /// Folded for comparison: case and diacritics removed, and đ read as d (a letter of its own, not an accent).
    static func fold(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .replacingOccurrences(of: "đ", with: "d")
    }

    /// Nil when `query` is not a subsequence of `candidate`; else a rank, lower is better: 0 the path starts with
    /// it, 1 the last name starts with it, 2 it is contained, 3+ a scattered subsequence (more gaps rank lower).
    static func score(_ query: String, in candidate: String) -> Int? {
        let q = fold(query.trimmingCharacters(in: .whitespacesAndNewlines))
        if q.isEmpty { return 0 }
        let c = fold(candidate)
        if c.hasPrefix(q) { return 0 }
        if let last = c.split(separator: "/").last, last.hasPrefix(q) { return 1 }
        if c.contains(q) { return 2 }
        var gaps = 0
        var qi = q.startIndex
        var previousMatched = true
        for ch in c where qi < q.endIndex {
            if ch == q[qi] {
                if !previousMatched { gaps += 1 }
                previousMatched = true
                qi = q.index(after: qi)
            } else {
                previousMatched = false
            }
        }
        return qi == q.endIndex ? 3 + gaps : nil
    }
}
