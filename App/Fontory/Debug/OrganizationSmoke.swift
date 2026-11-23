#if DEBUG
import AppKit
import Foundation
import FontoryCore
import SwiftUI

/// `-FontoryOrganizationSmoke`: exercises tags through `AppModel`'s public actions on a fresh temporary library
/// (synthetic faces, no font files, nothing activated), prints PASS/FAIL lines and exits (status 1 on any FAIL).
/// It never opens `~/Library/Application Support/Fontory`. Later organization tasks add their steps here.
@MainActor
enum OrganizationSmoke {
    static let argument = "-FontoryOrganizationSmoke"

    static func runAndExit() -> Never {
        Task { @MainActor in
            let ok = await run()
            print("SMOKE \(ok ? "PASSED" : "FAILED")")
            exit(ok ? 0 : 1)
        }
        dispatchMain()
    }

    private static var failures = 0

    private static func check(_ condition: Bool, _ name: String, _ detail: @autoclosure () -> String = "") {
        if condition {
            print("PASS \(name)")
        } else {
            failures += 1
            let d = detail()
            print("FAIL \(name)\(d.isEmpty ? "" : ": \(d)")")
        }
    }

    static func run() async -> Bool {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("FontoryOrganizationSmoke-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let backend = try LibraryBackend(databaseURL: dir.appendingPathComponent("library.sqlite"))
            let faces = try seed(backend.store, folder: dir)
            print("library: \(dir.path) (\(faces.count) faces)")
            let model = AppModel()
            await model.attachBackendForSmoke(backend)
            await steps(model, faces: faces)
            await assignmentSteps(model, faces: faces)
            await noteSteps(model, faces: faces)
            await quickCollectionSteps(model, faces: faces)
            await backfillSteps(model, backend: backend, folder: dir)
            await smartEditorSteps(model, backend: backend)
        } catch {
            check(false, "setup", "\(error)")
        }
        return failures == 0
    }

    /// Three synthetic faces in one folder location: Smoke Serif, Smoke Sans, Smoke Mono.
    private static func seed(_ store: FontStore, folder: URL) throws -> [String: Int64] {
        let loc = try store.upsertLocation(kind: .folder, volumeUUID: "SMOKE-VOLUME", relativePath: "Fonts",
                                           displayName: "Smoke", lastKnownPath: folder.path)
        let batch = try store.nextImportBatch()
        let defs: [(String, StyleClass)] = [("Serif", .serif), ("Sans", .sans), ("Mono", .mono)]
        for (name, style) in defs {
            let face = ParsedFace(postScriptName: "Smoke\(name)-Regular", family: "Smoke \(name)", style: "Regular",
                                  fullName: "Smoke \(name) Regular", glyphCount: 100, styleClass: style)
            let file = FileRecord(locationID: loc.id, relativePath: "Smoke\(name).otf", size: 10, mtime: Date(timeIntervalSince1970: 1000),
                                  format: "otf", fingerprint: "smoke-\(name)")
            _ = try store.insertFile(file, faces: [face], importBatch: batch)
        }
        let ids = try store.faceIDs(for: LibraryQuery())
        var out: [String: Int64] = [:]
        for row in try store.rows(ids: ids).values { out[row.family] = row.id }
        return out
    }

    private static func shown(_ model: AppModel) async -> Set<Int64> {
        await model.refreshNowForSmoke()
        return Set(model.faceIDs)
    }

