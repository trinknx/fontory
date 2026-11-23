#if DEBUG
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

        model.selectTag(a, modifiers: .option)
        let inverted = await shown(model)
        check(!inverted.contains(serif) && inverted == [sans, mono], "⌥-select A hides it", "\(inverted)")
        check(model.selectedTagPicks.first?.inverted == true && model.sidebarSelection == [.tag(a)], "⌥-select A is an inverted pick")

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
        await model.moveTag(a, toParent: b)
        check(model.alert != nil && model.tag(a)?.parentID == nil, "moving A into its subtag is refused")
        model.alert = nil

        // Nest and un-nest (the drag-and-drop actions).
        await model.moveTag(c, toParent: a)
        check(model.tag(c)?.parentID == a && model.organizationCounts.perTag[a] == 2, "drop c on A nests it")
        await model.moveTag(c, toParent: nil)
        check(model.tag(c)?.parentID == nil && model.organizationCounts.perTag[a] == 1, "drop c on the header un-nests it")

        await model.renameTag(c, to: "C2")
        check(model.tag(c)?.name == "C2", "rename")

        // Style group.
        check(model.organizationCounts.perStyle[.serif] == 1 && model.organizationCounts.perStyle[.mono] == 1,
              "style counts", "\(model.organizationCounts.perStyle)")
        model.applySidebarSelection([.scope(.styleClass(.sans))], modifiers: [])
        let sansShown = await shown(model)
        check(sansShown == [sans], "Style ▸ Sans shows the sans face")

        // Smart tag: empty rule matches everything until the editor (Task 8) sets one.
        await model.newSmartTag()
        let smart = model.tags.first { $0.kind == .smart }
        check(smart != nil && model.renamingTagID == smart?.id && model.editingSmartTagID == smart?.id,
              "New Smart Tag creates it, starts rename and asks for the editor")
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
}
#endif