    private static func steps(_ model: AppModel, faces: [String: Int64]) async {
        guard let serif = faces["Smoke Serif"], let sans = faces["Smoke Sans"], let mono = faces["Smoke Mono"] else {
            check(false, "seed", "faces missing: \(faces)")
            return
        }
        let initial = await shown(model)
        check(initial == [serif, sans, mono], "All shows the 3 seeded faces")

        // Tags A and A/B; B on Serif.
        guard let a = await model.createTag(name: "A", parentID: nil),
              let b = await model.createTag(name: "B", parentID: a) else {
            check(false, "create A and A/B", model.alert?.message ?? "")
            return
        }
        check(model.tag(b)?.parentID == a && model.childTags(of: nil).map(\.id) == [a], "A/B nested under A")
        await model.setTag(b, onFaces: [serif], included: true)
        check(model.organizationCounts.perTag[a] == 1 && model.organizationCounts.perTag[b] == 1,
              "counts: A and B have 1 font", "\(model.organizationCounts.perTag)")
        check(model.organizationCounts.untagged == 2, "counts: 2 untagged", "\(model.organizationCounts.untagged)")

        model.selectTag(a, modifiers: [])
        let underA = await shown(model)
        check(underA == [serif], "select A shows the face tagged B", "\(underA)")

        // ⌥-click as the sidebar reports it: the list's selection change at mouse-down (t) and the row's click
        // handler at mouse-up (t + 0.1 s); it must invert exactly once.
        let t = ProcessInfo.processInfo.systemUptime + 1000
        model.applySidebarSelection([.tag(a)], modifiers: .option, time: t)
        model.optionClickTag(a, modifiers: .option, time: t + 0.1)
        let inverted = await shown(model)
        check(!inverted.contains(serif) && inverted == [sans, mono], "⌥-select A hides it", "\(inverted)")
        check(model.selectedTagPicks.first?.inverted == true && model.sidebarSelection == [.tag(a)], "⌥-select A is an inverted pick")
        // A second genuine ⌥-click 1 s later, reported by both paths (down, then up 0.1 s later), inverts back once.
        model.applySidebarSelection([.tag(a)], modifiers: .option, time: t + 1)
        model.optionClickTag(a, modifiers: .option, time: t + 1.1)
        check(model.selectedTagPicks.first?.inverted == false, "second ⌥-click 1 s later un-inverts it, once")
        // Reported only by the row handler (list silent on the selected row): applied.
        model.optionClickTag(a, modifiers: .option, time: t + 2.1)
        check(model.selectedTagPicks.first?.inverted == true, "⌥-click reported only by the row handler inverts")
        // Reported only by the list (click outside the handler's shape): applied.
        model.applySidebarSelection([.tag(a)], modifiers: .option, time: t + 3)
        check(model.selectedTagPicks.first?.inverted == false, "⌥-click reported only by the list un-inverts")
        model.applySidebarSelection([.tag(a)], modifiers: .option, time: t + 4)
        check(model.selectedTagPicks.first?.inverted == true, "⌥-click again inverts (A shown without its fonts)")

        // ⌘-click union with a second tag.
        guard let c = await model.createTag(name: "c", parentID: nil) else { check(false, "create c"); return }
        await model.setTag(c, onFaces: [mono], included: true)
        model.selectTag(a, modifiers: [])
        model.selectTag(c, modifiers: .command)
        let union = await shown(model)
        check(union == [serif, mono], "⌘-select A + c shows the union", "\(union)")
        check(model.childTags(of: nil).map(\.name) == ["A", "c"], "tags in case-insensitive name order")

        // Sidebar list changes: a plain click on another row replaces the selection.
        model.applySidebarSelection([.scope(.untagged)], modifiers: [])
        let untagged = await shown(model)
        check(model.query.scope == .untagged && untagged == [sans], "Untagged shows the untagged face", "\(untagged)")

        // Errors surface as alerts.
        _ = await model.createTag(name: "a", parentID: nil)
        check(model.alert != nil, "duplicate name (case-insensitive) shows an alert")
        model.alert = nil
        await model.dropTag(a, onto: b)
        check(model.alert != nil && model.tag(a)?.parentID == nil, "dropping A on its subtag B shows an alert")
        model.alert = nil
        await model.dropTag(a, onto: a)
        check(model.alert == nil && model.tag(a)?.parentID == nil, "dropping A on itself does nothing")

        // Nest and un-nest (the drag-and-drop actions).
        await model.dropTag(c, onto: a)
        check(model.tag(c)?.parentID == a && model.organizationCounts.perTag[a] == 2, "drop c on A nests it")
        await model.dropTag(c, onto: nil)
        check(model.tag(c)?.parentID == nil && model.organizationCounts.perTag[a] == 1, "drop c on the header un-nests it")

        await model.renameTag(c, to: "C2")
        check(model.tag(c)?.name == "C2", "rename")

        // Style group.
        check(model.organizationCounts.perStyle[.serif] == 1 && model.organizationCounts.perStyle[.mono] == 1,
              "style counts", "\(model.organizationCounts.perStyle)")
        model.applySidebarSelection([.scope(.styleClass(.sans))], modifiers: [])
        let sansShown = await shown(model)
        check(sansShown == [sans], "Style ▸ Sans shows the sans face")

        // Smart tag: New Smart Tag… opens the editor on an unsaved draft; Save creates it.
        let tagsBefore = model.tags.count
        model.newSmartTag()
        check(model.smartTagEditor?.tagID == nil && model.tags.count == tagsBefore,
              "New Smart Tag opens the editor without creating a tag")
        if let editor = model.smartTagEditor {
            await model.saveSmartTag(editor)
        }
        let smart = model.tags.first { $0.kind == .smart }
        check(smart != nil && model.smartTagEditor == nil, "Save creates the smart tag and closes the editor", model.alert?.message ?? "")
        if let smart {
            check(model.smartTagCounts[smart.id] == 3, "smart tag count", "\(model.smartTagCounts)")
            model.selectTag(smart.id, modifiers: [])
            let matched = await shown(model)
            check(model.selectedTagPicks.first?.rule != nil && matched == [serif, sans, mono], "smart tag pick carries its rule")
        }

        await model.newTag()
        check(model.tags.contains { $0.name == "Untitled Tag" && $0.id == model.renamingTagID }, "New Tag starts an inline rename")

        // Deleting the selected tag (via its ancestor) falls back to All.
        model.selectTag(b, modifiers: [])
        await model.deleteTag(a)
        check(model.query.scope == .all, "deleting A while A/B is selected falls back to All", "\(model.query.scope)")
        check(model.tag(a) == nil && model.tag(b) == nil, "A and its subtag are gone")
        check(model.organizationCounts.untagged == 2, "counts refresh after delete", "\(model.organizationCounts.untagged)")

        model.selectTag(c, modifiers: [])
        await model.deleteTag(c)
        let all = await shown(model)
        check(model.query.scope == .all && all.count == 3, "deleting the selected tag falls back to All")
    }

    // MARK: Task 6: assigning tags, notes

    private static func directTags(_ model: AppModel, _ ids: [Int64]) async -> [Int64: Set<Int64>] {
        await model.faceTagMap(ids) ?? [:]
    }

    private static func assignmentSteps(_ model: AppModel, faces: [String: Int64]) async {
        guard let serif = faces["Smoke Serif"], let sans = faces["Smoke Sans"], let mono = faces["Smoke Mono"] else { return }
        guard let t = await model.createTag(name: "Display", parentID: nil),
              let sub = await model.createTag(name: "Headline", parentID: t) else {
            check(false, "create Display and Display/Headline", model.alert?.message ?? "")
            return
        }
        check(model.tagPath(sub) == "Display/Headline", "tag path of a nested tag", model.tagPath(sub))
        check(model.plainTagTree().contains { $0.tag.id == sub && $0.depth == 1 }
              && !model.plainTagTree().contains { $0.tag.kind == .smart }, "plain tag tree: subtags indented, no smart tags")

        // Mixed state: setTag on one face of a 2-face selection, read back with tagIDs(forFaces:).
        await model.setTag(t, onFaces: [serif], included: true)
        let map = await directTags(model, [serif, sans])
        let states = AppModel.tagStates(map, faces: [serif, sans])
        check(states[t] == .mixed, "1 of 2 selected faces tagged: mixed", "\(states)")
        check(AppModel.tagStates(map, faces: [serif])[t] == .on && AppModel.tagStates(map, faces: [sans])[t] == nil,
              "on for the tagged face alone, off for the other")

        // Toggling mixed adds to all; toggling on removes from all.
        await model.toggleTag(t, onFaces: [serif, sans], from: .mixed)
        var after = AppModel.tagStates(await directTags(model, [serif, sans]), faces: [serif, sans])
        check(after[t] == .on, "toggling a mixed tag adds it to the whole selection", "\(after)")
        await model.toggleTag(t, onFaces: [serif, sans], from: .on)
        after = AppModel.tagStates(await directTags(model, [serif, sans]), faces: [serif, sans])
        check(after[t] == nil, "toggling an 'on' tag removes it from the whole selection", "\(after)")

        // Drops: plain drop adds, ⌥-drop removes; Style, smart and Library rows refuse.
        var ok = await model.dropFaces([serif, mono], on: .tag(t), removing: false)
        var direct = await directTags(model, [serif, sans, mono])
        check(ok && direct[serif]?.contains(t) == true && direct[mono]?.contains(t) == true && direct[sans] == nil,
              "drop fonts on a tag tags them", "\(direct)")
        ok = await model.dropFaces([mono], on: .tag(t), removing: true)
        direct = await directTags(model, [serif, mono])
        check(ok && direct[serif]?.contains(t) == true && direct[mono]?.contains(t) != true, "⌥-drop removes the tag", "\(direct)")
        let before = model.organizationCounts
        let smart = model.tags.first { $0.kind == .smart }
        check(smart != nil, "a smart tag exists for the refusal check")
        let refusedStyle = await model.dropFaces([sans], on: .scope(.styleClass(.serif)), removing: false)
        let refusedSmart = await model.dropFaces([sans], on: .tag(smart?.id ?? -1), removing: false)
        let refusedLibrary = await model.dropFaces([sans], on: .scope(.all), removing: false)
        check(!refusedStyle && !model.acceptsFaceDrop(on: .scope(.styleClass(.serif))), "drop on a Style row is refused")
        check(!refusedSmart && smart.map { !model.acceptsFaceDrop(on: .tag($0.id)) } == true, "drop on a smart tag is refused")
        check(!refusedLibrary && !model.acceptsFaceDrop(on: .scope(.all)), "drop on a Library row is ignored")
        let sansTags = await directTags(model, [sans])
        check(model.organizationCounts == before && sansTags[sans] == nil,
              "refused drops change nothing")

        // Drag payload round trip.
        check(FaceDrag.decode(Data(FaceDrag.encode([serif, mono]).utf8)) == [serif, mono], "drag payload round trip")
        await dragSteps(model, faces: faces)

        // Context menu: Tags ▸ with checkbox states once loaded, toggling through the item, New Tag….
        _ = NSApplication.shared
        let menu = FontContextMenu.make(for: [serif, mono], model: model)
        let tagsMenu = menu.items.first { $0.title == "Tags" }?.submenu
        check(tagsMenu?.items.last?.title == "New Tag…", "context menu has Tags ▸ … New Tag…")
        let displayItem = tagsMenu?.items.first { $0.title == "Display" }
        let headlineItem = tagsMenu?.items.first { $0.title == "Headline" }
        for _ in 0..<50 where displayItem?.isEnabled != true { try? await Task.sleep(for: .milliseconds(20)) }
        check(displayItem?.state == .mixed && displayItem?.isEnabled == true, "menu: Display mixed for serif+mono",
              "\(String(describing: displayItem?.state))")
        check(headlineItem?.indentationLevel == 1 && headlineItem?.state == .off, "menu: Headline indented, off")
        if let tagsMenu, let displayItem, let index = tagsMenu.items.firstIndex(of: displayItem) {
            tagsMenu.performActionForItem(at: index)
            var tagged = false
            for _ in 0..<100 {
                let m = await directTags(model, [serif, mono])
                if m[serif]?.contains(t) == true && m[mono]?.contains(t) == true { tagged = true; break }
                try? await Task.sleep(for: .milliseconds(20))
            }
            check(tagged, "menu: choosing a mixed tag adds it to the whole selection")
        }

        // "New Tag…" (after its name prompt): creates the tag at the top level and tags the selection.
        let created = await model.createTagAndAssign(name: "Việt Nam", faces: [serif, mono])
        direct = await directTags(model, [serif, sans, mono])
        check(created != nil && model.tag(created ?? -1)?.parentID == nil
              && direct[serif]?.contains(created ?? -1) == true && direct[mono]?.contains(created ?? -1) == true
              && direct[sans] == nil, "New Tag… creates a top-level tag and tags the selection", "\(direct)")
        let again = await model.createTagAndAssign(name: "VIỆT NAM", faces: [sans])
        check(again == created && model.alert == nil, "New Tag… with an existing name (case only) reuses it")
        let different = await model.createTagAndAssign(name: "viet nam", faces: [sans])
        check(different != nil && different != created && model.alert == nil,
              "New Tag… without the diacritics is a different tag")
        model.alert = nil
        // "Mới" next to "Môi": the same letters, different words.
        let moi = await model.createTagAndAssign(name: "Môi", faces: [serif])
        check(model.plainTagExists(named: "môi") && !model.plainTagExists(named: "Mới"),
              "⌘T offers Create for “Mới” while “Môi” exists")
        let moi2 = await model.createTagAndAssign(name: "Mới", faces: [mono])
        let moiTags = await directTags(model, [serif, mono])
        check(moi != nil && moi2 != nil && moi != moi2 && model.tag(moi2 ?? -1)?.name == "Mới"
              && moiTags[mono]?.contains(moi ?? -1) == false && moiTags[serif]?.contains(moi2 ?? -1) == false,
              "“Mới” is created next to “Môi”, each on its own font", "\(moiTags)")
        check(model.plainTagExists(named: "Display/Headline") && model.plainTagExists(named: "display")
              && !model.plainTagExists(named: "Headline"), "⌘T exists check: top-level names and full paths")
        model.alert = nil

        // ⌘T panel matching: subsequence, case- and diacritic-insensitive.
        check(TagSearch.score("vn", in: "Việt Nam") != nil && TagSearch.score("VIET", in: "Việt Nam") == 0,
              "fuzzy: diacritic- and case-insensitive")
        check(TagSearch.score("dep", in: "Đẹp") == 0, "fuzzy: đ matches d")
        check(TagSearch.score("dh", in: "Display/Headline") != nil && TagSearch.score("head", in: "Display/Headline") == 1
              && TagSearch.score("xyz", in: "Display/Headline") == nil, "fuzzy: subsequence and last-name prefix")
        model.selection = [sans, serif]
        check(Set(model.tagPanelTargets) == [sans, serif], "⌘T targets the selection")
        model.selection = []
        check(model.tagPanelTargets.isEmpty, "⌘T has nothing to act on without a selection")
        model.showTagPanel()
        check(model.tagPanel == nil, "⌘T does nothing without a selection")
        model.showTagPanel(for: [mono])
        check(model.tagPanel?.faceIDs == [mono], "Edit Tags… opens the panel for one face")
        model.tagPanel = nil
    }

    private static func noteSteps(_ model: AppModel, faces: [String: Int64]) async {
        guard let serif = faces["Smoke Serif"], let sans = faces["Smoke Sans"] else { return }
        // Typing: five keystrokes 50 ms apart, then the 0.5 s debounce: one write with the last text.
        let writes = model.noteWriteCount
        var typed = ""
        for ch in "zebra" {
            typed.append(ch)
            model.editNote(typed, faceID: serif)
            try? await Task.sleep(for: .milliseconds(50))
        }
        check(model.noteWriteCount == writes, "no note write while typing")
        try? await Task.sleep(for: .milliseconds(800))
        await model.flushNotes()  // waits for the write in flight; nothing pending
        let info = await model.faceInfo(serif)
        check(model.noteWriteCount == writes + 1 && info?.note == "zebra", "note debounce writes once, with the last text",
              "writes \(model.noteWriteCount - writes), note \(String(describing: info?.note))")
        check(model.note(for: serif, stored: nil) == "zebra", "the editor gets the saved note back")

        // A style change mid-typing keeps each face's keystrokes.
        model.editNote("first face", faceID: sans)
        model.editNote("zebra stripes", faceID: serif)
        await model.flushNotes()
        let sansNote = await model.faceInfo(sans)?.note
        let serifNote = await model.faceInfo(serif)?.note
        check(sansNote == "first face" && serifNote == "zebra stripes", "flush on style change keeps both faces' notes",
              "\(String(describing: sansNote)) / \(String(describing: serifNote))")

        // Notes are found by search.
        model.query.scope = .all
        model.searchScope = [.notes]
        model.searchText = "stripes"
        let found = await shown(model)
        check(found == [serif], "a note set through the model is found by search", "\(found)")
        model.searchText = ""
        model.searchScope = Set(SearchText.Field.allCases)
    }

    // MARK: Task 7: Quick Collection, style backfill

    private static func storedQuickCollection(_ model: AppModel) async -> Set<Int64>? {
        guard let backend = model.backend else { return nil }
        return await model.runBackground { try backend.store.quickCollectionFaceIDs() }
    }

    private static func quickCollectionSteps(_ model: AppModel, faces: [String: Int64]) async {
        guard let serif = faces["Smoke Serif"], let sans = faces["Smoke Sans"], let mono = faces["Smoke Mono"] else { return }
        model.query.scope = .all
        check(model.quickCollectionIDs.isEmpty, "Quick Collection starts empty")

        // ⌘J on a mixed selection (Serif in, Sans out): adds all; again: removes all.
        await model.setQuickCollection([serif], included: true)
        model.selection = [serif, sans]
        check(model.quickCollectionMenuTitle == "Add to Quick Collection", "mixed selection: the menu says Add")
        await model.toggleQuickCollection()
        var stored = await storedQuickCollection(model)
        check(model.quickCollectionIDs == [serif, sans] && stored == [serif, sans] && model.organizationCounts.quickCollection == 2,
              "⌘J on a mixed selection adds every selected face", "\(model.quickCollectionIDs) / \(String(describing: stored))")
        check(model.quickCollectionMenuTitle == "Remove from Quick Collection", "all in: the menu says Remove")
        await model.toggleQuickCollection()
        stored = await storedQuickCollection(model)
        check(model.quickCollectionIDs.isEmpty && stored == [] && model.organizationCounts.quickCollection == 0,
              "⌘J again removes them all: toggling twice leaves the collection empty", "\(String(describing: stored))")

        // Two quick presses (the second before the first write lands) still alternate.
        model.selection = [mono]
        let first = Task { await model.toggleQuickCollection() }
        let second = Task { await model.toggleQuickCollection() }
        await first.value
        await second.value
        stored = await storedQuickCollection(model)
        check(model.quickCollectionIDs.isEmpty && stored == [], "two quick ⌘J presses add then remove", "\(String(describing: stored))")
        model.selection = []

        // Context menu item follows the faces.
        _ = NSApplication.shared
        let menu = FontContextMenu.make(for: [mono], model: model)
        let addItem = menu.items.first { $0.title.hasSuffix("Quick Collection") }
        check(addItem?.title == "Add to Quick Collection" && addItem?.keyEquivalent == "j", "context menu: Add to Quick Collection ⌘J")
        if let addItem, let index = menu.items.firstIndex(of: addItem) {
            menu.performActionForItem(at: index)
            for _ in 0..<100 where !model.quickCollectionIDs.contains(mono) { try? await Task.sleep(for: .milliseconds(10)) }
            await model.waitForQuickCollectionWritesForSmoke()
        }
        check(model.quickCollectionIDs == [mono], "context menu item adds the face")
        let removeTitle = FontContextMenu.make(for: [mono], model: model).items.first { $0.title.hasSuffix("Quick Collection") }?.title
        check(removeTitle == "Remove from Quick Collection", "context menu: Remove when the face is in it")

        // The Library row shows the collection.
        await model.setQuickCollection([serif], included: true)
        model.query.scope = .quickCollection
        let inCollection = await shown(model)
        check(inCollection == [serif, mono], "Quick Collection row shows its faces", "\(inCollection)")

        // Save as Tag…: a top-level tag with the same faces; a taken name alerts and creates nothing.
        let tagID = await model.saveQuickCollectionAsTag(name: "Picks")
        let direct = await model.faceTagMap([serif, sans, mono]) ?? [:]
        check(tagID != nil && model.tag(tagID ?? -1)?.parentID == nil
              && direct[serif]?.contains(tagID ?? -1) == true && direct[mono]?.contains(tagID ?? -1) == true
              && direct[sans]?.contains(tagID ?? -1) != true && model.organizationCounts.perTag[tagID ?? -1] == 2,
              "Save as Tag creates a top-level tag with the same faces", "\(direct)")
        // Again while organization reloads keep firing (as during a backfill): every face is still tagged.
        let reloads = Task { @MainActor in
            while !Task.isCancelled {
                Task { await model.reloadOrganization() }
                try? await Task.sleep(for: .milliseconds(1))
            }
        }
        var busyOK = true
        for i in 0..<10 {
            let busyID = await model.saveQuickCollectionAsTag(name: "Busy \(i)")
            let busyTags = await model.faceTagMap([serif, mono]) ?? [:]
            if busyID == nil || busyTags[serif]?.contains(busyID ?? -1) != true || busyTags[mono]?.contains(busyID ?? -1) != true {
                busyOK = false
            }
        }
        reloads.cancel()
        await model.reloadOrganization()
        check(busyOK, "Save as Tag while organization reloads are firing still tags every face")
        let created = await model.createTagAndAssign(name: "Busy New", faces: [serif])
        let createdTags = await model.faceTagMap([serif]) ?? [:]
        check(created != nil && createdTags[serif]?.contains(created ?? -1) == true, "New Tag… tags the face")
        let tagCount = model.tags.count
        let dup = await model.saveQuickCollectionAsTag(name: "picks")
        check(dup == nil && model.alert != nil && model.tags.count == tagCount, "Save as Tag with a taken name shows the alert")
        model.alert = nil

        // Clear…: confirmed when not empty, then empties the collection.
        model.confirmClearQuickCollection()
        check(model.alert?.actionTitle == "Clear" && model.alert?.isDestructive == true, "Clear… asks first when not empty")
        model.alert?.action?()
        model.alert = nil
        for _ in 0..<100 where !model.quickCollectionIDs.isEmpty { try? await Task.sleep(for: .milliseconds(10)) }
        await model.waitForQuickCollectionWritesForSmoke()
        stored = await storedQuickCollection(model)
        let afterClear = await shown(model)
        check(model.quickCollectionIDs.isEmpty && stored == [] && model.organizationCounts.quickCollection == 0 && afterClear.isEmpty,
              "Clear empties the collection", "\(String(describing: stored))")
        model.confirmClearQuickCollection()
        check(model.alert == nil, "Clear… on an empty collection asks nothing")
        model.query.scope = .all
    }

    /// A real font file plus the synthetic faces, all marked as classified by an old version, then the backfill.
    private static func backfillSteps(_ model: AppModel, backend: LibraryBackend, folder: URL) async {
        let store = backend.store
        let before: Int
        do {
            // The seeded faces' files: present but not fonts (classified unknown; missing files would be skipped).
            for name in ["Serif", "Sans", "Mono"] {
                try Data(repeating: 0x5A, count: 256).write(to: folder.appendingPathComponent("Smoke\(name).otf"))
            }
            let url = folder.appendingPathComponent("ArialBold.ttf")
            try FileManager.default.copyItem(at: URL(fileURLWithPath: "/System/Library/Fonts/Supplemental/Arial Bold.ttf"), to: url)
            guard let loc = try store.locations().first(where: { $0.volumeUUID == "SMOKE-VOLUME" }) else {
                check(false, "backfill: smoke location"); return
            }
            _ = try store.insertFile(FileRecord(locationID: loc.id, relativePath: "ArialBold.ttf", size: 10, mtime: Date(timeIntervalSince1970: 1000),
                                                format: "ttf", fingerprint: "smoke-arial"),
                                     faces: try FontParser.parse(url: url), importBatch: try store.nextImportBatch())
            let ids = try store.faceIDs(for: LibraryQuery())
            try store.setStyleClasses(ids.map { ($0, StyleClass.unknown) }, version: StyleClassifier.version - 1)
            before = try store.countFacesNeedingClassification()
            check(before == ids.count && before == 4, "backfill: 4 faces marked with an old class version", "\(before)")
        } catch {
            check(false, "backfill setup", "\(error)")
            return
        }

        // During an unmount nothing starts (the handler starts it once the volume is offline).
        model.unmountsInProgress = 1
        let idleRuns = model.styleBackfillRuns
        model.startStyleBackfill()
        check(model.styleBackfillRuns == idleRuns && model.styleBackfillTask == nil, "backfill: no start while an unmount is handled")
        model.unmountsInProgress = 0

        // Coalescing: starting while a run goes only asks for one more run, never a second at once.
        let runs = model.styleBackfillRuns
        model.startStyleBackfill()
        model.startStyleBackfill()
        model.startStyleBackfill()
        check(model.styleBackfillRuns == runs + 1, "backfill: starting again while it runs does not start a second run")
        await model.waitForStyleBackfillForSmoke()
        check(model.styleBackfillRuns == runs + 2 && model.styleBackfillMaxRunning == 1,
              "backfill: the pending start ran once more afterwards, never two at once",
              "runs \(model.styleBackfillRuns - runs), max at once \(model.styleBackfillMaxRunning)")
        let remaining = await model.runBackground { try store.countFacesNeedingClassification() }
        check(remaining == 0, "backfill: every face has the current class_version", "\(String(describing: remaining))")
        check(model.styleBackfillProgress == nil, "backfill: progress hidden when done")
        await model.reloadOrganization()
        check(model.organizationCounts.perStyle[.sans] == 1 && model.organizationCounts.perStyle[.unknown] == 3,
              "backfill: Arial Bold reclassified as Sans, the unparsable files unknown", "\(model.organizationCounts.perStyle)")

        // Nothing to do: no progress shown.
        model.startStyleBackfill()
        check(model.styleBackfillProgress == nil, "backfill: no progress row when there is nothing to classify")
        await model.waitForStyleBackfillForSmoke()
        check(model.styleBackfillProgress == nil && model.styleBackfillMaxRunning == 1, "backfill: an empty run ends quietly")

        // Quitting stops it and refuses new runs.
        await model.stopStyleBackfill()
        let stoppedRuns = model.styleBackfillRuns
        model.startStyleBackfill()
        check(model.styleBackfillRuns == stoppedRuns && model.styleBackfillTask == nil, "backfill: no run after quit")
    }

    /// The grid's drag source on the 3 seeded faces (payload on one item, one URL per file), then a 20,000-face
    /// drag on a second temporary library: the id list is encoded once, read from one item and decoded once.
    private static func dragSteps(_ model: AppModel, faces: [String: Int64]) async {
        let ids = faces.values.sorted()
        let grid = FontGridController(model: model, mode: .grid)
        _ = grid.makeScrollView()
        grid.update(faceIDs: ids)
        let plan = grid.makeDragPlan(ids)
        let items = ids.compactMap { plan.pasteboardItem(for: $0) }
        let payloadItems = items.filter { $0.types.contains(FaceDrag.pasteboardType) }
        let urls = items.compactMap { $0.string(forType: .fileURL) }
        check(payloadItems.count == 1 && payloadItems.first?.string(forType: FaceDrag.pasteboardType) == FaceDrag.encode(ids)
              && urls.count == 3 && Set(urls).count == 3, "drag: ids on one item, a file URL per face",
              "payload items \(payloadItems.count), urls \(urls.count)")

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("FontoryDragSmoke-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let backend = try LibraryBackend(databaseURL: dir.appendingPathComponent("library.sqlite"))
            let store = backend.store
            let loc = try store.upsertLocation(kind: .folder, volumeUUID: "SMOKE-DRAG", relativePath: "Fonts",
                                               displayName: "Drag", lastKnownPath: dir.path)
            let batch = try store.nextImportBatch()
            // 200 collection files of 100 faces: 20,000 faces, 200 distinct files.
            for f in 0..<200 {
                let parsed = (0..<100).map { i in
                    ParsedFace(faceIndex: i, postScriptName: "Drag\(f)-\(i)", family: "Drag \(f)", style: "S\(i)",
                               fullName: "Drag \(f) S\(i)", glyphCount: 10, styleClass: .sans)
                }
                let file = FileRecord(locationID: loc.id, relativePath: "Drag\(f).ttc", size: 10,
                                      mtime: Date(timeIntervalSince1970: 1000), format: "ttc", fingerprint: "drag-\(f)")
                _ = try store.insertFile(file, faces: parsed, importBatch: batch)
            }
            let all = try store.faceIDs(for: LibraryQuery())
            check(all.count == 20_000, "drag library has 20,000 faces", "\(all.count)")

            let big = AppModel()
            await big.attachBackendForSmoke(backend)
            let bigGrid = FontGridController(model: big, mode: .grid)
            _ = bigGrid.makeScrollView()
            bigGrid.update(faceIDs: all)

            // Worst case: nothing cached or prefetched. The plan reads nothing; the URLs are read once, in one
            // batch, when a drop asks for the first one.
            let encodes = FaceDrag.encodeCount
            let clock = ContinuousClock()
            let start = clock.now
            let bigPlan = bigGrid.makeDragPlan(all)
            let planTime = clock.now - start
            let itemStart = clock.now
            let bigItems = all.compactMap { bigPlan.pasteboardItem(for: $0) }
            let itemTime = clock.now - itemStart
            print("  20k drag, nothing known: plan \(planTime.formatted(.units(allowed: [.milliseconds]))), "
                  + "items \(itemTime.formatted(.units(allowed: [.milliseconds])))")
            let carrying = bigItems.filter { $0.types.contains(FaceDrag.pasteboardType) }
            check(FaceDrag.encodeCount == encodes + 1 && carrying.count == 1, "20k drag: id list encoded once, on one item")
            check(planTime + itemTime < .milliseconds(100), "20k drag start reads no files from the store",
                  "\((planTime + itemTime).formatted(.units(allowed: [.milliseconds])))")
            var lazyURLs: [String] = []
            if let lazy = bigPlan.lazy {
                let dropStart = clock.now
                lazyURLs = all.compactMap { lazy.url(for: $0)?.absoluteString }
                print("  20k drop asking for files: \((clock.now - dropStart).formatted(.units(allowed: [.milliseconds]))) (one batched read)")
                check(lazy.reads == 1, "20k drag: lazy URLs read in one batch", "\(lazy.reads) reads")
            }
            check(lazyURLs.count == 200 && Set(lazyURLs).count == 200, "20k drag: one URL per collection file (200)",
                  "\(lazyURLs.count)")
            let bigURLs = lazyURLs

            // The selection prefetch resolves URLs off the main actor; a drag after it reads nothing.
            big.selection = Set(all)
            bigGrid.update(selection: big.selection)
            for _ in 0..<200 {
                try? await Task.sleep(for: .milliseconds(25))
                let probe = clock.now
                _ = bigGrid.makeDragPlan([all[all.count - 1]])
                if clock.now - probe < .milliseconds(2) { break }
            }
            let prefetched = clock.now
            let fastPlan = bigGrid.makeDragPlan(all)
            let fastTime = clock.now - prefetched
            print("  20k drag after the selection prefetch: plan \(fastTime.formatted(.units(allowed: [.milliseconds])))")
            check(fastPlan.itemURLs.count == 200 && fastPlan.lazy == nil && fastTime < .milliseconds(100),
                  "20k drag after prefetch: all URLs known, no store read",
                  "\(fastPlan.itemURLs.count) urls, \(fastTime)")

            // Drop side: the list is decoded once, from the one provider carrying it.
            let providers: [NSItemProvider] = carrying.map { item in
                let provider = NSItemProvider()
                let data = Data(item.string(forType: FaceDrag.pasteboardType)!.utf8)
                provider.registerDataRepresentation(for: .fontoryFaceIDs, visibility: .ownProcess) { done in
                    done(data, nil); return nil
                }
                return provider
            } + bigURLs.prefix(5).map { NSItemProvider(contentsOf: URL(string: $0)!) ?? NSItemProvider() }
            let decodes = FaceDrag.decodeCount
            let received: [Int64] = await withCheckedContinuation { continuation in
                let accepted = FaceDrag.load(providers) { continuation.resume(returning: $0) }
                if !accepted { continuation.resume(returning: []) }
            }
            check(received == all && FaceDrag.decodeCount == decodes + 1, "20k drop: ids decoded once",
                  "\(received.count) ids, \(FaceDrag.decodeCount - decodes) decodes")
        } catch {
            check(false, "20k drag setup", "\(error)")
        }
    }

    // MARK: Task 8: smart tag editor

    /// Waits out the editor's debounced count.
    private static func editorCount(_ model: AppModel, _ editor: SmartTagEditorState) async -> Int? {
        model.scheduleSmartTagCount(editor)
        await editor.countTask?.value
        return editor.matchCount
    }

    private static func smartEditorSteps(_ model: AppModel, backend: LibraryBackend) async {
        let store = backend.store
        // Extra faces: two variable script faces, a static script face, a variable sans; weights 300/700/900.
        do {
            let loc = try store.upsertLocation(kind: .folder, volumeUUID: "SMOKE-SMART", relativePath: "Smart",
                                               displayName: "Smart", lastKnownPath: "/nonexistent/smart")
            let batch = try store.nextImportBatch()
            let defs: [(String, StyleClass, Bool, Double)] = [
                ("Brush VF", .script, true, 300), ("Hand VF", .script, true, 700),
                ("Hand Static", .script, false, 700), ("Grotesk VF", .sans, true, 900),
            ]
            for (i, (name, style, variable, weight)) in defs.enumerated() {
                let face = ParsedFace(postScriptName: "Smart\(i)", family: "Smart \(name)", style: "Regular",
                                      fullName: "Smart \(name)", weight: weight, isVariable: variable, glyphCount: 10,
                                      styleClass: style)
                let file = FileRecord(locationID: loc.id, relativePath: "Smart\(i).ttf", size: 10,
                                      mtime: Date(timeIntervalSince1970: 1000), format: "ttf", fingerprint: "smart-\(i)")
                _ = try store.insertFile(file, faces: [face], importBatch: batch)
            }
        } catch {
            check(false, "smart editor seed", "\(error)")
            return
        }
        await model.reloadOrganization()

        // "Style is Script AND Variable is yes", built as the sheet builds it.
        model.newSmartTag()
        guard let editor = model.smartTagEditor else { check(false, "editor opens"); return }
        editor.name = "Script VF"
        editor.match = .all
        editor.rows = []
        editor.addRow()
        editor.rows[0].condition = SmartRule.Condition(field: .styleClass, op: .is, value: .int(Int64(StyleClass.script.rawValue)))
        editor.addRow()
        editor.rows[1].condition = SmartRule.Condition(field: .variable, op: .yes)
        for row in editor.rows {
            let c = row.condition
            check(SmartRuleSchema.ops(for: c.field).contains(c.op), "editor offers \(c.field.rawValue) \(c.op.rawValue)")
        }
        let live = await editorCount(model, editor)
        let core = (try? store.faceIDs(for: LibraryQuery(scope: .tags([TagPick(tagID: -1, rule: editor.rule)])))).map(\.count)
        check(live == 2 && live == core, "live count: Script AND Variable matches 2", "live \(String(describing: live)), core \(String(describing: core))")
        await model.saveSmartTag(editor)
        guard let scriptVF = model.tags.first(where: { $0.name == "Script VF" }) else {
            check(false, "Script VF saved", model.alert?.message ?? "")
            return
        }
        let shownIDs = await shown(model)
        check(model.selectedTagPicks.map(\.tagID) == [scriptVF.id] && shownIDs.count == 2 && model.smartTagCounts[scriptVF.id] == 2,
              "saved smart tag: scope count equals the core count (2)", "shown \(shownIDs.count), row \(String(describing: model.smartTagCounts[scriptVF.id]))")

        // Edit…: drop the Variable row; the count follows.
        model.editSmartTag(scriptVF.id)
        guard let edit = model.smartTagEditor, edit.tagID == scriptVF.id else { check(false, "Edit… opens the editor"); return }
        check(edit.name == "Script VF" && edit.rows.count == 2, "Edit… loads name and rule")
        edit.removeRow(edit.rows[1].id)
        let editedLive = await editorCount(model, edit)
        check(editedLive == 3, "live count after removing a row: 3", "\(String(describing: editedLive))")
        await model.saveSmartTag(edit)
        let reshown = await shown(model)
        check(model.smartTagEditor == nil && model.smartTagCounts[scriptVF.id] == 3 && reshown.count == 3,
              "editing an existing smart tag updates its count", "\(String(describing: model.smartTagCounts[scriptVF.id])), shown \(reshown.count)")

        // Invert: the checkbox is off with no rows (the built rule ignores it); with a row it inverts.
        model.editSmartTag(scriptVF.id)
        if let inv = model.smartTagEditor {
            inv.inverted = true
            let invCount = await editorCount(model, inv)
            let total = (try? store.faceIDs(for: LibraryQuery()))?.count ?? -1
            check(invCount == total - 3, "inverted rule matches the other fonts", "\(String(describing: invCount)) of \(total)")
            inv.rows = []
            check(inv.rule.inverted == false, "no rows: Invert is not applied")
            model.cancelSmartTagEditor()
        }
        let afterCancel = model.tag(scriptVF.id).flatMap { SmartRule.decode($0.ruleJSON ?? "") }
        check(model.smartTagEditor == nil && afterCancel?.conditions.count == 1 && afterCancel?.inverted == false,
              "Cancel discards the draft")

        // Save with a duplicate name: alert, sheet and draft kept.
        model.newSmartTag()
        if let dup = model.smartTagEditor {
            dup.name = "script vf"
            dup.rows[0].condition = SmartRule.Condition(field: .italic, op: .no)
            let tagsBefore = model.tags.count
            let saved = await model.saveSmartTag(dup)
            check(!saved && model.alert?.message == TagError.duplicateName.message && model.smartTagEditor === dup
                  && dup.name == "script vf" && dup.rows.count == 1 && dup.rows[0].condition.field == .italic
                  && model.tags.count == tagsBefore,
                  "duplicate name: alert shown, sheet and draft kept", model.alert?.message ?? "no alert")
            model.alert = nil
            dup.name = "   "
            let savedEmpty = await model.saveSmartTag(dup)
            check(!savedEmpty && model.alert?.message == TagError.emptyName.message && model.smartTagEditor === dup,
                  "empty name: alert shown, sheet kept")
            model.alert = nil
            model.cancelSmartTagEditor()
        }

        // Weight/width stops map to stored units and round-trip through the saved JSON.
        let weights = SmartRuleSchema.weightStops.map(\.value)
        let widths = SmartRuleSchema.widthStops.map(\.value)
        check(weights == [100, 200, 300, 400, 500, 600, 700, 800, 900] && widths == Array(1...9).map(Double.init),
              "stops are OS/2 units (weight 100–900, width 1–9)")
        var roundTrips = true
        for (stops, field) in [(SmartRuleSchema.weightStops, SmartRule.Field.weight), (SmartRuleSchema.widthStops, .width)] {
            for lo in stops.indices { for hi in lo..<stops.count {
                var rule = SmartRule()
                rule.conditions = [SmartRule.Condition(field: field, op: .between, value: .range(stops[lo].value, stops[hi].value))]
                guard let back = SmartRule.decode(rule.encoded()),
                      case .range(let a, let b) = SmartTagEditorState(tagID: nil, name: "x", rule: back).rule.conditions.first?.value,
                      SmartRuleSchema.stopIndex(for: a, in: stops) == lo, SmartRuleSchema.stopIndex(for: b, in: stops) == hi
                else { roundTrips = false; continue }
            } }
        }
        check(roundTrips, "every weight/width stop pair round-trips")
        check(SmartRuleSchema.stopIndex(for: 437, in: SmartRuleSchema.weightStops) == 3, "an in-between weight snaps to the nearest stop")

        // "Weight between Bold and Black": 3 faces (700, 700, 900); the seeded faces are 400.
        model.newSmartTag()
        if let w = model.smartTagEditor {
            w.rows[0].condition = SmartRule.Condition(field: .weight, op: .between, value: .range(700, 900))
            let n = await editorCount(model, w)
            check(n == 3, "Weight between Bold and Black matches 3", "\(String(describing: n))")
            model.cancelSmartTagEditor()
        }

        // Every field's default value with its first operator compiles to a real condition (not match-nothing).
        var allValid = true
        for field in SmartRuleSchema.fieldOrder {
            for op in SmartRuleSchema.ops(for: field) {
                let value = SmartRuleSchema.defaultValue(for: field, tags: model.plainTagTree().map(\.tag),
                                                         locations: model.locations.filter { !$0.autoIndexed })
                var rule = SmartRule()
                rule.conditions = [SmartRule.Condition(field: field, op: op, value: value)]
                if rule.sqlClause().sql == "(0)" { allValid = false; print("  invalid: \(field) \(op)") }
            }
        }
        check(allValid, "every offered field/operator pair compiles to a real condition")
    }
}
#endif
