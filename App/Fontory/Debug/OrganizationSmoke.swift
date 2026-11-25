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
            await reviewFixSteps(model, backend: backend)
            await filterSteps(model, backend: backend, folder: dir)
            await exportSteps(model, backend: backend, faces: faces, folder: dir)
            await familyEditorSteps()
            await duplicateSteps()
            await backupSteps()
            await layoutsSteps()
            await compareSteps()
            glyphCopySteps()
            await rulesSteps()
            await googleSteps()
        } catch {
            check(false, "setup", "\(error)")
        }
        return failures == 0
    }

    /// Copy Glyph (PNG + SVG, no text) and Copy SVG Code (text only), on private pasteboards, never `.general`.
    private static func glyphCopySteps() {
        let base = NSFont.systemFont(ofSize: 100)
        let desc = base.fontDescriptor.withDesign(.serif) ?? base.fontDescriptor
        let font = NSFont(descriptor: desc, size: 100) ?? base
        var glyph: CGGlyph = 0
        var ch: UniChar = 0x67
        CTFontGetGlyphsForCharacters(font, &ch, &glyph, 1)
        let pb = NSPasteboard(name: .init("fontory.smoke.\(UUID())"))
        defer { pb.releaseGlobally() }
        let wrote = GlyphExport.copyGlyph(font: font, glyph: glyph, to: pb)
        let types = pb.types ?? []
        check(wrote && glyph != 0 && types.contains(.png) && types.contains(GlyphExport.svgType) && !types.contains(.string),
              "glyphCopy: copyGlyphWritesPNGAndSVGOnly", "\(types.map(\.rawValue))")
        let svg = GlyphSVG.document(font: font, glyph: glyph) ?? ""
        let pb2 = NSPasteboard(name: .init("fontory.smoke.\(UUID())"))
        defer { pb2.releaseGlobally() }
        let ok = GlyphExport.copySVGCode(svg, to: pb2)
        check(ok && !(pb2.types ?? []).contains(.png) && !(pb2.types ?? []).contains(GlyphExport.svgType) && (pb2.string(forType: .string) ?? "").hasPrefix("<svg"),
              "glyphCopy: copySVGCodeWritesTextOnly", "\((pb2.types ?? []).map(\.rawValue))")
        let pb3 = NSPasteboard(name: .init("fontory.smoke.\(UUID())"))
        defer { pb3.releaseGlobally() }
        pb3.clearContents(); pb3.setString("keep", forType: .string)
        check(!GlyphExport.write(png: nil, svg: nil, to: pb3) && pb3.string(forType: .string) == "keep",
              "glyphCopy: nothing written without PNG or SVG")
    }

    /// FeatureRulesModel on system fonts loaded directly (not through the library): counts, expanding, checks, the
    /// stale-load race, the AAT flag and copying to a private pasteboard.
    private static func rulesSteps() async {
        let sfns = URL(fileURLWithPath: "/System/Library/Fonts/SFNS.ttf")
        let newYork = URL(fileURLWithPath: "/System/Library/Fonts/NewYork.ttf")
        let hoefler = URL(fileURLWithPath: "/System/Library/Fonts/Supplemental/Hoefler Text.ttc")
        let renderer = PreviewRenderer()
        let model = FeatureRulesModel(renderer: renderer)
        await model.load(fileURL: sfns, faceIndex: 0, selection: .all)
        check(model.phase == .ready && !model.counts.isEmpty, "rules: counts listed for SFNS",
              "\(model.phase) \(model.counts.count)")

        let tag = model.counts.keys.sorted().first ?? ""
        var rules: GSUBFeatureRules?
        let read = await eventually(within: .seconds(2)) {
            rules = model.rules(for: tag)
            return !(rules?.rules.isEmpty ?? true)
        }
        check(read, "rules: expanding reads rules", "\(tag): \(String(describing: rules?.totalCount))")

        var statuses: [GSUBRuleStatus]?
        if let rule = rules?.rules.first {
            _ = await eventually(within: .seconds(2)) {
                statuses = model.statuses(for: rule, tag: tag)
                return statuses != nil
            }
            check(statuses?.count == rule.outputs.count, "rules: statuses arrive",
                  "\(String(describing: statuses)) for \(rule.outputs.count) outputs")
        } else {
            check(false, "rules: statuses arrive", "no rule")
        }

        let general = NSPasteboard.general.changeCount
        if let rule = rules?.rules.first(where: { model.characters(for: $0) != nil }), let glyph = rule.input.first {
            let pb = NSPasteboard(name: .init("fontory.smoke.\(UUID())"))
            defer { pb.releaseGlobally() }
            let pb2 = NSPasteboard(name: .init("fontory.smoke.\(UUID())"))
            defer { pb2.releaseGlobally() }
            let glyphOK = model.copyGlyph(glyph, to: pb)
            let types = pb.types ?? []
            let charsOK = model.copyCharacters(rule, to: pb2)
            let types2 = pb2.types ?? []
            check(glyphOK && types.contains(.png) && types.contains(GlyphExport.svgType) && !types.contains(.string)
                  && charsOK && pb2.string(forType: .string) == model.characters(for: rule) && !types2.contains(.png)
                  && NSPasteboard.general.changeCount == general,
                  "rules: copy writes to the given pasteboard only",
                  "\(types.map(\.rawValue)) \(types2.map(\.rawValue))")
        } else {
            check(false, "rules: copy writes to the given pasteboard only", "no rule with characters in \(tag)")
        }

        if let glyph = rules?.rules.first?.input.first {
            let pb = NSPasteboard(name: .init("fontory.smoke.\(UUID())"))
            defer { pb.releaseGlobally() }
            let wrote = await model.copyGlyphAsync(glyph, to: pb)
            let types = pb.types ?? []
            check(wrote && types.contains(.png) && types.contains(GlyphExport.svgType) && !types.contains(.string)
                  && NSPasteboard.general.changeCount == general,
                  "rules: async copy writes PNG and SVG to the given pasteboard", "\(types.map(\.rawValue))")

            let psName = renderer.font(fileURL: sfns, faceIndex: 0, pointSize: 1)
                .map { CTFontCopyPostScriptName($0) as String } ?? "?"
            let item = model.dragItem(for: glyph) as? GlyphPromiseProvider
            let dragPB = NSPasteboard(name: .init("fontory.smoke.\(UUID())"))
            defer { dragPB.releaseGlobally() }
            let dragTypes = item?.writableTypes(for: dragPB) ?? []
            let name = (item?.userInfo as? GlyphPromiseProvider.Payload)?.fileName ?? ""
            check(item != nil && !dragTypes.contains(.string) && name.hasPrefix(psName + " ") && name.hasSuffix(".svg"),
                  "rules: drag item is an SVG promise without text", "\(name) \(dragTypes.map(\.rawValue))")
        } else {
            check(false, "rules: async copy writes PNG and SVG to the given pasteboard", "no rule")
            check(false, "rules: drag item is an SVG promise without text", "no rule")
        }
        if let sfFont = renderer.font(fileURL: sfns, faceIndex: 0, pointSize: 1) {
            var ch: UniChar = 0x20
            var space: CGGlyph = 0
            CTFontGetGlyphsForCharacters(sfFont, &ch, &space, 1)
            check(space != 0 && model.dragItem(for: space) == nil, "rules: inkless glyph has no drag item")
        }
        if let sfFont = renderer.font(fileURL: sfns, faceIndex: 0, pointSize: 1) {
            var ch: UniChar = 0x61
            var a: CGGlyph = 0
            CTFontGetGlyphsForCharacters(sfFont, &ch, &a, 1)
            let light = await model.glyphImage(a, pointSize: 40, scale: 2, dark: false)
            let dark = await model.glyphImage(a, pointSize: 40, scale: 2, dark: true)
            // The box spans ascent + descent at 40 pt (2x), so it is taller than 80 px and wider than a's ink.
            check(a != 0 && (light?.height ?? 0) > 80 && (light?.width ?? 0) > 20 && dark != nil,
                  "rules: glyph image renders SFNS a", "\(String(describing: light?.width))x\(String(describing: light?.height))")
        }

        let emojiURL = URL(fileURLWithPath: "/System/Library/Fonts/Apple Color Emoji.ttc")
        let emoji = FeatureRulesModel(renderer: renderer)
        await emoji.load(fileURL: emojiURL, faceIndex: 0, selection: .all)
        var emojiGlyphs: [CGGlyph] = [0, 0]
        if let emojiFont = renderer.font(fileURL: emojiURL, faceIndex: 0, pointSize: 1) {
            let utf16 = Array("\u{1F600}".utf16)
            CTFontGetGlyphsForCharacters(emojiFont, utf16, &emojiGlyphs, utf16.count)
        }
        let emojiItem = emoji.dragItem(for: emojiGlyphs[0]) as? GlyphPromiseProvider
        let emojiPB = NSPasteboard(name: .init("fontory.smoke.\(UUID())"))
        defer { emojiPB.releaseGlobally() }
        let emojiName = (emojiItem?.userInfo as? GlyphPromiseProvider.Payload)?.fileName ?? ""
        check(emojiGlyphs[0] != 0 && emojiName.hasSuffix(".png")
              && !(emojiItem?.writableTypes(for: emojiPB) ?? []).contains(.string),
              "rules: colour glyph drags as a PNG promise", "\(emojiGlyphs[0]) \(emojiName)")

        if emojiGlyphs[0] != 0 {
            let pb = NSPasteboard(name: .init("fontory.smoke.\(UUID())"))
            defer { pb.releaseGlobally() }
            let wrote = await emoji.copyGlyphAsync(emojiGlyphs[0], to: pb)
            let types = pb.types ?? []
            check(wrote && types.contains(.png) && !types.contains(GlyphExport.svgType) && !types.contains(.string)
                  && !emoji.hasOutline(emojiGlyphs[0]),
                  "rules: colour face copies a PNG only and has no SVG code", "\(types.map(\.rawValue))")
        }

        // Selection and statuses live in per-rule states: selecting moves the mark from one rule's state to another's.
        if let rules, rules.rules.count >= 2 {
            let r0 = rules.rules[0], r1 = rules.rules[1]
            let s0 = model.cellState(for: r0, tag: tag), s1 = model.cellState(for: r1, tag: tag)
            let g0 = RuleGlyph(tag: tag, rule: r0, output: 0, index: 0)
            let g1 = RuleGlyph(tag: tag, rule: r1, output: 0, index: 0)
            model.select(g0)
            let first = s0.selected == g0 && s1.selected == nil
            model.select(g1)
            check(first && s0.selected == nil && s1.selected == g1 && model.selectedGlyph == g1
                  && s0.statuses != nil,
                  "rules: selection and statuses live in per-rule cell states")
            model.select(nil)
        }

        // Two cells asking for the same image at once share one render.
        if let glyph = rules?.rules.last?.outputs.first?.first {
            let one = Task { await model.glyphImage(glyph, pointSize: 31, scale: 2, dark: false) }
            let two = Task { await model.glyphImage(glyph, pointSize: 31, scale: 2, dark: false) }
            await Task.yield()
            await Task.yield()
            let inFlight = model.imageCacheCountForSmoke.rendering
            let a = await one.value, b = await two.value
            check(a != nil && a === b && model.imageCacheCountForSmoke.rendering == 0 && inFlight <= 1,
                  "rules: concurrent image requests share one render", "in flight \(inFlight)")
        }

        // The first face is a large CJK font (slow to read: thousands of glyph names and a big GSUB), so the second,
        // small face finishes while the first is still loading; the first must not overwrite it.
        let hiragino = URL(fileURLWithPath: "/System/Library/Fonts/ヒラギノ角ゴシック W3.ttc")
        let raced = FeatureRulesModel(renderer: renderer)
        let firstDone = SmokeFlag()
        let first = Task {
            await raced.load(fileURL: hiragino, faceIndex: 0, selection: .all)
            firstDone.value = true
        }
        _ = await eventually(within: .seconds(2)) { raced.phase == .reading }
        await raced.load(fileURL: newYork, faceIndex: 0, selection: .all)
        let overlapped = !firstDone.value
        await first.value
        let expected = renderer.font(fileURL: newYork, faceIndex: 0, pointSize: 1)
            .flatMap { GSUBRuleReader.read($0) }?.counts(selection: .all) ?? [:]
        check(raced.phase == .ready && !expected.isEmpty && raced.counts == expected && overlapped,
              "rules: a stale load does not overwrite the new face",
              "\(raced.counts.count) vs \(expected.count), overlapped \(overlapped)")

        await model.load(fileURL: hoefler, faceIndex: 0, selection: .all)
        check(model.hasAATLayout, "rules: AAT font is flagged", "\(model.phase)")

        // Expanded features live on the app model (outlive the Features tab view), and are not saved.
        let app = AppModel()
        app.expandedRuleFeatures.insert("liga")
        check(app.expandedRuleFeatures == ["liga"] && AppModel().expandedRuleFeatures.isEmpty,
              "rules: expanded features are kept on the app model for the session only")
    }

    /// Compare: opening rules, cycling, swap, the missing-font scene, remembered text/recents in a temporary suite
    /// (never `.standard`), the empty state. The seeded faces have no files, so their scene sides are missing.
    private static func compareSteps() async {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("FontoryCompareSmoke-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: root) }
        let suiteName = "local.fontory.smoke.compare.\(UUID().uuidString)"
        guard let suite = UserDefaults(suiteName: suiteName) else { check(false, "compare: settings suite"); return }
        defer { suite.removePersistentDomain(forName: suiteName) }
        func standardKeys() -> [String] {
            UserDefaults.standard.dictionaryRepresentation().keys.filter { $0.hasPrefix("compare.") }.sorted()
        }
        let standardBefore = standardKeys()

        let backend: LibraryBackend
        let faces: [String: Int64]
        do {
            try fm.createDirectory(at: root, withIntermediateDirectories: true)
            backend = try LibraryBackend(databaseURL: root.appendingPathComponent("library.sqlite"))
            faces = try seed(backend.store, folder: root)
        } catch {
            check(false, "compare: setup", "\(error)"); return
        }
        guard let serif = faces["Smoke Serif"], let sans = faces["Smoke Sans"], let mono = faces["Smoke Mono"] else {
            check(false, "compare: seeded faces"); return
        }
        let compare = CompareModel(defaults: suite)
        compare.fontStore = { backend.store }
        check(compare.text == CompareModel.presets[0] && compare.options == CompareOptions() && compare.recentTexts.isEmpty,
              "compare: fresh suite starts with the first preset and default options")
        compare.canvasDidResize(CGSize(width: 800, height: 400), scale: 1)

        await compare.open(referenceFaceID: serif, candidateFaceIDs: [sans, mono])
        await compare.waitForRenderForSmoke()
        check(compare.a?.family == "Smoke Serif", "compare: open sets A to the reference family", compare.a?.family ?? "nil")
        check(compare.candidates.map(\.family) == ["Smoke Sans", "Smoke Mono"], "compare: open lists the candidate families",
              "\(compare.candidates.map(\.family))")
        check(compare.b?.family == "Smoke Sans", "compare: open sets B to the first candidate", compare.b?.family ?? "nil")
        check(compare.emptyMessage == nil, "compare: no empty message when fonts are open")
        check(compare.isCurrentCandidate(compare.candidates[0]) && !compare.isCurrentCandidate(compare.candidates[1]),
              "compare: the current candidate is B's family")
        check(compare.scene?.a.isMissing == true && compare.scene?.b.isMissing == true,
              "compare: fonts without files give missing scene sides")
        check(compare.scene?.a.label == "Smoke Serif Regular", "compare: the side label is Family Style", compare.scene?.a.label ?? "nil")
        check(compare.copyImage() == false, "compare: Copy has nothing to copy for missing fonts")

        compare.cycle(.family(1))
        await compare.waitForRenderForSmoke()
        check(compare.b?.family == "Smoke Mono", "compare: → cycles B to the next family", compare.b?.family ?? "nil")
        compare.cycle(.family(1))
        await compare.waitForRenderForSmoke()
        check(compare.b?.family == "Smoke Sans", "compare: → wraps around the candidates", compare.b?.family ?? "nil")
        compare.cycle(.family(-1))
        await compare.waitForRenderForSmoke()
        check(compare.b?.family == "Smoke Mono", "compare: ← cycles B back", compare.b?.family ?? "nil")
        let aBefore = compare.a, bBefore = compare.b
        compare.cycle(.style(1))
        compare.cycle(.referenceStyle(1))
        await compare.waitForRenderForSmoke()
        check(compare.a == aBefore && compare.b == bBefore, "compare: one-style families keep A and B on style keys")
        await compare.pickCandidate(compare.candidates[0])
        check(compare.b?.family == "Smoke Sans", "compare: picking a candidate makes it B")

        await compare.swap()
        await compare.waitForRenderForSmoke()
        check(compare.a?.family == "Smoke Sans" && compare.b?.family == "Smoke Serif", "compare: swap exchanges A and B",
              "\(compare.a?.family ?? "nil") / \(compare.b?.family ?? "nil")")
        check(compare.candidates.contains { $0.family == "Smoke Serif" }, "compare: swap puts the old A's family into the candidates")
        check(compare.scene?.a.isMissing == true, "compare: a missing A is replaced, not drawn", "\(String(describing: compare.scene?.a.isMissing))")

        compare.removeCandidate(compare.candidates[0])
        check(compare.candidates.count == 2, "compare: removing a candidate drops its family")

        compare.setText("Xin chào")
        check(suite.string(forKey: "compare.text") == "Xin chào" && compare.recentTexts.isEmpty,
              "compare: typing remembers the text but does not touch the recents")
        compare.commitText("Xin chào")
        check(compare.recentTexts == ["Xin chào"], "compare: committing a custom text lists it first")
        compare.commitText(CompareModel.presets[2])
        check(compare.recentTexts == ["Xin chào"] && suite.string(forKey: "compare.text") == CompareModel.presets[2],
              "compare: a committed preset is remembered as text but not as a recent")
        for i in 1...6 { compare.commitText("Text \(i)") }
        check(compare.recentTexts.count == 5 && compare.recentTexts.first == "Text 6" && !compare.recentTexts.contains("Xin chào"),
              "compare: only the five latest committed texts are kept", "\(compare.recentTexts)")
        compare.commitText("Text 3")
        check(compare.recentTexts.first == "Text 3" && compare.recentTexts.filter { $0 == "Text 3" }.count == 1,
              "compare: a repeated committed text moves to the front")
        compare.setOptions(CompareOptions(mode: .sideBySide, sizeRule: .matchXHeight, outlines: true, guides: false))
        let reloaded = CompareModel(defaults: suite)
        check(reloaded.text == "Text 3" && reloaded.recentTexts == compare.recentTexts
              && reloaded.options == CompareOptions(mode: .sideBySide, sizeRule: .matchXHeight, outlines: true, guides: false),
              "compare: text, recents and options persist across a new model")
        check(reloaded.a == nil && reloaded.b == nil && reloaded.candidates.isEmpty, "compare: A, B and candidates are not persisted")

        // Interleaved opens and a cycle: the last open wins, the cycle in between is dropped.
        let first = Task { await compare.open(referenceFaceID: serif, candidateFaceIDs: [sans, mono]) }
        let between = Task { compare.cycle(.family(1)) }
        let second = Task { await compare.open(referenceFaceID: mono, candidateFaceIDs: [serif, sans]) }
        await first.value; await between.value; await second.value
        await compare.waitForRenderForSmoke()
        check(compare.a?.family == "Smoke Mono" && compare.candidates.map(\.family) == ["Smoke Serif", "Smoke Sans"]
              && compare.b?.family == "Smoke Serif", "compare: interleaved opens and a cycle end on the last open",
              "\(compare.a?.family ?? "nil") \(compare.candidates.map(\.family)) \(compare.b?.family ?? "nil")")
        let slow = Task { await compare.open(referenceFaceID: serif, candidateFaceIDs: [sans]) }
        let empty = Task { await compare.open(referenceFaceID: nil, candidateFaceIDs: []) }
        await slow.value; await empty.value
        await compare.waitForRenderForSmoke()
        check(compare.a == nil && compare.emptyMessage != nil, "compare: an empty open is not overwritten by an earlier open")
        await compare.open(referenceFaceID: serif, candidateFaceIDs: [sans, mono])
        let swapTask = Task { await compare.swap() }
        let cycleTask = Task { compare.cycle(.family(1)) }
        await swapTask.value; await cycleTask.value
        await compare.waitForRenderForSmoke()
        // Swap first (A Sans, B Serif), then → wraps from Serif to Sans; the other order would give A Mono.
        check(compare.a?.family == "Smoke Sans" && compare.b?.family == "Smoke Sans",
              "compare: swap reads A and B when it runs, and a later cycle follows it",
              "\(compare.a?.family ?? "nil") / \(compare.b?.family ?? "nil")")

        await compare.open(referenceFaceID: nil, candidateFaceIDs: [])
        check(compare.emptyMessage == "Select fonts or add some to the Quick Collection, then press ⌥⌘K." && compare.a == nil
              && compare.b == nil && compare.candidates.isEmpty, "compare: opening with nothing shows the no-fonts message")

        // Opening rules on the app model (its own model reads the standard defaults, never writes them).
        let model = AppModel(layoutsDirectory: root.appendingPathComponent("Layouts", isDirectory: true),
                             templatesDirectory: root.appendingPathComponent("Templates", isDirectory: true))
        await model.attachBackendForSmoke(backend)
        await model.refreshNowForSmoke()
        model.compare.fontStore = { backend.store }
        check(model.compareSource.reference == nil && model.compareSource.candidates.isEmpty, "compare: nothing selected or collected has no source")
        model.quickCollectionIDs = [serif, sans, mono]
        let quick = model.quickCollectionIDs.sorted()
        check(model.compareSource.reference == quick.first && model.compareSource.candidates == Array(quick.dropFirst()),
              "compare: the Quick Collection is the source with nothing selected")
        model.selection = [sans]
        check(model.compareSource.reference == sans && model.compareSource.candidates == [serif, mono],
              "compare: one selected face against the Quick Collection without its family", "\(model.compareSource)")
        model.selection = [sans, mono, serif]
        let ordered = model.faceIDs.filter(model.selection.contains)
        check(model.compareSource.reference == ordered.first && model.compareSource.candidates == Array(ordered.dropFirst()),
              "compare: 2+ selected faces compare the first against the rest in browser order")
        model.selection = [serif, sans]
        await model.openInCompare()
        check(model.compare.a != nil && model.compare.candidates.count == 1 && model.compare.b?.family == model.compare.candidates.first?.family,
              "compare: openInCompare opens the selection")
        let noFlags = NSEvent.ModifierFlags(), arrowFlags: NSEvent.ModifierFlags = [.function, .numericPad]
        check(CompareCanvasView.command(keyCode: 123, modifiers: arrowFlags) == .cycle(.family(-1))
              && CompareCanvasView.command(keyCode: 124, modifiers: noFlags) == .cycle(.family(1))
              && CompareCanvasView.command(keyCode: 126, modifiers: arrowFlags) == .cycle(.style(-1))
              && CompareCanvasView.command(keyCode: 125, modifiers: arrowFlags) == .cycle(.style(1))
              && CompareCanvasView.command(keyCode: 126, modifiers: [.shift, .function, .numericPad]) == .cycle(.referenceStyle(-1))
              && CompareCanvasView.command(keyCode: 125, modifiers: .shift) == .cycle(.referenceStyle(1))
              && CompareCanvasView.command(keyCode: 8, modifiers: .command) == .copy
              && CompareCanvasView.command(keyCode: 8, modifiers: noFlags) == nil
              && CompareCanvasView.command(keyCode: 123, modifiers: .command) == nil
              && CompareCanvasView.command(keyCode: 51, modifiers: noFlags) == nil,
              "compare: canvas keys map keyCode + modifiers to cycling and copy")
        check(CompareReadout.percent(-6.4) == "−6%" && CompareReadout.percent(4.6) == "+5%" && CompareReadout.percent(0.2) == "0%"
              && CompareReadout.percent(nil) == "—" && CompareReadout.fraction(0.5312) == "0.53"
              && CompareReadout.lacks("B", 1) == "B lacks 1 character" && CompareReadout.lacks("A", 3) == "A lacks 3 characters"
              && CompareReadout.lacks("A", 0) == nil,
              "compare: readout formatting (percent, fraction, lacks)")
        model.compare.canvasDidResize(CGSize(width: 800, height: 400), scale: 1)
        await model.compare.waitForRenderForSmoke()
        if let scene = model.compare.scene {
            check(CompareReadout.rows(scene).map(\.title) == ["x-height", "Cap height", "Ascender", "Descender", "Width"]
                  && CompareReadout.notes(scene).isEmpty && CompareReadout.showsB(scene),
                  "compare: readout rows for a line (no scale note at the same size), B and Δ% shown with a B")
        } else {
            check(false, "compare: readout scene rendered after a canvas resize")
        }
        await model.compare.open(referenceFaceID: serif, candidateFaceIDs: [])
        await model.compare.waitForRenderForSmoke()
        if let scene = model.compare.scene {
            check(!CompareReadout.showsB(scene), "compare: no B hides the B and Δ% readout columns")
        } else {
            check(false, "compare: no-B scene rendered")
        }
        // Dropping fonts into an empty window: the first becomes A, the rest the candidates, the message goes.
        await model.compare.open(referenceFaceID: nil, candidateFaceIDs: [])
        check(model.compare.a == nil && model.compare.emptyMessage != nil, "compare: empty before the drop")
        await model.compare.addCandidates(faceIDs: [sans, mono, serif])
        await model.compare.waitForRenderForSmoke()
        check(model.compare.a?.family == "Smoke Sans" && model.compare.candidates.map(\.family) == ["Smoke Mono", "Smoke Serif"]
              && model.compare.b?.family == "Smoke Mono" && model.compare.emptyMessage == nil,
              "compare: dropping fonts into an empty window makes the first A, the rest candidates, and clears the message",
              "\(model.compare.a?.family ?? "nil") \(model.compare.candidates.map(\.family)) \(model.compare.b?.family ?? "nil") \(model.compare.emptyMessage ?? "nil")")
        model.selection = [sans, mono]
        model.quickCollectionIDs = [serif, sans, mono]
        model.openFamilyDetail(faceID: serif)
        _ = await eventually { model.detail?.family == "Smoke Serif" }
        check(model.compareSource.reference == serif && model.compareSource.candidates == [sans, mono],
              "compare: an open family page wins over 2+ selected faces", "\(model.compareSource)")
        // A family page compares the style being viewed: the single selected face, else the representative.
        model.setDetailForSmoke(FamilyDetail(family: "Smoke Serif", faceIDs: [serif, sans], representativeID: serif), selection: [sans])
        check(model.compareSource.reference == sans, "compare: a family page with one style selected compares that style",
              "\(model.compareSource)")
        model.setDetailForSmoke(FamilyDetail(family: "Smoke Serif", faceIDs: [serif, sans], representativeID: serif), selection: [])
        check(model.compareSource.reference == serif, "compare: a family page with no style selected compares the representative")
        model.setDetailForSmoke(FamilyDetail(family: "Smoke Serif", faceIDs: [serif, sans], representativeID: serif), selection: [sans, serif])
        check(model.compareSource.reference == serif, "compare: a family page with 2 styles selected compares the representative")
        model.setDetailForSmoke(nil)
        model.closeFamilyDetail()
        model.quickCollectionIDs = []
        model.selection = []

        // Characters ▸ Compare… keeps the previous custom text in the recents, then sets the character.
        compare.setText("Previous custom")
        await compare.open(referenceFaceID: serif, candidateFaceIDs: [sans], text: "ß")
        check(compare.text == "ß" && compare.recentTexts.first == "Previous custom",
              "compare: opening with a character text pushes the previous custom text to the recents", "\(compare.recentTexts)")
        let recentsBefore = compare.recentTexts
        compare.setText(CompareModel.presets[1])
        await compare.open(referenceFaceID: serif, candidateFaceIDs: [sans], text: "Q")
        check(compare.recentTexts == recentsBefore, "compare: a preset previous text is not pushed to the recents")
        // The legend names the current A, not the previous scene's.
        await compare.waitForRenderForSmoke()
        await compare.open(referenceFaceID: mono, candidateFaceIDs: [sans])
        check(compare.legendName(a: true) == "Smoke Mono", "compare: the legend shows the current A while a render is pending",
              compare.legendName(a: true) ?? "nil")
        await compare.waitForRenderForSmoke()
        check(compare.legendName(a: true) == "Smoke Mono Regular", "compare: the legend shows Family Style once rendered",
              compare.legendName(a: true) ?? "nil")

        check(standardKeys() == standardBefore, "compare: nothing was written to the standard defaults",
              "\(standardKeys()) vs \(standardBefore)")
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

    /// A real font file plus the synthetic faces, all marked as classified by an old version and without metadata,
    /// then the backfill.
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
            try store.database.withLock {
                try store.database.execute("UPDATE faces SET meta_version = 0, features = '', figure_style = 0")
                try store.database.execute("DELETE FROM face_coverage")
            }
            before = try store.countFacesNeedingBackfill()
            check(before == ids.count && before == 4, "backfill: 4 faces marked with an old class version and no metadata", "\(before)")
        } catch {
            check(false, "backfill setup", "\(error)")
            return
        }

        // During an unmount nothing starts (the handler starts it once the volume is offline).
        model.unmountsInProgress = 1
        let idleRuns = model.faceBackfillRuns
        model.startFaceBackfill()
        check(model.faceBackfillRuns == idleRuns && model.faceBackfillTask == nil, "backfill: no start while an unmount is handled")
        model.unmountsInProgress = 0

        // Coalescing: starting while a run goes only asks for one more run, never a second at once.
        let runs = model.faceBackfillRuns
        model.startFaceBackfill()
        model.startFaceBackfill()
        model.startFaceBackfill()
        check(model.faceBackfillRuns == runs + 1, "backfill: starting again while it runs does not start a second run")
        await model.waitForFaceBackfillForSmoke()
        check(model.faceBackfillRuns == runs + 2 && model.faceBackfillMaxRunning == 1,
              "backfill: the pending start ran once more afterwards, never two at once",
              "runs \(model.faceBackfillRuns - runs), max at once \(model.faceBackfillMaxRunning)")
        let remaining = await model.runBackground { try store.countFacesNeedingBackfill() }
        check(remaining == 0, "backfill: every face has the current class_version and meta_version", "\(String(describing: remaining))")
        let arial = await model.runBackground { () throws -> (features: String, figures: Int, covers: Bool) in
            try store.database.withLock {
                let s = try store.database.prepare("""
                SELECT faces.features, faces.figure_style, face_coverage.ranges FROM faces
                LEFT JOIN face_coverage ON face_coverage.face_id = faces.id WHERE faces.postscript_name = 'Arial-BoldMT'
                """)
                defer { s.reset() }
                guard try s.step() else { return ("", 0, false) }
                let covers = s.isNull(2) ? false : CoverageRanges(blob: s.blob(2))?.contains(0x41) == true
                return (s.text(0), Int(s.int64(1)), covers)
            }
        }
        check(arial.map { $0.features.contains(" kern ") && $0.figures == FigureStyle.lining.rawValue && $0.covers } == true,
              "backfill: Arial Bold gets its features, lining figures and coverage", "\(String(describing: arial))")
        let label = FaceBackfillRow.label(BackfillProgress(done: 200, total: 1500))
        check(label.hasPrefix("Updating font details… 200 of 1") && label.hasSuffix("500"),
              "backfill: progress reads \"Updating font details… N of M\"", label)
        check(model.faceBackfillProgress == nil, "backfill: progress hidden when done")
        await model.reloadOrganization()
        check(model.organizationCounts.perStyle[.sans] == 1 && model.organizationCounts.perStyle[.unknown] == 3,
              "backfill: Arial Bold reclassified as Sans, the unparsable files unknown", "\(model.organizationCounts.perStyle)")

        // Nothing to do: no progress shown.
        model.startFaceBackfill()
        check(model.faceBackfillProgress == nil, "backfill: no progress row when there is nothing to classify")
        await model.waitForFaceBackfillForSmoke()
        check(model.faceBackfillProgress == nil && model.faceBackfillMaxRunning == 1, "backfill: an empty run ends quietly")

        // Quitting stops it and refuses new runs.
        await model.stopFaceBackfill()
        let stoppedRuns = model.faceBackfillRuns
        model.startFaceBackfill()
        check(model.faceBackfillRuns == stoppedRuns && model.faceBackfillTask == nil, "backfill: no run after quit")
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

        // An unreadable stored rule: Edit… asks first and leaves rule_json alone; Replace opens an empty editor.
        let unreadable = #"{"conditions":[{"field":"fromTheFuture","op":"is","value":"x"}],"match":"all"}"#
        if let futureID = await model.createTag(name: "Future", parentID: nil, kind: .smart, ruleJSON: unreadable) {
            model.alert = nil
            model.editSmartTag(futureID)
            let stored = (try? store.tags())?.first { $0.id == futureID }?.ruleJSON
            check(model.smartTagEditor == nil && model.alert?.actionTitle == "Replace Rule…" && model.alert?.isDestructive == true
                  && stored == unreadable, "unreadable rule: Edit… shows the alert, rule_json unchanged")
            model.alert?.action?()
            model.alert = nil
            check(model.smartTagEditor?.tagID == futureID && model.smartTagEditor?.rows.isEmpty == true,
                  "unreadable rule: Replace Rule… opens an empty editor")
            model.cancelSmartTagEditor()
            let afterCancel = (try? store.tags())?.first { $0.id == futureID }?.ruleJSON
            check(afterCancel == unreadable, "unreadable rule: Cancel after Replace keeps rule_json")
            await model.deleteTag(futureID)
        } else {
            check(false, "create Future", model.alert?.message ?? "")
        }

        // A condition whose operator its field does not take is reset and marked.
        var odd = SmartRule()
        odd.conditions = [SmartRule.Condition(field: .weight, op: .contains, value: .text("x")),
                          SmartRule.Condition(field: .name, op: .contains, value: .text("a"))]
        let oddState = SmartTagEditorState(tagID: nil, name: "odd", rule: odd)
        check(oddState.rows.map(\.changedFromUnsupported) == [true, false] && oddState.rows[0].condition.op == .between,
              "unsupported operator: row reset and marked")
        oddState.rows[0].condition.value = .range(400, 700)
        check(!oddState.rows[0].changedFromUnsupported, "editing the marked row clears the mark")

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

    // MARK: Final review fixes

    /// Starts organization reloads every millisecond until cancelled (as scans and the backfill do).
    private static func hammerReloads(_ model: AppModel) -> Task<Void, Never> {
        Task { @MainActor in
            while !Task.isCancelled {
                Task { await model.reloadOrganization() }
                try? await Task.sleep(for: .milliseconds(1))
            }
        }
    }

    private static func coreIDs(_ store: FontStore, _ rule: SmartRule, includeSystem: Bool) -> Set<Int64> {
        Set((try? store.faceIDs(for: LibraryQuery(scope: .tags([TagPick(tagID: -1, rule: rule)]), includeSystem: includeSystem))) ?? [])
    }

    private static func reviewFixSteps(_ model: AppModel, backend: LibraryBackend) async {
        let store = backend.store
        let includeSystem = model.query.includeSystem

        // Coalescing: N rapid triggers cost at most two runs (one in flight, one pending).
        await model.reloadOrganization()
        let runsBefore = model.organizationReloadRuns
        let burst = (0..<25).map { _ in Task { @MainActor in await model.reloadOrganization() } }
        for t in burst { await t.value }
        let burstRuns = model.organizationReloadRuns - runsBefore
        check((1...2).contains(burstRuns), "25 rapid organization reloads run at most twice", "\(burstRuns) runs")
        // The same while one is already in flight.
        let first = Task { @MainActor in await model.reloadOrganization() }
        while model.organizationReloadTask == nil { await Task.yield() }
        let runsMid = model.organizationReloadRuns
        let more = (0..<25).map { _ in Task { @MainActor in await model.reloadOrganization() } }
        await first.value
        for t in more { await t.value }
        let midRuns = model.organizationReloadRuns - runsMid
        check(midRuns <= 2, "25 reloads during one in flight add at most one more run", "\(midRuns) runs")

        // A new smart tag is selected, and a shown one edited, while reloads keep firing.
        var monoRule = SmartRule()
        monoRule.conditions = [SmartRule.Condition(field: .styleClass, op: .is, value: .int(Int64(StyleClass.mono.rawValue)))]
        var sansRule = SmartRule()
        sansRule.conditions = [SmartRule.Condition(field: .styleClass, op: .is, value: .int(Int64(StyleClass.sans.rawValue)))]
        var hammer = hammerReloads(model)
        model.newSmartTag()
        guard let fresh = model.smartTagEditor else { hammer.cancel(); check(false, "editor opens"); return }
        fresh.name = "Review Mono"
        fresh.rows = []
        fresh.addRow()
        fresh.rows[0].condition = monoRule.conditions[0]
        await model.saveSmartTag(fresh)
        let monoID = model.selectedTagPicks.first?.tagID
        check(model.selectedTagPicks.count == 1 && monoID.flatMap { model.tag($0) }?.name == "Review Mono"
              && model.selectedTagPicks.first?.rule == monoRule,
              "busy reloads: a new smart tag is selected at once", "\(model.selectedTagPicks)")
        guard let monoID else { hammer.cancel(); return }

        model.editSmartTag(monoID)
        guard let edit = model.smartTagEditor else { hammer.cancel(); check(false, "Edit… opens"); return }
        edit.rows[0].condition = sansRule.conditions[0]
        await model.saveSmartTag(edit)
        check(model.selectedTagPicks.first?.rule == sansRule, "busy reloads: the edited rule is shown at once",
              "\(String(describing: model.selectedTagPicks.first?.rule))")
        hammer.cancel()
        await model.reloadOrganization()
        let afterEdit = await shown(model)
        check(model.selectedTagPicks.first?.rule == sansRule && afterEdit == coreIDs(store, sansRule, includeSystem: includeSystem),
              "edit during an in-flight reload: the browser ends on the new rule", "\(afterEdit.count) shown")

        // ⊕ New Tag while reloads keep firing: the inline rename starts on a row that exists.
        hammer = hammerReloads(model)
        await model.newTag()
        let renaming = model.renamingTagID
        check(renaming != nil && renaming.flatMap { model.tag($0) } != nil, "busy reloads: New Tag starts its rename on a listed row")
        hammer.cancel()
        await model.reloadOrganization()
        if let renaming { await model.deleteTag(renaming) }
        model.renamingTagID = nil

        // A rule naming the newest tag keeps matching nothing after the tag is deleted and its id reused.
        guard let holderID = await model.createTag(name: "Review Holder", parentID: nil, kind: .smart, ruleJSON: "{}"),
              let newest = await model.createTag(name: "Review Newest", parentID: nil),
              let serifFace = (try? store.faceIDs(for: LibraryQuery()))?.first else {
            check(false, "tombstone setup", model.alert?.message ?? ""); return
        }
        await model.setTag(newest, onFaces: [serifFace], included: true)
        model.editSmartTag(holderID)
        if let h = model.smartTagEditor {
            h.rows = []
            h.addRow()
            h.rows[0].condition = SmartRule.Condition(field: .tag, op: .has, value: .int(newest))
            await model.saveSmartTag(h)
        }
        check(model.smartTagCounts[holderID] == 1, "rule on the newest tag matches its font",
              "\(String(describing: model.smartTagCounts[holderID]))")
        await model.deleteTag(newest)
        let reused = await model.createTag(name: "Review Reused", parentID: nil)
        if let reused { await model.setTag(reused, onFaces: [serifFace], included: true) }
        await model.reloadOrganization()
        let holderRule = model.tag(holderID).flatMap { SmartRule.decode($0.ruleJSON ?? "") }
        print("  deleted tag id \(newest), new tag id \(String(describing: reused))")
        check(reused == newest && holderRule?.conditions.first?.value == .int(SmartRule.deletedID)
              && model.smartTagCounts[holderID] == 0 && coreIDs(store, holderRule ?? SmartRule(), includeSystem: includeSystem).isEmpty,
              "deleted newest tag, new tag takes its id: the rule holds the tombstone and matches nothing",
              "rule \(String(describing: holderRule)), count \(String(describing: model.smartTagCounts[holderID]))")

        // A smart tag dropped on a plain tag is refused with an alert; it stays top level.
        if let reused {
            model.alert = nil
            await model.dropTag(holderID, onto: reused)
            let storedParent = (try? store.tags())?.first { $0.id == holderID }?.parentID
            check(model.alert?.message == "Smart tags stay at the top level." && model.tag(holderID)?.parentID == nil && storedParent == nil,
                  "smart tag dropped under a plain tag: refused with an alert", model.alert?.message ?? "no alert")
            model.alert = nil
        }

        // The style-only reload refreshes the Style counts.
        await model.reloadOrganization(.styles)
        let styles = (try? store.styleCounts(includeSystem: includeSystem)) ?? [:]
        check(model.organizationCounts.perStyle == styles, "style-only reload refreshes the Style counts")
    }

    // MARK: Wave 3a task 4: Filters popover

    /// Three faces with metadata in their own location (the earlier faces have none, so they never match a feature).
    private static func seedFilterFaces(_ store: FontStore, folder: URL) throws -> (location: Int64, ids: [String: Int64]) {
        let loc = try store.upsertLocation(kind: .folder, volumeUUID: "SMOKE-FILTERS", relativePath: "Filters",
                                           displayName: "Filters", lastKnownPath: folder.path)
        let batch = try store.nextImportBatch()
        let latin = Array(0x41...0x5A).map(UInt32.init) + Array(0x61...0x7A).map(UInt32.init)
        let defs: [(String, [String], FigureStyle, OutlineType, Bool, Bool, [UInt32])] = [
            ("FilterA", ["liga", "smcp"], .lining, .cff, false, false, latin + VietnameseLetters.scalars),
            ("FilterB", ["liga"], .oldstyle, .truetype, true, false, latin),
            ("FilterC", [], .unknown, .bitmap, false, true, [0x41]),
        ]
        for (name, features, figures, outline, variable, color, scalars) in defs {
            let meta = FaceMetadata(coverage: CoverageRanges(scalars: scalars), features: features, figureStyle: figures)
            let face = ParsedFace(postScriptName: "\(name)-Regular", family: name, style: "Regular", fullName: "\(name) Regular",
                                  isVariable: variable, glyphCount: 100, outlineType: outline, isColor: color, metadata: meta)
            let file = FileRecord(locationID: loc.id, relativePath: "\(name).otf", size: 10, mtime: Date(timeIntervalSince1970: 1000),
                                  format: "otf", fingerprint: "filter-\(name)")
            _ = try store.insertFile(file, faces: [face], importBatch: batch)
        }
        var q = LibraryQuery(scope: .location(id: loc.id, subfolder: nil))
        q.includeSystem = true
        var out: [String: Int64] = [:]
        for row in try store.rows(ids: try store.faceIDs(for: q)).values { out[row.family] = row.id }
        return (loc.id, out)
    }

    /// What the core returns for the model's current query (its scope, search and filters).
    private static func coreShown(_ store: FontStore, _ model: AppModel) -> Set<Int64> {
        Set((try? store.faceIDs(for: model.query)) ?? [-1])
    }

    private static func filterSteps(_ model: AppModel, backend: LibraryBackend, folder: URL) async {
        let store = backend.store
        model.suppressesPreviewSaveForSmoke = true
        let savedPreview = model.preview
        defer { model.preview = savedPreview }
        let seeded: (location: Int64, ids: [String: Int64])
        do { seeded = try seedFilterFaces(store, folder: folder) } catch { check(false, "filters: seed", "\(error)"); return }
        guard let a = seeded.ids["FilterA"], let b = seeded.ids["FilterB"] else {
            check(false, "filters: seed", "\(seeded.ids)")
            return
        }
        model.searchText = ""
        model.query.scope = .all
        model.clearFilters()
        let unfiltered = await shown(model)
        // Earlier steps indexed real fonts too: expectations are about the seeded faces; the whole result must equal the core's.
        let seededSet = Set(seeded.ids.values)
        func ours(_ ids: Set<Int64>) -> Set<Int64> { ids.intersection(seededSet) }
        check(unfiltered.isSuperset(of: [a, b]) && model.query.filters.isEmpty, "filters: unfiltered All shows the seeded faces",
              "\(unfiltered.count) faces")

        // Two filters: applied at once (no text), result equals the core query.
        model.filters.features = ["liga"]
        model.filters.figures = .lining
        check(model.query.filters == model.filters && model.filterApplyTask == nil, "filters: non-text controls apply at once")
        var now = await shown(model)
        check(ours(now) == [a] && now.count < unfiltered.count && now == coreShown(store, model), "filters: liga + lining equals the core query",
              "shown \(now), core \(coreShown(store, model))")
        check(model.effectiveFilters.activeCount == 2 && model.browserCountText == "\(now.count) font\(now.count == 1 ? "" : "s") · 2 filters", "filters: badge and window subtitle count",
              "\(model.effectiveFilters.activeCount), \"\(model.browserCountText)\"")
        // Another sidebar view keeps them.
        model.query.scope = .location(id: seeded.location, subfolder: nil)
        now = await shown(model)
        check(ours(now) == [a] && now == coreShown(store, model) && !model.query.filters.isEmpty, "filters: kept on another sidebar view",
              "\(now)")
        model.query.scope = .all
        model.clearFilters()

        // Characters field: debounced 150 ms.
        model.filters.requiredCharacters = "Ab"
        check(model.query.filters.requiredCharacters.isEmpty && model.filterApplyTask != nil, "filters: typed characters wait for the debounce")
        try? await Task.sleep(for: .milliseconds(300))
        now = await shown(model)
        check(model.query.filters.requiredCharacters == "Ab" && ours(now) == [a, b] && now == coreShown(store, model),
              "filters: characters field applied after 150 ms", "\"\(model.query.filters.requiredCharacters)\" \(now)")

        // "Supports the preview text": combined with the field, follows the preview text, off clears only the mirror.
        model.preview.showsFontNames = false
        model.preview.text = ""
        check(!model.canFollowPreviewText, "filters: preview mirror unavailable while the preview is Dynamic")
        model.preview.text = "Ắ Z"
        check(model.canFollowPreviewText, "filters: preview mirror available with typed text")
        model.followsPreviewText = true
        now = await shown(model)
        check(model.query.filters.requiredCharacters == "AbẮ Z" && ours(now) == [a] && now == coreShown(store, model),
              "filters: preview text combined with the characters field", "\"\(model.query.filters.requiredCharacters)\" \(now)")
        check(model.effectiveFilters.activeCount == 1, "filters: field + mirror count as one filter")
        model.preview.text = "z"
        try? await Task.sleep(for: .milliseconds(300))
        now = await shown(model)
        check(model.query.filters.requiredCharacters == "Abz" && ours(now) == [a, b] && now == coreShown(store, model),
              "filters: follows a preview text change", "\"\(model.query.filters.requiredCharacters)\" \(now)")
        model.followsPreviewText = false
        check(model.query.filters.requiredCharacters == "Ab" && model.filters.requiredCharacters == "Ab",
              "filters: turning the mirror off keeps the typed characters", "\"\(model.query.filters.requiredCharacters)\"")
        model.followsPreviewText = true
        model.preview.text = ""
        check(!model.followsPreviewText && model.query.filters.requiredCharacters == "Ab",
              "filters: an emptied (Dynamic) preview turns the mirror off", "\"\(model.query.filters.requiredCharacters)\"")

        // Feature tags: 4 printable ASCII, no spaces; added once.
        let valid = ["ss01", " cv01 ", "kern", "c2sc"].map(AppModel.validFeatureTag)
        let invalid = ["", "abc", "abcde", "ab c", "abçd", "ab\td"].map(AppModel.validFeatureTag)
        check(valid == ["ss01", "cv01", "kern", "c2sc"] && invalid.allSatisfy { $0 == nil }, "filters: feature tag validation",
              "\(valid) \(invalid)")
        let added = model.addFeatureTag("smcp"), again = model.addFeatureTag("smcp"), bad = model.addFeatureTag("sm")
        check(added && again && !bad && model.filters.features == ["smcp"] && model.query.filters.features == ["smcp"],
              "filters: tag added once, invalid tag refused", "\(model.filters.features)")
        now = await shown(model)
        check(ours(now) == [a] && now == coreShown(store, model), "filters: characters + typed feature tag equal the core query", "\(now)")
        model.removeFeatureTag("smcp")
        check(model.query.filters.features.isEmpty, "filters: tag removed")

        // Script menu: Vietnamese and a script are one choice; kind tri-states.
        model.filters.vietnamese = true
        model.filters.variable = .exclude
        now = await shown(model)
        check(ours(now) == [a] && now == coreShown(store, model), "filters: Vietnamese + not variable equal the core query", "\(now)")

        // Clear All.
        model.followsPreviewText = false
        model.filters.outline = .bitmap
        model.clearFilters()
        now = await shown(model)
        check(now == unfiltered && model.query.filters.isEmpty && model.filters.isEmpty && !model.followsPreviewText
              && model.effectiveFilters.activeCount == 0 && model.browserCountText == "\(unfiltered.count) fonts",
              "filters: Clear All restores the unfiltered count", "\(now.count) of \(unfiltered.count), \"\(model.browserCountText)\"")
        let persisted = UserDefaults.standard.dictionaryRepresentation().keys.filter { $0.localizedCaseInsensitiveContains("filter") }
        check(persisted.isEmpty, "filters: nothing written to defaults", "\(persisted)")
    }

    // MARK: Wave 3a task 5: Duplicates

    /// Records unregistrations (and whether the file was still there), registers nothing on the Mac.
    final class SmokeRegistrar: FontRegistrar, @unchecked Sendable {
        private let lock = NSLock()
        private var log: [(path: String, existed: Bool)] = []

        /// Every register and unregister, in order, with the path (registration order checks).
        private var calls: [(register: Bool, path: String)] = []

        var unregistered: [(path: String, existed: Bool)] { lock.withLock { log } }
        var events: [(register: Bool, path: String)] { lock.withLock { calls } }

        func register(_ urls: [URL]) async -> [URL: RegistrationOutcome] {
            lock.withLock { for url in urls { calls.append((true, url.path)) } }
            return Dictionary(urls.map { ($0, .ok) }, uniquingKeysWith: { a, _ in a })
        }

        func unregister(_ urls: [URL]) async -> [URL: RegistrationOutcome] {
            lock.withLock {
                for url in urls {
                    log.append((url.path, FileManager.default.fileExists(atPath: url.path)))
                    calls.append((false, url.path))
                }
            }
            return Dictionary(urls.map { ($0, .ok) }, uniquingKeysWith: { a, _ in a })
        }

        func availablePostScriptNames() -> Set<String> { [] }
    }

    private static func indexedPaths(_ store: FontStore, _ locationID: Int64) -> [String: Int64] {
        Dictionary(((try? store.files(in: locationID)) ?? []).map { ($0.relativePath, $0.id) }, uniquingKeysWith: { a, _ in a })
    }

    private static func hashedFileCount(_ store: FontStore) -> Int {
        (try? store.database.withLock {
            let s = try store.database.prepare("SELECT COUNT(*) FROM files WHERE content_hash IS NOT NULL")
            defer { s.reset() }
            return try s.step() ? Int(s.int64(0)) : -1
        }) ?? -1
    }

    /// Export (spec §19) with the panels skipped: a tag's files, the Quick Collection as a ZIP, a missing file counted.
    private static func exportSteps(_ model: AppModel, backend: LibraryBackend, faces: [String: Int64], folder: URL) async {
        let fm = FileManager.default
        guard let serif = faces["Smoke Serif"], let sans = faces["Smoke Sans"], let mono = faces["Smoke Mono"] else {
            check(false, "export: faces missing")
            return
        }
        // Real files for Serif and Sans; Mono's file does not exist.
        for name in ["SmokeSerif.otf", "SmokeSans.otf"] {
            try? Data("font \(name)".utf8).write(to: folder.appendingPathComponent(name))
        }
        try? fm.removeItem(at: folder.appendingPathComponent("SmokeMono.otf"))
        let out = folder.appendingPathComponent("ExportOut", isDirectory: true)
        try? fm.createDirectory(at: out, withIntermediateDirectories: true)
        model.exportDestinationOverride = out
        model.exportOptionsOverride = (byFamily: false, zip: false)
        guard let tag = await model.createTag(name: "ExportTag", parentID: nil) else { check(false, "export: create tag"); return }
        await model.setTag(tag, onFaces: [serif, sans], included: true)
        await model.exportTag(tag)
        let copied = ((try? fm.contentsOfDirectory(atPath: out.path)) ?? []).sorted()
        check(copied == ["SmokeSans.otf", "SmokeSerif.otf"], "export: a tag's files are copied into the destination", "\(copied)")
        check(model.lastExportResult?.copied == 2 && model.lastExportResult?.skipped == 0, "export: the tag export reports 2 copied", "\(String(describing: model.lastExportResult))")
        check(model.alert == nil, "export: no alert while the destination is overridden", model.alert?.message ?? "")

        await model.toggleQuickCollection([serif, sans, mono])
        model.exportOptionsOverride = (byFamily: true, zip: true)
        await model.exportQuickCollection()
        let zip = out.appendingPathComponent("Quick Collection.zip")
        check(fm.fileExists(atPath: zip.path), "export: the Quick Collection with ZIP produces Quick Collection.zip",
              "\(((try? fm.contentsOfDirectory(atPath: out.path)) ?? []))")
        check(model.lastExportResult?.copied == 2 && model.lastExportResult?.skipped == 1 && model.lastExportResult?.output == zip,
              "export: the missing file is skipped and counted", "\(String(describing: model.lastExportResult))")
        check(model.exportProgress == nil, "export: the progress sheet is closed afterwards")

        // A genuinely offline file: its location is marked offline (url nil).
        do {
            let store = backend.store
            let loc = try store.upsertLocation(kind: .folder, volumeUUID: "SMOKE-OFFLINE", relativePath: "Gone",
                                               displayName: "Gone", lastKnownPath: folder.appendingPathComponent("Gone").path)
            let face = ParsedFace(postScriptName: "SmokeGone-Regular", family: "Smoke Gone", style: "Regular",
                                  fullName: "Smoke Gone Regular", glyphCount: 10, styleClass: .sans)
            let file = FileRecord(locationID: loc.id, relativePath: "SmokeGone.otf", size: 10, mtime: Date(timeIntervalSince1970: 1000),
                                  format: "otf", fingerprint: "smoke-gone")
            _ = try store.insertFile(file, faces: [face], importBatch: try store.nextImportBatch())
            try store.setLocationOnline(loc.id, online: false, lastKnownPath: nil)
            let goneID = try store.rows(ids: try store.faceIDs(for: LibraryQuery(includeSystem: true))).values.first { $0.family == "Smoke Gone" }?.id
            guard let gone = goneID else { check(false, "export: offline face missing"); return }
            check(AppModel.offlineMessage(1) == "1 font is on a drive that isn't connected. Export the others?"
                  && AppModel.offlineMessage(3) == "3 fonts are on a drive that isn't connected. Export the others?",
                  "export: the offline question's copy")
            let before = ((try? fm.contentsOfDirectory(atPath: out.path)) ?? []).sorted()
            var asked: [Int] = []
            model.exportOfflineAnswer = { asked.append($0); return false }
            model.exportOptionsOverride = (byFamily: false, zip: false)
            await model.exportFonts(faceIDs: [serif, gone], suggestedName: "Mixed")
            check(asked == [1], "export: the offline question is asked with the offline count", "\(asked)")
            check(((try? fm.contentsOfDirectory(atPath: out.path)) ?? []).sorted() == before, "export: answering Cancel exports nothing")
            model.exportOfflineAnswer = { asked.append($0); return true }
            model.exportOptionsOverride = (byFamily: true, zip: false)
            await model.exportFonts(faceIDs: [serif, gone], suggestedName: "Mixed")
            check(model.lastExportResult?.copied == 1 && model.lastExportResult?.skipped == 1,
                  "export: answering Export copies the others and counts the offline file", "\(String(describing: model.lastExportResult))")
            // Everything offline: an informational alert, no question, no export.
            asked = []
            model.lastExportResult = nil
            await model.exportFonts(faceIDs: [gone], suggestedName: "Gone")
            check(asked.isEmpty && model.lastExportResult == nil && model.alert?.actionTitle == nil
                  && model.alert?.message == "1 font is on a drive that isn't connected.",
                  "export: when every file is offline an alert says so and nothing is exported", model.alert?.message ?? "no alert")
            model.alert = nil
        } catch {
            check(false, "export: offline setup", "\(error)")
        }
        model.exportOfflineAnswer = nil
        model.exportDestinationOverride = nil
        model.exportOptionsOverride = nil
    }

    /// A temporary library (its own registrar and settings suite) with copies of a system font: an OTF-named copy, a TTF
    /// copy, a copy in a subfolder (for the Trash) and a padded copy (same font, different file).
    private static func duplicateSteps() async {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("FontoryDuplicatesSmoke-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: root) }
        let suiteName = "local.fontory.smoke.duplicates.\(UUID().uuidString)"
        guard let suite = UserDefaults(suiteName: suiteName) else { check(false, "duplicates: settings suite"); return }
        defer { suite.removePersistentDomain(forName: suiteName) }
        let token = String(UUID().uuidString.prefix(8))
        let subName = "Sub/Arial copy \(token).ttf"
        let fonts = root.appendingPathComponent("Fonts", isDirectory: true)
        let source = URL(fileURLWithPath: "/System/Library/Fonts/Supplemental/Arial Bold.ttf")
        let standardBefore = ["previewSettings", SettingsKey.duplicateLocationRank, SettingsKey.skipDuplicatesOnImport]
            .map { String(describing: UserDefaults.standard.object(forKey: $0)) }
        let registrar = SmokeRegistrar()
        let backend: LibraryBackend
        do {
            try fm.createDirectory(at: fonts.appendingPathComponent("Sub"), withIntermediateDirectories: true)
            for name in ["Arial.otf", "Arial.ttf", subName] { try fm.copyItem(at: source, to: fonts.appendingPathComponent(name)) }
            try (Data(contentsOf: source) + Data(count: 4096)).write(to: fonts.appendingPathComponent("Arial padded.ttf"))
            backend = try LibraryBackend(databaseURL: root.appendingPathComponent("library.sqlite"), registrar: registrar)
        } catch {
            check(false, "duplicates: setup", "\(error)")
            return
        }
        let store = backend.store
        let model = AppModel()
        model.settingsDefaults = suite
        model.suppressesPreviewSaveForSmoke = true
        // Never the user's Trash: "recycling" moves the file into a Trash folder of the temp root.
        let smokeTrash = root.appendingPathComponent("Trash", isDirectory: true)
        try? fm.createDirectory(at: smokeTrash, withIntermediateDirectories: true)
        model.recycleFile = { url in
            let target = smokeTrash.appendingPathComponent(url.lastPathComponent)
            do {
                try FileManager.default.moveItem(at: url, to: target)
                return (target, nil)
            } catch {
                return (nil, error.localizedDescription)
            }
        }
        await model.attachBackendForSmoke(backend)
        guard let loc = await model.runBackground({ try backend.addFolder(fonts) }) else {
            check(false, "duplicates: add the folder", model.alert?.message ?? ""); return
        }
        await model.reloadLocations()
        model.rescan(loc.id)
        await model.waitForScansForSmoke()
        check(indexedPaths(store, loc.id).count == 4, "duplicates: 4 copies indexed", "\(indexedPaths(store, loc.id).keys.sorted())")

        // No search starts while an unmount is handled; the handler starts it afterwards.
        await model.waitForDuplicateSearchForSmoke()  // the count's grouping after the scan
        model.unmountsInProgress = 1
        let idle = model.duplicateRuns
        model.findDuplicates()
        check(model.duplicateRuns == idle && model.duplicateTask == nil, "duplicates: no search starts while an unmount is handled")
        model.unmountsInProgress = 0
        model.cancelDuplicateSearch()  // drops the pending start (the view is not showing)

        // The sidebar row shows the view and starts hashing; an unmount cancels it before a file is read, and the
        // view searches again once the volume is offline.
        await model.waitForFaceBackfillForSmoke()  // hashing waits for an idle backfill (checked below)
        let runs = model.duplicateRuns, cancelled = model.duplicateRunsCancelled
        check(model.filtersAvailable, "duplicates: the Filters button works in the browser")
        model.isShowingFilters = true
        model.applySidebarSelection([.duplicates], modifiers: [])
        check(model.isShowingDuplicates && model.sidebarSelection == [.duplicates] && model.duplicateTask != nil && model.duplicateRuns == runs + 1,
              "duplicates: the sidebar row shows the view and starts a search")
        check(!model.filtersAvailable && !model.isShowingFilters, "duplicates: the Filters button is disabled (and its popover closed) in the Duplicates view")
        await model.handle(.unmounted(volumeURL: fonts))
        await model.waitForDuplicateSearchForSmoke()
        check(model.duplicateRunsCancelled == cancelled + 1 && hashedFileCount(store) == 0,
              "duplicates: hashing cancelled on unmount, nothing hashed", "cancelled \(model.duplicateRunsCancelled - cancelled), hashed \(hashedFileCount(store))")
        check(model.duplicateRuns == runs + 2 && model.location(loc.id)?.online == false,
              "duplicates: searched again after the unmount (view showing)", "runs \(model.duplicateRuns - runs)")
        await model.handle(.mounted(volumeURL: fonts, uuid: loc.volumeUUID))
        await model.waitForScansForSmoke()
        await model.waitForDuplicateSearchForSmoke()
        await model.waitForFaceBackfillForSmoke()
        check(model.location(loc.id)?.online == true, "duplicates: the folder is back online")

        // Hashing waits while the face backfill runs (a stand-in task here), shows it, and starts when the backfill ends.
        let standIn = Task<Void, Never> {}
        model.faceBackfillTask = standIn
        model.faceBackfillRunning += 1
        let beforeWait = model.duplicateRuns
        model.findDuplicates()
        check(model.isWaitingForFaceBackfill && model.isFindingDuplicates && model.duplicateTask == nil && model.duplicateRuns == beforeWait
              && model.duplicateSearchStatus == "Waiting for font details…",
              "duplicates: hashing waits for the face backfill", model.duplicateSearchStatus)
        model.startDuplicateSearch(hashing: false)
        check(model.duplicateRuns == beforeWait && model.duplicateTask == nil, "duplicates: a start while waiting joins the pending search")
        // The Filters note while the backfill fills in metadata a filter reads.
        model.faceBackfillProgress = BackfillProgress(done: 3, total: 10)
        check(model.filtersBackfillNote == nil, "filters: no backfill note without a metadata filter")
        model.filters.vietnamese = true
        check(model.filtersBackfillNote == "Font details are still updating — 3 of 10; some fonts may be missing from filtered results",
              "filters: the popover notes the running backfill for a metadata filter", model.filtersBackfillNote ?? "nil")
        model.filters.vietnamese = false
        model.faceBackfillEnded()
        check(!model.isWaitingForFaceBackfill && model.duplicateRuns == beforeWait + 1 && model.duplicateTask != nil && model.filtersBackfillNote == nil,
              "duplicates: the waiting search starts when the face backfill ends")
        await model.waitForDuplicateSearchForSmoke()

        // Groups.
        model.findDuplicates()
        await model.waitForDuplicateSearchForSmoke()
        var paths = indexedPaths(store, loc.id)
        guard let otf = paths["Arial.otf"], let ttf = paths["Arial.ttf"], let sub = paths[subName], let padded = paths["Arial padded.ttf"] else {
            check(false, "duplicates: indexed paths", "\(paths.keys.sorted())"); return
        }
        let exact = model.duplicateGroups.filter { $0.kind == .exact }
        let sameFont = model.duplicateGroups.filter { $0.kind == .sameFont }
        check(exact.count == 1 && Set(exact.first?.fileIDs ?? []) == [otf, ttf, sub], "duplicates: one exact group of the 3 copies",
              "\(model.duplicateGroups.map { "\($0.kind) \($0.fileIDs)" })")
        check(sameFont.count == 1 && sameFont.first?.fileIDs.contains(padded) == true && sameFont.first?.fileIDs.count == 2,
              "duplicates: the padded file is a same-font group with the copies", "\(sameFont.map(\.fileIDs))")
        check(model.duplicateGroups.first?.kind == .exact && hashedFileCount(store) == 3, "duplicates: exact groups first; only the 3 equal fingerprints hashed",
              "hashed \(hashedFileCount(store))")
        check(model.duplicateRows[exact.first?.faceIDs.first ?? -1]?.postScriptName == "Arial-BoldMT" && model.duplicateFiles[otf]?.size ?? 0 > 0,
              "duplicates: rows carry the face and the file size")

        // Select Copies to Remove keeps the OTF; same-font rows are never selected but can be checked by hand.
        await model.selectCopiesToRemove()
        check(model.checkedDuplicateFiles == [ttf, sub], "duplicates: auto-select keeps the OTF over the TTF", "\(model.checkedDuplicateFiles)")
        // Keep rule 1b: a tagged TTF is kept over the untagged OTF.
        guard let ttfFace = model.duplicateFacesByFile[ttf]?.first?.id, let keepTag = await model.createTag(name: "Dup Keep", parentID: nil) else {
            check(false, "duplicates: keep-tag setup"); return
        }
        await model.setTag(keepTag, onFaces: [ttfFace], included: true)
        await model.selectCopiesToRemove()
        check(model.checkedDuplicateFiles == [otf, sub], "duplicates: auto-select keeps the tagged TTF (rule 1b)", "\(model.checkedDuplicateFiles)")
        await model.setTag(keepTag, onFaces: [ttfFace], included: false)
        await model.selectCopiesToRemove()
        check(model.checkedDuplicateFiles == [ttf, sub], "duplicates: untagged again, the OTF is kept", "\(model.checkedDuplicateFiles)")
        model.setDuplicateChecked(padded, true)
        check(model.checkedDuplicateFiles.contains(padded), "duplicates: a same-font row can be checked by hand")
        model.setDuplicateChecked(padded, false)

        // Remove from Library: excluded, a rescan does not bring it back, Include Again does. A tagged face counts in
        // the "N fonts removed" notice.
        guard let subFace = model.duplicateFacesByFile[sub]?.first?.id, let tag = await model.createTag(name: "Dup Smoke", parentID: nil) else {
            check(false, "duplicates: tag setup"); return
        }
        await model.setTag(tag, onFaces: [subFace], included: true)
        model.checkedDuplicateFiles = [sub]
        model.alert = nil
        await model.removeCheckedFromLibrary()
        check(model.alert?.actionTitle == "Remove" && model.alert?.isDestructive == true
              && model.alert?.message.hasPrefix("1 font with tags or notes will lose them") == true && indexedPaths(store, loc.id)[subName] == sub,
              "duplicates: Remove from Library asks first when fonts have tags or notes", model.alert?.message ?? "no alert")
        model.alert?.action?()
        model.alert = nil
        for _ in 0..<500 where indexedPaths(store, loc.id)[subName] != nil || model.isRemovingDuplicates { try? await Task.sleep(for: .milliseconds(20)) }
        await model.waitForDuplicateSearchForSmoke()
        paths = indexedPaths(store, loc.id)
        check(paths[subName] == nil && fm.fileExists(atPath: fonts.appendingPathComponent(subName).path)
              && model.excludedFiles == [ExcludedFile(locationID: loc.id, relativePath: subName)],
              "duplicates: Remove from Library excludes the file and leaves it on disk", "\(model.excludedFiles)")
        check(model.removalNotices[loc.id] == 1, "duplicates: the tagged face counts in the fonts-removed notice", "\(model.removalNotices)")
        check(model.checkedDuplicateFiles.isEmpty && !model.duplicateGroups.contains { $0.fileIDs.contains(sub) },
              "duplicates: the removed file leaves the groups")
        model.rescan(loc.id)
        await model.waitForScansForSmoke()
        check(indexedPaths(store, loc.id)[subName] == nil, "duplicates: a rescan does not bring it back")
        if let excluded = model.excludedFiles.first { await model.includeAgain(excluded) }
        await model.waitForScansForSmoke()
        await model.waitForDuplicateSearchForSmoke()
        paths = indexedPaths(store, loc.id)
        check(paths[subName] != nil && model.excludedFiles.isEmpty, "duplicates: Include Again rescans and brings it back")
        guard let sub2 = paths[subName] else { return }

        // Protected copies: a user-installed one is kept and never checked; a file active outside Fontory neither.
        let installed = root.appendingPathComponent("Installed", isDirectory: true)
        let instLoc: LocationRecord
        do {
            try fm.createDirectory(at: installed, withIntermediateDirectories: true)
            try fm.copyItem(at: source, to: installed.appendingPathComponent("Arial.ttf"))
            let ref = try VolumeIdentity.ref(for: installed)
            instLoc = try store.upsertLocation(kind: .userInstalled, volumeUUID: ref.volumeUUID, relativePath: ref.relativePath,
                                               displayName: "Installed", lastKnownPath: installed.path)
        } catch {
            check(false, "duplicates: installed location", "\(error)"); return
        }
        await model.reloadLocations()
        model.rescan(instLoc.id)
        await model.waitForScansForSmoke()
        await model.waitForDuplicateSearchForSmoke()
        guard let inst = indexedPaths(store, instLoc.id)["Arial.ttf"] else { check(false, "duplicates: installed copy indexed"); return }
        await model.selectCopiesToRemove()
        check(model.checkedDuplicateFiles == [otf, ttf, sub2], "duplicates: a user-installed copy is the one kept",
              "\(model.checkedDuplicateFiles) installed \(inst)")
        model.setDuplicateChecked(inst, true)
        check(!model.checkedDuplicateFiles.contains(inst) && model.isProtectedDuplicate(inst), "duplicates: a user-installed copy cannot be checked")
        _ = try? store.setExternalActive(fileIDs: [otf], true)
        model.findDuplicates()
        await model.waitForDuplicateSearchForSmoke()
        check(model.isProtectedDuplicate(otf) && !model.checkedDuplicateFiles.contains(otf), "duplicates: a copy active outside Fontory is unchecked and locked")
        model.checkedDuplicateFiles = [inst, otf]  // forced past the UI
        check(model.checkedRemovableFiles.isEmpty, "duplicates: protected files are filtered out of the checked set")
        await model.removeCheckedFromLibrary()
        let forced = await model.trashFiles([inst, otf])
        model.alert = nil
        check(forced.recycled.isEmpty && forced.failures.count == 2 && indexedPaths(store, instLoc.id)["Arial.ttf"] == inst
              && indexedPaths(store, loc.id)["Arial.otf"] == otf && fm.fileExists(atPath: installed.appendingPathComponent("Arial.ttf").path)
              && fm.fileExists(atPath: fonts.appendingPathComponent("Arial.otf").path) && model.excludedFiles.isEmpty,
              "duplicates: protected rows are never removed or trashed", "\(forced.failures.map(\.message))")
        _ = try? store.setExternalActive(fileIDs: [otf], false)

        // Move to Trash: confirmed with count and size, deactivates first, recycles, deletes the row without exclusion.
        let sub2Face = (try? store.rows(ids: try store.faceIDs(for: LibraryQuery(scope: .location(id: loc.id, subfolder: nil), includeSystem: true))))?
            .values.first { $0.fileID == sub2 }?.id
        guard let sub2Face else { check(false, "duplicates: face of the subfolder copy"); return }
        let report = await backend.activation.set([sub2Face], to: .on, force: true)
        check(report.failures.isEmpty && (try? store.rows(ids: [sub2Face]))?[sub2Face]?.activation == .on, "duplicates: the copy to trash is active in Fontory")
        model.findDuplicates()
        await model.waitForDuplicateSearchForSmoke()
        model.checkedDuplicateFiles = [sub2]
        model.lastTrashResult = nil
        model.moveCheckedToTrash()
        let size = ByteCountFormatter.string(fromByteCount: model.duplicateFiles[sub2]?.size ?? -1, countStyle: .file)
        check(model.alert?.actionTitle == "Move to Trash" && model.alert?.isDestructive == true && model.alert?.title.contains("1 font file") == true
              && model.alert?.message.hasPrefix("1 file, \(size) in total.") == true && fm.fileExists(atPath: fonts.appendingPathComponent(subName).path),
              "duplicates: Move to Trash asks first with the file count and total size", model.alert?.message ?? "no alert")
        model.alert?.action?()
        model.alert = nil
        for _ in 0..<500 where model.lastTrashResult == nil { try? await Task.sleep(for: .milliseconds(20)) }
        let trashed = model.lastTrashResult
        let subPath = fonts.appendingPathComponent(subName).path
        let unregisteredFirst = registrar.unregistered.contains { $0.path.hasSuffix("Arial copy \(token).ttf") && $0.existed }
        check(trashed?.recycled == [sub2] && !fm.fileExists(atPath: subPath), "duplicates: Move to Trash recycles the file (gone from its path)",
              "\(String(describing: trashed?.failures))")
        check(unregisteredFirst, "duplicates: the active copy was deactivated before it was trashed", "\(registrar.unregistered)")
        check(indexedPaths(store, loc.id)[subName] == nil && model.excludedFiles.isEmpty, "duplicates: the trashed file leaves the index without an exclusion")
        check(trashed?.trashedURLs.map(\.path) == [smokeTrash.appendingPathComponent("Arial copy \(token).ttf").path]
              && fm.fileExists(atPath: smokeTrash.appendingPathComponent("Arial copy \(token).ttf").path),
              "duplicates: the file went to the smoke's own Trash folder (the user's Trash is never used)")

        // A recycle error is reported per file; the file and its row stay. The file was active, so it says it was deactivated.
        func faceOf(_ fileID: Int64) -> Int64? {
            (try? store.rows(ids: try store.faceIDs(for: LibraryQuery(scope: .location(id: loc.id, subfolder: nil), includeSystem: true))))?
                .values.first { $0.fileID == fileID }?.id
        }
        guard let paddedFace = faceOf(padded), let ttfFace2 = faceOf(ttf) else { check(false, "duplicates: faces of padded/ttf"); return }
        _ = await backend.activation.set([paddedFace], to: .on, force: true)
        let workingRecycler = model.recycleFile
        model.recycleFile = { _ in (nil, "Simulated recycle failure.") }
        let refused = await model.trashFiles([padded])
        model.recycleFile = workingRecycler
        check(refused.recycled.isEmpty && refused.failures.map(\.fileID) == [padded]
              && refused.failures.first?.message == "Simulated recycle failure. (it was deactivated)"
              && model.alert?.message.contains("Arial padded.ttf") == true && indexedPaths(store, loc.id)["Arial padded.ttf"] == padded
              && fm.fileExists(atPath: fonts.appendingPathComponent("Arial padded.ttf").path),
              "duplicates: a recycle error is reported per file and keeps the file and its row", model.alert?.message ?? "no alert")
        model.alert = nil

        // An already-missing file is reported per file and stays in the index; it is checked before deactivation, so
        // its active face stays on.
        _ = await backend.activation.set([ttfFace2], to: .on, force: true)
        try? fm.removeItem(at: fonts.appendingPathComponent("Arial.ttf"))
        let missing = await model.trashFiles([ttf])
        check(missing.recycled.isEmpty && missing.failures.map(\.fileID) == [ttf] && missing.failures.first?.message == "The file is missing."
              && model.alert?.message.contains("Arial.ttf") == true && indexedPaths(store, loc.id)["Arial.ttf"] == ttf,
              "duplicates: a missing file is reported per file", model.alert?.message ?? "no alert")
        check((try? store.rows(ids: [ttfFace2]))?[ttfFace2]?.activation == .on, "duplicates: a missing file is not deactivated")
        model.alert = nil

        // The watcher's rescan deleting a trashed row first (simulated in the recycler) is not counted twice.
        let paddedTag = await model.createTag(name: "Dup Padded", parentID: nil)
        if let paddedTag { await model.setTag(paddedTag, onFaces: [paddedFace], included: true) }
        await model.waitForDuplicateSearchForSmoke()
        let noticesBefore = model.removalNotices[loc.id] ?? 0
        model.recycleFile = { url in
            let result = await workingRecycler(url)
            _ = try? store.deleteFiles([padded])  // the watcher's scan, which counts its own notice
            return result
        }
        let raced = await model.trashFiles([padded])
        model.recycleFile = workingRecycler
        check(paddedTag != nil && raced.recycled == [padded] && indexedPaths(store, loc.id)["Arial padded.ttf"] == nil
              && (model.removalNotices[loc.id] ?? 0) == noticesBefore,
              "duplicates: a row the rescan already deleted is not counted again", "\(noticesBefore) -> \(String(describing: model.removalNotices[loc.id]))")
        model.alert = nil

        // Adding files individually: "Skip duplicates on import" applies, and re-adding an excluded file includes it again.
        let loose = root.appendingPathComponent("Loose", isDirectory: true)
        let looseFile = loose.appendingPathComponent("Arial loose.ttf")
        try? fm.createDirectory(at: loose, withIntermediateDirectories: true)
        try? fm.copyItem(at: source, to: looseFile)
        model.skipDuplicatesOnImport = true
        await model.addFiles(urls: [looseFile])
        let looseLoc = model.locations.first { $0.kind == .fileSet && $0.lastKnownPath.hasSuffix("/Loose") }
        if let looseLoc {
            check(model.scanProgress[looseLoc.id]?.skippedDuplicates == 1 && indexedPaths(store, looseLoc.id).isEmpty,
                  "duplicates: adding a file skips a duplicate when the setting is on", "\(String(describing: model.scanProgress[looseLoc.id]))")
            model.skipDuplicatesOnImport = false
            await model.addFiles(urls: [looseFile])
            let looseID = indexedPaths(store, looseLoc.id)["Arial loose.ttf"]
            check(looseID != nil && model.scanProgress[looseLoc.id]?.skippedDuplicates == 0, "duplicates: with the setting off, the file is added")
            if let looseID {
                // No tags or notes: Remove from Library goes ahead without asking.
                await model.waitForDuplicateSearchForSmoke()  // the file's rows, as the view lists them
                model.alert = nil
                await model.removeFromLibrary([looseID], confirmed: false)
                check(model.alert == nil && indexedPaths(store, looseLoc.id).isEmpty
                      && model.excludedFiles.contains(ExcludedFile(locationID: looseLoc.id, relativePath: "Arial loose.ttf")),
                      "duplicates: Remove from Library without tags or notes needs no confirmation", model.alert?.message ?? "")
                await model.addFiles(urls: [looseFile])
                check(indexedPaths(store, looseLoc.id)["Arial loose.ttf"] != nil
                      && !model.excludedFiles.contains(ExcludedFile(locationID: looseLoc.id, relativePath: "Arial loose.ttf")),
                      "duplicates: adding an excluded file again includes it", "\(model.excludedFiles)")
            }
        } else {
            check(false, "duplicates: file-set location for added files", model.alert?.message ?? "")
        }
        model.skipDuplicatesOnImport = false

        // Settings: skip duplicates on import (scanner and suite), location rank (suite), nothing in the user's defaults.
        model.skipDuplicatesOnImport = true
        try? await Task.sleep(for: .milliseconds(100))
        let more = root.appendingPathComponent("More", isDirectory: true)
        try? fm.createDirectory(at: more, withIntermediateDirectories: true)
        try? fm.copyItem(at: source, to: more.appendingPathComponent("Arial more.ttf"))
        if let moreLoc = await model.runBackground({ try backend.addFolder(more) }) {
            await model.reloadLocations()
            model.rescan(moreLoc.id)
            await model.waitForScansForSmoke()
            check(model.scanProgress[moreLoc.id]?.skippedDuplicates == 1 && indexedPaths(store, moreLoc.id).isEmpty && suite.bool(forKey: SettingsKey.skipDuplicatesOnImport),
                  "duplicates: Skip duplicates on import skips the copy and reports it", "\(String(describing: model.scanProgress[moreLoc.id]))")
            model.duplicateLocationRank = [moreLoc.id, loc.id]
            let stored = (suite.array(forKey: SettingsKey.duplicateLocationRank) as? [NSNumber])?.map(\.int64Value)
            check(stored == [moreLoc.id, loc.id] && Array(model.effectiveLocationRank.prefix(2)) == [moreLoc.id, loc.id],
                  "duplicates: location rank persisted as ids", "\(String(describing: stored))")
            model.moveLocationRank(from: [0], to: 2)
            check(Array(model.duplicateLocationRank.prefix(2)) == [loc.id, moreLoc.id], "duplicates: reordering the rank")
        } else {
            check(false, "duplicates: add More", model.alert?.message ?? "")
        }
        model.skipDuplicatesOnImport = false

        // Leaving the view, quitting, and the user's defaults.
        model.applySidebarSelection([.scope(.all)], modifiers: [])
        check(!model.isShowingDuplicates && model.filtersAvailable, "duplicates: another sidebar row shows the browser again (Filters available)")
        model.preview.text = "smoke"
        model.flushPreviewSave()
        await model.stopDuplicateSearch()
        let stopped = model.duplicateRuns
        model.findDuplicates()
        check(model.duplicateRuns == stopped && model.duplicateTask == nil, "duplicates: no search after quit")
        let standardAfter = ["previewSettings", SettingsKey.duplicateLocationRank, SettingsKey.skipDuplicatesOnImport]
            .map { String(describing: UserDefaults.standard.object(forKey: $0)) }
        check(standardAfter == standardBefore, "duplicates: nothing written to the user's defaults")
    }

    // MARK: Wave 3b task 8: Family Editor

    /// Polls (on the main actor) until `condition` holds or 3 s pass.
    private static func eventually(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<300 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    /// A fresh temporary library with the three seeded faces: rename, undo, merge, split, original names, clashes,
    /// search, the edited mark, the family page following a rename, and the ⌘Z routing rule.
    private static func familyEditorSteps() async {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("FontoryFamilySmoke-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: dir) }
        let backend: LibraryBackend
        let faces: [String: Int64]
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            backend = try LibraryBackend(databaseURL: dir.appendingPathComponent("library.sqlite"))
            faces = try seed(backend.store, folder: dir)
        } catch {
            check(false, "family: setup", "\(error)"); return
        }
        guard let serif = faces["Smoke Serif"], let sans = faces["Smoke Sans"], let mono = faces["Smoke Mono"] else {
            check(false, "family: seed", "\(faces)"); return
        }
        let store = backend.store
        let model = AppModel()
        await model.attachBackendForSmoke(backend)
        func families() -> [String: Set<Int64>] {
            Dictionary(((try? store.families(for: LibraryQuery())) ?? []).map { ($0.name, Set($0.faceIDs)) },
                       uniquingKeysWith: { $0.union($1) })
        }
        // The browser's own refresh (scheduled by the edit) may supersede a smoke refresh: wait for the face.
        func gridName(_ id: Int64) async -> String? {
            await model.refreshNowForSmoke()
            _ = await eventually { model.faceIDs.contains(id) }
            return model.faceIDs.contains(id) ? model.row(id)?.family : nil
        }
        check(!model.canUndoFamilyEdit, "family: nothing to undo at first")

        // Rename.
        await model.renameFamily(faceIDs: [serif], to: "Smoke Book")
        let renamed = await gridName(serif)
        check(renamed == "Smoke Book", "family: renaming Smoke Serif to Smoke Book shows Smoke Book in the grid", renamed ?? "nil")
        check(model.canUndoFamilyEdit, "family: the rename can be undone")
        check(model.editedFamilies["smoke book"] == ["Smoke Serif"], "family: the edited mark lists the original name",
              "\(model.editedFamilies)")
        check(AppModel.editedTooltip(["Smoke Serif"]) == "Original: Smoke Serif", "family: the edited mark's tooltip copy")

        // Search finds the custom name.
        model.searchText = "Smoke Book"
        await model.refreshNowForSmoke()
        check(model.faceIDs == [serif], "family: search Smoke Book finds the renamed face", "\(model.faceIDs)")
        model.searchText = ""
        await model.refreshNowForSmoke()

        // Undo.
        await model.undoLastFamilyEdit()
        let undone = await gridName(serif)
        check(undone == "Smoke Serif", "family: undo puts back Smoke Serif", undone ?? "nil")
        check(!model.canUndoFamilyEdit && model.editedFamilies.isEmpty, "family: one level of undo, no edited mark left")

        // A no-op rename (same name again) keeps the real undo.
        await model.renameFamily(faceIDs: [serif], to: "Smoke Book")
        await model.renameFamily(faceIDs: [serif], to: "Smoke Book")
        check(model.canUndoFamilyEdit, "family: a no-op rename keeps the undo")
        await model.undoLastFamilyEdit()
        let undoneAfterNoOp = await gridName(serif)
        check(undoneAfterNoOp == "Smoke Serif", "family: undo after a no-op rename still restores the first edit", undoneAfterNoOp ?? "nil")

        // Merge.
        await model.mergeFamilies(["smoke serif", "smoke sans"], into: "Smoke")
        var g = families()
        check(g["Smoke"] == [serif, sans] && g.count == 2, "family: merging Serif + Sans into Smoke makes one family of 2", "\(g)")
        check(model.editedFamilies["smoke"] == ["Smoke Sans", "Smoke Serif"], "family: the merged family lists both originals",
              "\(model.editedFamilies)")

        // Split.
        await model.moveToNewFamily(faceIDs: [sans], name: "Smoke Solo")
        g = families()
        check(g["Smoke"] == [serif] && g["Smoke Solo"] == [sans] && g.count == 3, "family: moving one face to Smoke Solo makes two families", "\(g)")

        // Use Original Names, per family.
        await model.useOriginalNames(faceIDs: [serif])
        await model.useOriginalNames(faceIDs: [sans])
        g = families()
        check(g == ["Smoke Serif": [serif], "Smoke Sans": [sans], "Smoke Mono": [mono]], "family: Use Original Names gives three families again", "\(g)")
        check(customFamily(store, serif) == nil && customFamily(store, sans) == nil, "family: no override is left")
        await model.undoLastFamilyEdit()
        check(families()["Smoke Solo"] == [sans], "family: undo after Use Original Names puts the name back", "\(families())")
        await model.useOriginalNames(faceIDs: [sans])

        // Clash with an existing family that differs only in case.
        let clash = await model.familyClash(name: "smoke mono", excluding: [serif])
        let noClash = await model.familyClash(name: "Smoke Other", excluding: [serif])
        let ownName = await model.familyClash(name: "SMOKE SERIF", excluding: [serif])
        check(clash && !noClash && !ownName, "family: a clash with Smoke Mono (typed smoke mono) is reported, case-insensitively",
              "clash \(clash) other \(noClash) own \(ownName)")
        check(AppModel.clashWarning("Smoke Mono") == "A family named Smoke Mono already exists. Its fonts and these will show as one family.",
              "family: the clash warning copy")
        check(AppModel.familyEditorNote == "Names change only in Fontory. Other apps still show the original names.",
              "family: the editor note copy")
        await model.renameFamily(faceIDs: [serif], to: "smoke mono")
        g = families()
        check(customFamily(store, mono) == nil && g.count == 2 && g.values.contains([serif, mono]),
              "family: renaming into Smoke Mono groups them and leaves Mono's rows untouched", "\(g)")
        await model.undoLastFamilyEdit()

        // The family page follows a rename; a split keeps it on the old family.
        model.openFamilyDetail(faceID: serif)
        _ = await eventually { model.detail?.family == "Smoke Serif" }
        await model.renameFamily(faceIDs: [serif], to: "Smoke Book")
        let followed = await eventually { model.detail?.family == "Smoke Book" && model.detail?.faceIDs == [serif] }
        check(followed, "family: the open family page re-opens under the new name", "\(String(describing: model.detail))")
        await model.mergeFamilies(["smoke book", "smoke sans"], into: "Smoke Book")
        let merged = await eventually { model.detail?.faceIDs.count == 2 }
        check(merged, "family: the open family page shows the merged styles", "\(String(describing: model.detail))")
        await model.moveToNewFamily(faceIDs: [sans], name: "Smoke Solo")
        let stayed = await eventually { model.detail?.family == "Smoke Book" && model.detail?.faceIDs == [serif] }
        check(stayed, "family: after Move to New Family the page stays on the old family", "\(String(describing: model.detail))")
        await model.useOriginalNames(faceIDs: [serif, sans])
        let original = await eventually { model.detail?.family == "Smoke Serif" }
        check(original, "family: Use Original Names re-opens the page under the original name", "\(String(describing: model.detail))")
        model.closeFamilyDetail()

        // ⌘Z routing: only ⌘Z in the key browser with no text being edited and an edit to undo.
        let rule = AppModel.handlesFamilyUndoKey
        check(rule(true, true, false, true) && !rule(false, true, false, true) && !rule(true, false, false, true)
              && !rule(true, true, true, true) && !rule(true, true, false, false),
              "family: ⌘Z undoes a family edit only in the key browser, outside text fields, when there is one")
        check(model.alert == nil, "family: no alert", model.alert?.message ?? "")
    }

    // MARK: Wave 3b task 5: Backups

    private static func customFamily(_ store: FontStore, _ faceID: Int64) -> String? {
        (try? store.database.withLock { () -> String? in
            let s = try store.database.prepare("SELECT custom_family FROM faces WHERE id = ?")
            defer { s.reset() }
            try s.bind([.int(faceID)])
            return try s.step() && !s.isNull(0) ? s.text(0) : nil
        }) ?? nil
    }

    private static func directTagNames(_ store: FontStore, _ faceID: Int64) -> Set<String> {
        let tags = (try? store.tags()) ?? []
        let ids = (try? store.tagIDs(forFaces: [faceID]))?[faceID] ?? []
        return Set(tags.filter { ids.contains($0.id) }.map(\.name))
    }

    /// A temporary library (smoke registrar, its own settings suite and backup folder) with three real fonts in two
    /// folders: automatic backups, a manual backup, restore (corrupt file, full restore, Cancel, quit).
    private static func backupSteps() async {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("FontoryBackupSmoke-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: root) }
        let suiteName = "local.fontory.smoke.backup.\(UUID().uuidString)"
        guard let suite = UserDefaults(suiteName: suiteName) else { check(false, "backup: settings suite"); return }
        defer { suite.removePersistentDomain(forName: suiteName) }
        let keys = ["previewSettings", SettingsKey.duplicateLocationRank, SettingsKey.skipDuplicatesOnImport]
        let standardBefore = keys.map { String(describing: UserDefaults.standard.object(forKey: $0)) }

        let fonts = root.appendingPathComponent("Fonts", isDirectory: true)
        let extra = root.appendingPathComponent("Extra", isDirectory: true)
        let supplemental = URL(fileURLWithPath: "/System/Library/Fonts/Supplemental", isDirectory: true)
        let backend: LibraryBackend
        do {
            try fm.createDirectory(at: fonts, withIntermediateDirectories: true)
            try fm.createDirectory(at: extra, withIntermediateDirectories: true)
            for name in ["Arial.ttf", "Georgia.ttf"] {
                try fm.copyItem(at: supplemental.appendingPathComponent(name), to: fonts.appendingPathComponent(name))
            }
            try fm.copyItem(at: supplemental.appendingPathComponent("Courier New.ttf"), to: extra.appendingPathComponent("Courier New.ttf"))
            backend = try LibraryBackend(databaseURL: root.appendingPathComponent("library.sqlite"), registrar: SmokeRegistrar())
        } catch {
            check(false, "backup: setup", "\(error)"); return
        }
        let store = backend.store
        let model = AppModel()
        model.settingsDefaults = suite
        model.suppressesPreviewSaveForSmoke = true
        model.backupDirectory = root.appendingPathComponent("Backups", isDirectory: true)
        await model.attachBackendForSmoke(backend)
        check(model.backupDirectory.path.hasPrefix(root.path), "backup: the smoke's backups go to its temp folder")

        guard let fontsLoc = await model.runBackground({ try backend.addFolder(fonts) }),
              let extraLoc = await model.runBackground({ try backend.addFolder(extra) }) else {
            check(false, "backup: add the folders", model.alert?.message ?? ""); return
        }
        await model.reloadLocations()
        model.rescan(fontsLoc.id)
        model.rescan(extraLoc.id)
        await model.waitForScansForSmoke()
        let allIDs = (try? store.faceIDs(for: LibraryQuery(includeSystem: true))) ?? []
        let byName = Dictionary(((try? store.rows(ids: allIDs)) ?? [:]).values.map { ($0.postScriptName, $0.id) }, uniquingKeysWith: { a, _ in a })
        guard let arial = byName["ArialMT"], let georgia = byName["Georgia"], let courier = byName["CourierNewPSMT"] else {
            check(false, "backup: faces indexed", "\(byName.keys.sorted())"); return
        }

        // Automatic backups: today's file, overwritten by the next run; retention prunes old ones only.
        let files = BackupFiles(directory: model.backupDirectory)
        let today = files.dailyURL(for: Date())
        await model.writeAutomaticBackup()
        var listed = files.list()
        check(listed.count == 1 && listed.first?.url.lastPathComponent == today.lastPathComponent && listed.first?.isSafety == false,
              "backup: an automatic backup writes today's file", "\(listed.map(\.url.lastPathComponent))")
        guard let keep = await model.createTag(name: "Smoke Keep", parentID: nil) else { check(false, "backup: create tag"); return }
        await model.setTag(keep, onFaces: [arial], included: true)
        let old = model.backupDirectory.appendingPathComponent("Fontory 2000-01-01.fontorybackup")
        let other = model.backupDirectory.appendingPathComponent("notes.txt")
        try? Data("old".utf8).write(to: old)
        try? Data("keep".utf8).write(to: other)
        await model.writeAutomaticBackup()
        listed = files.list()
        let everything = (try? fm.contentsOfDirectory(atPath: model.backupDirectory.path)) ?? []
        let todayTags = (try? BackupArchive.read(today))?.tags.map(\.name) ?? []
        check(listed.count == 1 && Set(everything) == [today.lastPathComponent, "notes.txt"] && todayTags == ["Smoke Keep"],
              "backup: a second automatic backup overwrites today's file (still one file), prunes old ones, leaves other files",
              "\(everything) tags \(todayTags)")
        // The quit backup's budget: a fast write returns at once; slow work is cut off at the budget.
        let clock = ContinuousClock()
        let fast = await clock.measure { await model.writeAutomaticBackup(within: .seconds(3)) }
        check(fast < .seconds(1), "backup: a fast quit backup returns well under its 3 s budget", "\(fast)")
        var inTime = true
        let slow = await clock.measure {
            inTime = await awaitAtMost(.milliseconds(200), Task { try? await Task.sleep(for: .seconds(2)) })
        }
        check(!inTime && slow < .seconds(1), "backup: awaitAtMost stops waiting at the budget", "\(slow)")
        check(model.backupEntries.map(\.url.lastPathComponent) == [today.lastPathComponent], "backup: backupEntries refreshed after a write",
              "\(model.backupEntries.map(\.url.lastPathComponent))")

        // User data: tag (above), note, Quick Collection, custom family, activation, location rank.
        model.editNote("Backup note", faceID: arial)
        await model.flushNotes()
        await model.setQuickCollection([georgia, courier], included: true)
        _ = await model.runBackground { try store.setCustomFamily("Smoke Family", faceIDs: [georgia]) }
        _ = await backend.activation.set([arial], to: .on, force: true)
        model.duplicateLocationRank = [extraLoc.id, fontsLoc.id]
        let manual = root.appendingPathComponent("Manual.fontorybackup")
        do {
            try await model.backUp(to: manual)
        } catch {
            check(false, "backup: Back Up Now", "\(error)")
        }
        let manifest = try? BackupArchive.read(manual)
        check(manifest?.faces.count == 3 && manifest?.tags.map(\.name) == ["Smoke Keep"], "backup: Back Up Now writes the chosen file",
              "\(String(describing: manifest?.faces.map(\.postScriptName)))")

        // Clear everything.
        _ = await model.runBackground {
            try store.deleteTag(keep)
            try store.setNote(nil, faceID: arial)
            try store.clearQuickCollection()
            try store.clearCustomFamilies(faceIDs: [georgia])
        }
        _ = await backend.activation.set([arial], to: .off, force: true)
        _ = await backend.activation.set([courier], to: .on, force: true)
        model.duplicateLocationRank = []
        await model.afterTagChange()
        await model.loadQuickCollection()
        check((try? store.tags())?.isEmpty == true && customFamily(store, georgia) == nil && model.quickCollectionIDs.isEmpty,
              "backup: the library is cleared before the restore")

        // A corrupt file: .failed, no safety backup, nothing changed.
        let corrupt = root.appendingPathComponent("Corrupt.fontorybackup")
        try? Data("this is not a zip".utf8).write(to: corrupt)
        let entriesBefore = files.list()
        await model.beginRestore(from: corrupt, restoreActivation: true)
        var failed = false
        if case .failed = model.restoreState { failed = true }
        check(failed && files.list() == entriesBefore && (try? store.tags())?.isEmpty == true
              && (try? store.rows(ids: [courier]))?[courier]?.activation == .on,
              "backup: restoring a corrupt file fails, writes no safety backup and changes nothing", "\(String(describing: model.restoreState))")
        model.dismissRestore()
        check(model.restoreState == nil, "backup: dismissing the failure closes the sheet")

        // Full restore, with activation. A family edit made first must not stay undoable afterwards.
        await model.renameFamily(faceIDs: [courier], to: "Smoke Undo Probe")
        check(model.canUndoFamilyEdit, "backup: a family edit is undoable before the restore")
        await model.beginRestore(from: manual, restoreActivation: true)
        check(!model.canUndoFamilyEdit && model.familyNameRequest == nil, "backup: a restore clears the family undo")
        guard case .finished(let result) = model.restoreState else {
            check(false, "backup: restore finishes", "\(String(describing: model.restoreState))"); return
        }
        check(result.tagCount == 1 && result.restoredFaceCount == 3 && result.notFound.isEmpty,
              "backup: the summary counts 1 tag and 3 fonts", "\(result)")
        let rows = (try? store.rows(ids: [arial, courier])) ?? [:]
        check(directTagNames(store, arial) == ["Smoke Keep"] && model.tags.map(\.name) == ["Smoke Keep"],
              "backup: the tag survives a restore", "\(directTagNames(store, arial))")
        let info = await model.faceInfo(arial)
        check(info?.note == "Backup note" && model.note(for: arial, stored: info?.note) == "Backup note", "backup: the note survives a restore")
        check(model.quickCollectionIDs == [georgia, courier] && (try? store.quickCollectionFaceIDs()) == [georgia, courier], "backup: the Quick Collection survives a restore")
        check(customFamily(store, georgia) == "Smoke Family", "backup: the custom family survives a restore")
        check(rows[arial]?.activation == .on && rows[courier]?.activation == .off,
              "backup: Also restore activation activates saved faces and deactivates the others",
              "arial \(String(describing: rows[arial]?.activation)) courier \(String(describing: rows[courier]?.activation))")
        let storedRank = (suite.array(forKey: SettingsKey.duplicateLocationRank) as? [NSNumber])?.map(\.int64Value)
        check(model.duplicateLocationRank == [extraLoc.id, fontsLoc.id] && storedRank == [extraLoc.id, fontsLoc.id],
              "backup: the location rank is restored (in the smoke's own settings)", "\(model.duplicateLocationRank)")
        let safety = model.backupEntries.filter(\.isSafety)
        check(safety.count == 1 && (try? BackupArchive.read(safety[0].url))?.tags.isEmpty == true,
              "backup: a safety backup of the library before the restore is listed", "\(model.backupEntries.map(\.url.lastPathComponent))")
        model.dismissRestore()

        // Cancel during scanning: the missing Extra folder is re-added and stays; nothing is applied.
        guard let keepAgain = (try? store.tags())?.first(where: { $0.name == "Smoke Keep" })?.id else {
            check(false, "backup: the restored tag before Cancel"); return
        }
        _ = await model.runBackground {
            try store.deleteLocation(extraLoc.id)
            try store.deleteTag(keepAgain)
        }
        await model.reloadLocations()
        model.holdsRestoreScanForSmoke = true
        let restore = Task { await model.beginRestore(from: manual, restoreActivation: false) }
        var sawScanning = false
        for _ in 0..<500 {
            if case .scanning = model.restoreState { sawScanning = true; break }
            try? await Task.sleep(for: .milliseconds(10))
        }
        model.cancelRestore()
        await restore.value
        model.holdsRestoreScanForSmoke = false
        await model.waitForScansForSmoke()
        let readded = model.locations.first { $0.lastKnownPath == extra.standardizedFileURL.path || $0.displayName == "Extra" }
        check(sawScanning && model.restoreState == nil && (try? store.tags())?.isEmpty == true && (try? store.quickCollectionFaceIDs()) == [georgia],
              "backup: Cancel during scanning applies nothing", "\(String(describing: model.restoreState))")
        check(readded != nil, "backup: a location re-added before Cancel stays in the library")
        check(model.backupEntries.filter(\.isSafety).count == 2, "backup: each restore writes its own safety backup",
              "\(model.backupEntries.map(\.url.lastPathComponent))")

        // A missing folder that is reachable is re-added and scanned before the data is applied.
        if let readded { _ = await model.runBackground { try store.deleteLocation(readded.id) } }
        await model.reloadLocations()
        await model.beginRestore(from: manual, restoreActivation: false)
        let extraAgain = model.locations.first { $0.displayName == "Extra" }
        let courierAgain = extraAgain.flatMap { indexedPaths(store, $0.id)["Courier New.ttf"] }
            .flatMap { fileID in (try? store.rows(ids: (try? store.faceIDs(for: LibraryQuery(includeSystem: true))) ?? []))?.values.first { $0.fileID == fileID }?.id }
        if case .finished(let r) = model.restoreState {
            check(r.restoredFaceCount == 3 && r.unreachableLocations.isEmpty && courierAgain.map { model.quickCollectionIDs.contains($0) } == true,
                  "backup: a removed reachable folder is re-added and scanned, and its fonts get their data back", "\(r)")
        } else {
            check(false, "backup: restore with a re-added folder", "\(String(describing: model.restoreState))")
        }
        model.dismissRestore()

        // Quitting cancels a running restore and writes today's backup.
        if let extraAgain { _ = await model.runBackground { try store.deleteLocation(extraAgain.id) } }
        guard let keepThird = (try? store.tags())?.first(where: { $0.name == "Smoke Keep" })?.id else {
            check(false, "backup: the restored tag before quitting"); return
        }
        _ = await model.runBackground { try store.deleteTag(keepThird) }
        await model.reloadLocations()
        model.holdsRestoreScanForSmoke = true
        let quitting = Task { await model.beginRestore(from: manual, restoreActivation: false) }
        for _ in 0..<500 {
            if case .scanning = model.restoreState { break }
            try? await Task.sleep(for: .milliseconds(10))
        }
        await model.prepareForQuit()
        await quitting.value
        model.holdsRestoreScanForSmoke = false
        check(model.restoreState == nil && (try? store.tags())?.isEmpty == true && (try? BackupArchive.read(today))?.tags.isEmpty == true,
              "backup: quitting cancels the restore and writes today's backup")

        let standardAfter = keys.map { String(describing: UserDefaults.standard.object(forKey: $0)) }
        check(standardAfter == standardBefore, "backup: nothing written to the user's defaults")
    }

    // MARK: Wave 3C task 5: Layouts window

    /// A fresh AppModel whose LayoutsModel uses temporary Layouts/Templates folders (set at init, before anything
    /// installs or writes): built-in templates, New Layout naming, edit → dirty → autosave, undo/redo, the render,
    /// font resolution, rename/duplicate, delete through a fake recycler, and the quit flush.
    private static func layoutsSteps() async {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("FontoryLayoutsSmoke-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: root) }
        let suiteName = "local.fontory.smoke.layouts.\(UUID().uuidString)"
        guard let suite = UserDefaults(suiteName: suiteName) else { check(false, "layouts: settings suite"); return }
        defer { suite.removePersistentDomain(forName: suiteName) }
        func standardSnapshot() -> [String] {
            let all = UserDefaults.standard.dictionaryRepresentation()
            return all.keys.filter { $0.localizedCaseInsensitiveContains("layout") || $0.hasPrefix("zoom") || $0 == "previewSettings" }
                .sorted().map { "\($0)=\(String(describing: all[$0]))" }
        }
        let standardBefore = standardSnapshot()
        // The real folders are only looked at (their dates), never written.
        let realBase = (try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: false))?
            .appendingPathComponent("Fontory", isDirectory: true)
        func realDates() -> [String] {
            guard let realBase else { return [] }
            return ["Layouts", "Templates"].map { name in
                let date = (try? fm.attributesOfItem(atPath: realBase.appendingPathComponent(name).path))?[.modificationDate]
                return "\(name)=\(String(describing: date))"
            }
        }
        let realBefore = realDates()

        let fonts = root.appendingPathComponent("Fonts", isDirectory: true)
        let backend: LibraryBackend
        do {
            try fm.createDirectory(at: fonts, withIntermediateDirectories: true)
            try fm.copyItem(at: URL(fileURLWithPath: "/System/Library/Fonts/Supplemental/Georgia Italic.ttf"),
                            to: fonts.appendingPathComponent("Georgia Italic.ttf"))
            // Latin-only (no Vietnamese stacked marks such as ế, ệ): for the missing-characters note.
            try fm.copyItem(at: URL(fileURLWithPath: "/System/Library/Fonts/Supplemental/Hoefler Text.ttc"),
                            to: fonts.appendingPathComponent("Hoefler Text.ttc"))
            // One family of three styles, for the Pairing Studio (⌘K, cycling).
            for name in ["Trebuchet MS.ttf", "Trebuchet MS Bold.ttf", "Trebuchet MS Italic.ttf"] {
                try fm.copyItem(at: URL(fileURLWithPath: "/System/Library/Fonts/Supplemental/\(name)"),
                                to: fonts.appendingPathComponent(name))
            }
            backend = try LibraryBackend(databaseURL: root.appendingPathComponent("library.sqlite"), registrar: SmokeRegistrar())
        } catch {
            check(false, "layouts: setup", "\(error)"); return
        }
        let model = AppModel(layoutsDirectory: root.appendingPathComponent("Layouts", isDirectory: true),
                             templatesDirectory: root.appendingPathComponent("Templates", isDirectory: true))
        model.settingsDefaults = suite
        model.suppressesPreviewSaveForSmoke = true
        model.backupDirectory = root.appendingPathComponent("Backups", isDirectory: true)
        let layouts = model.layouts
        check(layouts.layoutsDirectory.path.hasPrefix(root.path) && layouts.templatesDirectory.path.hasPrefix(root.path),
              "layouts: the smoke's layouts and templates live in its temp folder")
        var recycled: [URL] = []
        let trash = root.appendingPathComponent("FakeTrash", isDirectory: true)
        layouts.recycle = { url in
            recycled.append(url)
            do {
                try fm.createDirectory(at: trash, withIntermediateDirectories: true)
                var dest = trash.appendingPathComponent(url.lastPathComponent)
                if fm.fileExists(atPath: dest.path) {
                    dest = trash.appendingPathComponent("\(UUID().uuidString) \(url.lastPathComponent)")
                }
                try fm.moveItem(at: url, to: dest)
                return (dest, nil)
            } catch {
                return (nil, error.localizedDescription)
            }
        }
        await model.attachBackendForSmoke(backend)
        guard let loc = await model.runBackground({ try backend.addFolder(fonts) }) else {
            check(false, "layouts: add the font folder", model.alert?.message ?? ""); return
        }
        await model.reloadLocations()
        model.rescan(loc.id)
        await model.waitForScansForSmoke()

        // Templates.
        await layouts.installBuiltInTemplates()
        let templateFiles = ((try? fm.contentsOfDirectory(atPath: layouts.templatesDirectory.path)) ?? []).filter { !$0.hasPrefix(".") }
        check(templateFiles.count == 10 && layouts.templates.count == 10 && layouts.templates.first?.name == "Poster"
              && layouts.templates.allSatisfy(\.isBuiltIn),
              "layouts: the built-in templates are installed into the temp folder, Poster first",
              "\(templateFiles.sorted()) / \(layouts.templates.map(\.name))")
        guard let poster = layouts.templates.first(where: { $0.name == "Poster" }) else { return }

        // New Layout naming.
        await layouts.newLayout(from: poster.url)
        let first = layouts.currentURL
        await layouts.newLayout(from: poster.url)
        let second = layouts.currentURL
        check(first?.lastPathComponent == "Poster.json" && second?.lastPathComponent == "Poster 2.json"
              && layouts.items.map(\.name) == ["Poster", "Poster 2"] && layouts.current?.name == "Poster 2",
              "layouts: New Layout from Poster makes Poster.json, then Poster 2.json",
              "\(String(describing: first?.lastPathComponent)), \(String(describing: second?.lastPathComponent)), \(layouts.items.map(\.name))")

        // Render.
        let rendered = await eventually(within: .seconds(2)) { layouts.renderedImage != nil }
        check(rendered, "layouts: the page renders within 2 s")
        if let doc = layouts.current, rendered {
            let georgia = doc.blocks.first { $0.font.postScriptName == "Georgia-Italic" }
            let helvetica = doc.blocks.first { $0.font.postScriptName == "HelveticaNeue-Bold" }
            check(georgia.map { !layouts.report.missingFontBlockIDs.contains($0.id.uuidString) } == true
                  && helvetica.map { layouts.report.missingFontBlockIDs.contains($0.id.uuidString) } == true,
                  "layouts: an indexed font resolves; a font not in the library is reported missing",
                  "\(layouts.report.missingFontBlockIDs)")
        }

        // Edit, dirty, autosave.
        guard let url = layouts.currentURL, let original = layouts.current?.blocks.first?.text else {
            check(false, "layouts: a layout is open"); return
        }
        let imageBefore = layouts.renderedImage
        layouts.apply { $0.blocks[0].text = "Smoke headline" }
        check(layouts.isDirty, "layouts: an edit marks the layout dirty")
        let saved = await eventually(within: .seconds(3)) {
            !layouts.isDirty && ((try? String(contentsOf: url, encoding: .utf8))?.contains("Smoke headline") ?? false)
        }
        check(saved, "layouts: the autosave writes the edit about 1 s later")
        check(await eventually(within: .seconds(2)) { layouts.renderedImage != nil && layouts.renderedImage !== imageBefore },
              "layouts: an edit re-renders the page")

        // Undo / redo.
        layouts.undo()
        check(layouts.current?.blocks.first?.text == original && layouts.isDirty, "layouts: undo restores the text")
        layouts.redo()
        check(layouts.current?.blocks.first?.text == "Smoke headline", "layouts: redo applies it again")
        layouts.undo()
        check(layouts.canRedo, "layouts: redo is available after undo")
        layouts.apply { $0.blocks[0].text = "Another" }
        check(!layouts.canRedo, "layouts: a new edit clears redo")
        layouts.apply({ $0.showMissing = false }, undoable: false)
        layouts.undo()
        check(layouts.current?.blocks.first?.text != "Another" && layouts.current?.showMissing == false,
              "layouts: a non-undoable change is kept and not an undo step")

        // Zoom.
        layouts.zoomIn()
        check(!layouts.zoomsToFit && layouts.effectiveZoom > layouts.fitZoom, "layouts: zoom in leaves fit")
        layouts.zoomToFit()
        check(layouts.zoomsToFit && layouts.effectiveZoom == layouts.fitZoom, "layouts: zoom to fit")

        // Rapid edits (a drag, key repeats): at most one render runs, one more follows with the latest state.
        await layouts.waitForRenderForSmoke()
        let textBeforeRapid = layouts.current?.blocks.first?.text ?? ""
        let startsBefore = layouts.renderStartCount
        for i in 0..<20 { layouts.apply({ $0.blocks[0].text = "Rapid edit \(i)" }, undoable: false) }
        await layouts.waitForRenderForSmoke()
        let starts = layouts.renderStartCount - startsBefore
        check(starts >= 1 && starts <= 3, "layouts: 20 rapid edits start at most 3 renders", "\(starts)")
        if let doc = layouts.current, let shown = layouts.renderedImage {
            let expected = LayoutRenderer.renderImage(doc, fonts: layouts.resolved, scale: layouts.renderedScale).image
            let same = expected.map { imageBytes($0) == imageBytes(shown) } ?? false
            check(doc.blocks.first?.text == "Rapid edit 19" && same, "layouts: after rapid edits the page shows the last edit")
        } else {
            check(false, "layouts: after rapid edits the page shows the last edit", "no image")
        }
        layouts.apply({ $0.blocks[0].text = textBeforeRapid }, undoable: false)

        await layoutEditingSteps(layouts, store: backend.store)

        // Rename, duplicate.
        await layouts.rename(url, to: "Renamed")
        let renamed = layouts.layoutsDirectory.appendingPathComponent("Renamed.json")
        check(layouts.currentURL == renamed && fm.fileExists(atPath: renamed.path) && !fm.fileExists(atPath: url.path)
              && layouts.current?.name == "Renamed" && layouts.items.map(\.name).contains("Renamed"),
              "layouts: rename moves the open layout's file", "\(layouts.items.map(\.name))")
        await layouts.flush()
        check((try? LayoutLibrary(layoutsDirectory: layouts.layoutsDirectory, templatesDirectory: layouts.templatesDirectory)
                .load(renamed))?.blocks.first?.text == layouts.current?.blocks.first?.text,
              "layouts: the renamed file holds the latest edits")
        await layouts.duplicate(renamed)
        check(layouts.items.map(\.name).contains("Renamed 2") && layouts.currentURL?.lastPathComponent == "Renamed 2.json",
              "layouts: duplicate makes Renamed 2 and opens it", "\(layouts.items.map(\.name))")
        // Text pending in the editor goes into the layout it was typed in before another layout opens.
        let dupURL = layouts.currentURL
        if let dupBlock = layouts.current?.blocks.first?.id {
            layouts.commitPendingTextEdit = { layouts.setText("Typed before switching", for: dupBlock) }
        }
        await layouts.open(renamed)
        let library = LayoutLibrary(layoutsDirectory: layouts.layoutsDirectory, templatesDirectory: layouts.templatesDirectory)
        check(dupURL.flatMap { try? library.load($0) }?.blocks.first?.text == "Typed before switching"
              && layouts.current?.blocks.first?.text != "Typed before switching" && layouts.currentURL == renamed,
              "layouts: opening another layout commits the editor's text to the original first")

        // Delete through the fake recycler.
        guard let firstURL = first else { return }
        await layouts.delete(firstURL)
        check(recycled == [firstURL] && !fm.fileExists(atPath: firstURL.path) && !layouts.items.map(\.name).contains("Poster"),
              "layouts: delete moves the file to the (fake) Trash", "\(recycled)")
        await layouts.delete(renamed)
        check(layouts.current == nil && layouts.currentURL == nil && layouts.renderedImage == nil,
              "layouts: deleting the open layout closes it")

        await pairingSteps(model, store: backend.store)

        // Quit flush: an edit made just before quitting is saved.
        if let dup = layouts.items.first(where: { $0.name == "Renamed 2" }) {
            await layouts.open(dup.url)
            layouts.apply { $0.blocks[0].text = "Saved at quit" }
            await model.prepareForQuit()
            check((try? String(contentsOf: dup.url, encoding: .utf8))?.contains("Saved at quit") == true && !layouts.isDirty,
                  "layouts: quitting saves a pending edit")
        } else {
            check(false, "layouts: the duplicate is listed")
        }

        // Nothing outside the temp folders.
        check(realDates() == realBefore, "layouts: the real Layouts and Templates folders are untouched", "\(realBefore) → \(realDates())")
        check(standardSnapshot() == standardBefore, "layouts: nothing written to the user's defaults")
        check(recycled.allSatisfy { $0.path.hasPrefix(root.path) }, "layouts: only temp files were recycled")
    }

    // MARK: Wave 3C task 7: Pairing Studio

    /// ⌘K sources and the ⌘K rule, cycling families (←/→) and styles (↑/↓) on the selected block, Apply to All
    /// Blocks, the strip's remove and its family-name images; every change is one undo step. Starts with no layout
    /// open, so ⌘K creates a Poster.
    private static func pairingSteps(_ model: AppModel, store: FontStore) async {
        let layouts = model.layouts
        check(layouts.current == nil, "pairing: starts with no layout open")
        let all = (try? store.faceIDs(for: LibraryQuery())) ?? []
        var byFamily: [String: [Int64]] = [:]
        for id in all {
            guard let ref = try? store.reference(forFace: id) else { continue }
            byFamily[ref.family.lowercased(), default: []].append(id)
        }
        guard let treb = byFamily["trebuchet ms"], treb.count == 3, let georgia = byFamily["georgia"]?.first,
              let hoefler = byFamily["hoefler text"]?.first else {
            check(false, "pairing: the fixture has Trebuchet MS (3 styles), Georgia and Hoefler Text", "\(byFamily.keys.sorted())")
            return
        }
        func families() -> [String] { layouts.candidates.map { $0.family.lowercased() } }

        // Two ⌘K presses at once with no layout open: one new Poster, both sources' families in it.
        let itemsBefore = layouts.items.count
        model.selection = Set(treb)
        let pressA = Task { @MainActor in await model.openInLayouts() }
        // Let the first press read its source and start creating the Poster; it is still running when the second comes.
        for _ in 0..<3 { await Task.yield() }
        let firstStillRunning = layouts.current == nil
        model.selection = [georgia]
        let pressB = Task { @MainActor in await model.openInLayouts() }
        await pressA.value
        await pressB.value
        let layoutFiles = ((try? FileManager.default.contentsOfDirectory(atPath: layouts.layoutsDirectory.path)) ?? [])
            .filter { $0.hasSuffix(".json") }
        check(firstStillRunning && layouts.items.count == itemsBefore + 1 && layoutFiles.count == itemsBefore + 1,
              "pairing: two ⌘K presses at once create exactly one layout", "\(firstStillRunning) \(layouts.items.map(\.name))")
        check(Set(families()) == ["trebuchet ms", "georgia"] && families().count == 2,
              "pairing: … holding both presses' candidates", "\(families())")
        if let made = layouts.currentURL { await layouts.delete(made) }
        check(layouts.current == nil && layouts.items.count == itemsBefore, "pairing: the double-⌘K layout is removed again")

        // ⌘K with three faces of one family plus one other: two candidates, in a new Poster.
        model.selection = Set(treb + [georgia])
        check(model.layoutsSourceFaceIDs.count == 4, "pairing: ⌘K uses the browser selection")
        await model.openInLayouts()
        check(layouts.current != nil && layouts.currentURL?.lastPathComponent.hasPrefix("Poster") == true,
              "pairing: ⌘K with no layout open creates a Poster layout", "\(String(describing: layouts.currentURL))")
        check(families() == ["trebuchet ms", "georgia"] || families() == ["georgia", "trebuchet ms"],
              "pairing: ⌘K with 3 faces of one family plus 1 other gives 2 candidates", "\(families())")
        layouts.undo()
        check(layouts.candidates.isEmpty, "pairing: setting the candidates is undoable")
        layouts.redo()
        check(families().count == 2, "pairing: … and redoable")
        let first = layouts.candidates[0]
        let second = layouts.candidates[1]

        // The strip's family name drawn in its own font, off the main thread.
        let image = await layouts.candidateImage(for: first, pointSize: 18, scale: 2)
        check(image != nil && (image?.width ?? 0) > 10, "pairing: the strip renders a candidate's name in its font")

        // Keys.
        check(LayoutsModel.cycleKey(keyCode: 124) == .family(1) && LayoutsModel.cycleKey(keyCode: 123) == .family(-1)
              && LayoutsModel.cycleKey(keyCode: 125) == .style(1) && LayoutsModel.cycleKey(keyCode: 126) == .style(-1)
              && LayoutsModel.cycleKey(keyCode: 51) == nil,
              "pairing: ←/→ cycle families and ↑/↓ cycle styles")
        check(CandidatesStrip<LayoutsModel>.cycleKey(.left) == LayoutsModel.cycleKey(keyCode: 123)
              && CandidatesStrip<LayoutsModel>.cycleKey(.right) == LayoutsModel.cycleKey(keyCode: 124)
              && CandidatesStrip<LayoutsModel>.cycleKey(.up) == LayoutsModel.cycleKey(keyCode: 126)
              && CandidatesStrip<LayoutsModel>.cycleKey(.down) == LayoutsModel.cycleKey(keyCode: 125),
              "pairing: arrows on the focused candidates strip cycle like on the page")

        // Cycling on the selected block.
        guard let blockID = layouts.current?.blocks.first?.id else { check(false, "pairing: the Poster has blocks"); return }
        func font() -> FontReference? { layouts.current?.blocks.first { $0.id == blockID }?.font }
        layouts.select(blockID)
        await layouts.applyCandidate(first)
        let start = font()
        check(start?.family.lowercased() == first.family.lowercased(), "pairing: a strip click applies the candidate to the block")
        layouts.cycleFamily(step: 1)
        await layouts.waitForPairing()
        let afterOne = font()
        check(afterOne?.family.lowercased() == second.family.lowercased(), "pairing: → goes to the next family",
              "\(String(describing: afterOne))")
        layouts.cycleFamily(step: 1)
        await layouts.waitForPairing()
        check(font()?.family.lowercased() == first.family.lowercased(), "pairing: → twice wraps back to the first family",
              "\(String(describing: font()))")
        let afterTwo = font()
        layouts.undo()
        check(font() == afterOne, "pairing: a family step is undoable")
        layouts.redo()
        check(font() == afterTwo, "pairing: … and redoable")

        // Styles: put the block in Trebuchet MS, then ↑.
        let trebCandidate = layouts.candidates.first { $0.family.lowercased() == "trebuchet ms" }!
        await layouts.applyCandidate(trebCandidate)
        let beforeStyle = font()
        layouts.cycleStyle(step: -1)
        await layouts.waitForPairing()
        let afterStyle = font()
        check(afterStyle?.family.lowercased() == "trebuchet ms" && afterStyle?.postScriptName != beforeStyle?.postScriptName,
              "pairing: ↑ cycles styles within the family", "\(String(describing: beforeStyle)) → \(String(describing: afterStyle))")
        layouts.undo()
        check(font() == beforeStyle, "pairing: a style step is undoable")
        for _ in 0..<3 { layouts.cycleStyle(step: 1) }
        await layouts.waitForPairing()
        check(font() == beforeStyle, "pairing: ↓ three times through three styles wraps around")
        for _ in 0..<3 { layouts.undo() }
        check(font() == beforeStyle, "pairing: the style steps undo one by one")

        // Apply to All Blocks.
        let fontsBefore = layouts.current?.blocks.map(\.font)
        await layouts.applyFamilyToAll(second)
        check(layouts.current?.blocks.allSatisfy { $0.font.family.lowercased() == second.family.lowercased() } == true,
              "pairing: Apply to All sets every block's family", "\(layouts.current?.blocks.map(\.font.family) ?? [])")
        layouts.undo()
        check(layouts.current?.blocks.map(\.font) == fontsBefore, "pairing: Apply to All is one undo step")

        // A second ⌘K appends, skipping families already listed.
        model.selection = [georgia, treb[1], hoefler]
        await model.openInLayouts()
        check(families().count == 3 && families().last == "hoefler text" && Array(layouts.candidates.prefix(2)) == [first, second],
              "pairing: a second ⌘K appends without duplicates", "\(families())")
        layouts.undo()
        check(families().count == 2, "pairing: appending is undoable")
        layouts.redo()

        // The strip's remove.
        guard let hoeflerCandidate = layouts.candidates.last else { return }
        layouts.removeCandidate(hoeflerCandidate)
        check(families() == [first.family.lowercased(), second.family.lowercased()], "pairing: the strip's remove works")
        layouts.undo()
        check(families().count == 3, "pairing: removing is undoable")
        layouts.redo()

        // An empty selection uses the Quick Collection.
        model.selection = []
        await model.setQuickCollection([hoefler], included: true)
        await model.waitForQuickCollectionWritesForSmoke()
        check(model.layoutsSourceFaceIDs == [hoefler], "pairing: with an empty selection the Quick Collection is used")
        await model.openInLayouts()
        check(families().last == "hoefler text" && families().count == 3, "pairing: ⌘K adds the Quick Collection's family",
              "\(families())")
        await model.setQuickCollection([hoefler], included: false)
        await model.waitForQuickCollectionWritesForSmoke()

        // The family page's family.
        model.openFamilyDetail(faceID: treb[0])
        let opened = await eventually(within: .seconds(2)) { model.detail != nil }
        check(opened && Set(model.layoutsSourceFaceIDs) == Set(treb), "pairing: on the family page ⌘K uses its family",
              "\(model.layoutsSourceFaceIDs)")
        model.closeFamilyDetail()

        await layoutExportSteps(layouts)
    }

    // MARK: Wave 3C task 8: PDF export and print

    /// PDF export (one page, one page per candidate, 30 candidates with progress and Cancel), the save-panel seam,
    /// the print operation's paper size and view, and that everything lands in a temp folder. Runs on the layout
    /// the Pairing Studio steps leave open (3 candidates).
    private static func layoutExportSteps(_ layouts: LayoutsModel) async {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("FontoryExportSmoke-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: dir) }
        do { try fm.createDirectory(at: dir, withIntermediateDirectories: true) } catch { check(false, "export: temp folder"); return }
        func names() -> [String] { ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? []).sorted() }
        func pdf(_ name: String) -> CGPDFDocument? { CGPDFDocument(dir.appendingPathComponent(name) as CFURL) }
        guard let doc = layouts.current else { check(false, "export: a layout is open"); return }
        let candidateCount = Set(layouts.candidates.map { $0.family.lowercased() }).count
        check(candidateCount == 3, "export: the open layout has 3 candidate families", "\(candidateCount)")

        do { try await layouts.exportPDF(to: dir.appendingPathComponent("one.pdf")) } catch { check(false, "export: one page", "\(error)") }
        let one = pdf("one.pdf")
        let box = one?.page(at: 1)?.getBoxRect(.mediaBox)
        check(one?.numberOfPages == 1 && box?.size == CGSize(width: doc.pageSize.w, height: doc.pageSize.h),
              "export: Export PDF writes 1 page of the page size", "\(String(describing: one?.numberOfPages)) \(String(describing: box))")

        do { try await layouts.exportPDFForEachCandidate(to: dir.appendingPathComponent("three.pdf")) } catch { check(false, "export: candidates", "\(error)") }
        let three = pdf("three.pdf")
        check(three?.numberOfPages == 3 && three?.page(at: 3)?.getBoxRect(.mediaBox).size == CGSize(width: doc.pageSize.w, height: doc.pageSize.h),
              "export: with 3 candidates the per-candidate export writes a 3-page PDF", "\(String(describing: three?.numberOfPages))")
        check(layouts.exportProgress == nil, "export: no progress sheet for 3 candidates")

        // The save-panel seam, and the default names.
        check(LayoutsModel.exportFileName(layoutName: "Poster", forCandidates: false) == "Poster.pdf"
              && LayoutsModel.exportFileName(layoutName: "Poster", forCandidates: true) == "Poster — Candidates.pdf"
              && LayoutsModel.exportFileName(layoutName: "a/b", forCandidates: false) == "a-b.pdf",
              "export: default names are the layout name, plus “ — Candidates”")
        layouts.exportDestinationOverride = dir.appendingPathComponent("seam.pdf")
        await layouts.exportPDFWithPanel()
        layouts.exportDestinationOverride = dir.appendingPathComponent("seam-candidates.pdf")
        await layouts.exportPDFForEachCandidateWithPanel()
        layouts.exportDestinationOverride = nil
        check(pdf("seam.pdf")?.numberOfPages == 1 && pdf("seam-candidates.pdf")?.numberOfPages == 3,
              "export: the destination override skips the panels")

        // Print: the operation's paper is the page; the view draws the page.
        if let op = layouts.printOperation() {
            let info = op.printInfo
            let defaultPaper = NSPrintInfo.shared.paperSize
            let paper = info.paperSize
            let samePaper = (paper == defaultPaper) || (paper == NSSize(width: defaultPaper.height, height: defaultPaper.width))
            let wantsLandscape = doc.pageSize.w > doc.pageSize.h
            check(samePaper && info.orientation == (wantsLandscape ? .landscape : .portrait)
                  && info.horizontalPagination == .fit && info.verticalPagination == .fit,
                  "print: the default paper, scaled to fit, oriented by the page's aspect", "\(paper) vs \(defaultPaper)")
            let data = op.view?.dataWithPDF(inside: op.view?.bounds ?? .zero)
            let printed = data.flatMap { CGDataProvider(data: $0 as CFData) }.flatMap { CGPDFDocument($0) }
            check(op.view?.bounds.size == CGSize(width: doc.pageSize.w, height: doc.pageSize.h) && printed?.numberOfPages == 1,
                  "print: the print view draws the page")
        } else {
            check(false, "print: an operation is made for the open layout")
        }

        // No candidates: the per-candidate export is unavailable.
        let savedCandidates = layouts.candidates
        layouts.apply { $0.candidates = [] }
        check(!layouts.canExportCandidates, "export: with no candidates the per-candidate item is disabled")
        var threw = false
        do { try await layouts.exportPDFForEachCandidate(to: dir.appendingPathComponent("none.pdf")) } catch { threw = true }
        check(threw && !fm.fileExists(atPath: dir.appendingPathComponent("none.pdf").path), "export: with no candidates nothing is written")
        layouts.undo()
        check(layouts.candidates == savedCandidates && layouts.canExportCandidates, "export: candidates come back with undo")

        // 30 candidates: a progress sheet, Cancel writes nothing, a full run writes 30 pages.
        let fakes = (0..<27).map { FontReference(postScriptName: "SmokeFake\($0)-Regular", family: "Smoke Fake \($0)") }
        layouts.apply { $0.candidates += fakes }
        layouts.exportPageDelay = 0.03
        let cancelled = dir.appendingPathComponent("cancelled.pdf")
        var cancelledError = false
        let task = Task { @MainActor in
            do { try await layouts.exportPDFForEachCandidate(to: cancelled) } catch is CancellationError { cancelledError = true } catch {}
        }
        let shown = await eventually(within: .seconds(5)) { (layouts.exportProgress?.total ?? 0) == 30 && (layouts.exportProgress?.done ?? 0) >= 2 }
        check(shown, "export: 30 candidates show a progress sheet", "\(String(describing: layouts.exportProgress))")
        var busy = false
        do { try await layouts.exportPDF(to: dir.appendingPathComponent("second.pdf")) } catch LayoutExportError.busy { busy = true } catch {}
        check(busy && !fm.fileExists(atPath: dir.appendingPathComponent("second.pdf").path),
              "export: a second export is refused while one runs")
        layouts.cancelExport()
        await task.value
        try? await Task.sleep(for: .milliseconds(150))
        check(layouts.exportProgress == nil, "export: a late progress update of an ended export is dropped")
        check(cancelledError && !fm.fileExists(atPath: cancelled.path) && layouts.exportProgress == nil,
              "export: Cancel ends the export, writes no file and closes the sheet")
        layouts.exportPageDelay = 0
        do { try await layouts.exportPDFForEachCandidate(to: dir.appendingPathComponent("thirty.pdf")) } catch { check(false, "export: 30", "\(error)") }
        check(pdf("thirty.pdf")?.numberOfPages == 30 && layouts.exportProgress == nil, "export: 30 candidates write a 30-page PDF",
              "\(String(describing: pdf("thirty.pdf")?.numberOfPages))")
        layouts.undo()
        check(layouts.candidates == savedCandidates, "export: the added test candidates are undone")

        check(names() == ["one.pdf", "seam-candidates.pdf", "seam.pdf", "thirty.pdf", "three.pdf"],
              "export: only the expected files are in the temp folder, no leftovers", "\(names())")
    }

    // MARK: Wave 3C task 6: block editing and inspector

    /// Block editing at the model level (what the canvas and inspector call): select, move and resize as one undo
    /// step each, text, size/tracking/line height/alignment/colour/sizes, font and style, delete and add, and the
    /// "N characters missing" note for a Latin-only font with Vietnamese text.
    private static func layoutEditingSteps(_ layouts: LayoutsModel, store: FontStore) async {
        guard let doc = layouts.current, let block = doc.blocks.first else { check(false, "editing: a layout is open"); return }
        let id = block.id
        let start = block.frame
        func current() -> LayoutBlock? { layouts.current?.blocks.first { $0.id == id } }

        // Select by page point (the canvas converts its view point first).
        let inside = CGPoint(x: start.x + start.w / 2, y: start.y + start.h / 2)
        layouts.select(layouts.blockID(atPage: inside))
        check(layouts.selectedBlockID == id && layouts.selectedBlock?.id == id, "editing: clicking a block selects it")
        layouts.select(layouts.blockID(atPage: CGPoint(x: -50, y: -50)))
        check(layouts.selectedBlockID == nil, "editing: clicking outside every block clears the selection")
        layouts.select(id)

        // Move: live intermediate frames, one undo step at mouse-up.
        layouts.beginLiveEdit()
        layouts.moveBlock(id, from: start, by: CGSize(width: 10, height: 10))
        check(current()?.frame.x == start.x + 10, "editing: dragging moves the block live")
        layouts.moveBlock(id, from: start, by: CGSize(width: 40, height: 25))
        layouts.endLiveEdit()
        check(current()?.frame == LayoutFrame(x: start.x + 40, y: start.y + 25, w: start.w, h: start.h),
              "editing: the drag ends at the last position", "\(String(describing: current()?.frame))")
        layouts.undo()
        check(current()?.frame == start, "editing: one undo reverts the whole drag", "\(String(describing: current()?.frame))")
        layouts.redo()
        check(current()?.frame.x == start.x + 40, "editing: redo repeats the drag")
        layouts.undo()

        // Resize by a corner, never below 20 × 20.
        layouts.beginLiveEdit()
        layouts.resizeBlock(id, from: start, corner: .bottomRight, by: CGSize(width: -5000, height: -5000))
        layouts.endLiveEdit()
        check(current()?.frame == LayoutFrame(x: start.x, y: start.y, w: 20, h: 20),
              "editing: resizing stops at 20 × 20", "\(String(describing: current()?.frame))")
        layouts.undo()
        layouts.beginLiveEdit()
        layouts.resizeBlock(id, from: start, corner: .topLeft, by: CGSize(width: -10, height: -20))
        layouts.endLiveEdit()
        check(current()?.frame == LayoutFrame(x: start.x - 10, y: start.y - 20, w: start.w + 10, h: start.h + 20),
              "editing: the top-left handle keeps the opposite corner", "\(String(describing: current()?.frame))")
        layouts.undo()
        check(current()?.frame == start, "editing: resize undoes")
        layouts.beginLiveEdit()
        layouts.endLiveEdit()
        check(current()?.frame == start && layouts.canRedo, "editing: a click without a drag is no undo step")

        // Text and the typographic fields.
        layouts.setText("Edited in place", for: id)
        check(current()?.text == "Edited in place", "editing: the in-place editor's text is applied")
        layouts.undo()
        check(current()?.text == block.text, "editing: text undoes")
        let fields: [(String, () -> Void, (LayoutBlock) -> Bool)] = [
            ("size", { layouts.setSize(61, for: id) }, { $0.size == 61 }),
            ("tracking", { layouts.setTracking(-25, for: id) }, { $0.tracking == -25 }),
            ("line height", { layouts.setLineHeight(1.5, for: id) }, { $0.lineHeight == 1.5 }),
            ("alignment", { layouts.setAlignment(block.alignment == .right ? .center : .right, for: id) }, { $0.alignment != block.alignment }),
            ("colour", { layouts.setColor("#FF0000", for: id) }, { $0.color == "#FF0000" }),
        ]
        for (name, set, holds) in fields {
            set()
            check(current().map(holds) == true, "editing: setting \(name) applies")
            layouts.undo()
            check(current() == block, "editing: \(name) undoes")
        }
        // Inspector values name their block: a value committing after the selection moved still hits it.
        layouts.select(nil)
        layouts.setTracking(40, for: id)
        check(current()?.tracking == 40, "editing: an inspector value applies to its own block, not the selection")
        layouts.undo()
        // Colour changes coalesce per block: A then B within a second are two undo steps.
        if let other = layouts.current?.blocks.first(where: { $0.id != id }) {
            layouts.setColor("#00FF00", for: id)
            layouts.setColor("#0000FF", for: id)
            layouts.setColor("#00FF00", for: other.id)
            layouts.undo()
            check(current()?.color == "#0000FF" && layouts.current?.blocks.first { $0.id == other.id }?.color == other.color,
                  "editing: colour changes to another block are a separate undo step")
            layouts.undo()
            check(current() == block, "editing: quick colour changes to one block are one undo step")
        }
        layouts.select(id)
        layouts.setSize(-4, for: id)
        check(current()?.size == LayoutsModel.sizeRange.lowerBound, "editing: size is clamped", "\(String(describing: current()?.size))")
        layouts.undo()
        check(LayoutsModel.parseSizes("12, 16,24 ,  36.5") == [12, 16, 24, 36.5] && LayoutsModel.parseSizes("12, big") == nil
              && LayoutsModel.parseSizes(" ") == nil, "editing: waterfall sizes parse from a comma-separated field")
        check(layouts.setSizes("10, 20", for: id) && current()?.sizes == [10, 20], "editing: waterfall sizes apply")
        layouts.undo()
        check(!layouts.setSizes("x", for: id) && current() == block, "editing: bad waterfall sizes are refused")
        let showMissing = layouts.current?.showMissing
        layouts.setShowMissing(!(showMissing ?? true))
        check(layouts.current?.showMissing == !(showMissing ?? true), "editing: Show Missing Characters toggles")
        layouts.undo()
        check(layouts.current?.showMissing == showMissing, "editing: Show Missing Characters undoes")

        // Delete and add.
        let count = layouts.current?.blocks.count ?? 0
        layouts.deleteSelectedBlock()
        check(layouts.current?.blocks.count == count - 1 && current() == nil && layouts.selectedBlockID == nil,
              "editing: ⌫ deletes the selected block")
        layouts.undo()
        check(layouts.current?.blocks.count == count && current() == block, "editing: delete undoes")
        layouts.addTextBlock()
        let page = layouts.current?.pageSize ?? LayoutSize(w: 0, h: 0)
        let added = layouts.selectedBlock
        check(layouts.current?.blocks.count == count + 1 && added?.kind == .text
              && added?.frame == LayoutFrame(x: (page.w - 300) / 2, y: (page.h - 100) / 2, w: 300, h: 100),
              "editing: + Text Block adds a selected 300 × 100 block at the page centre", "\(String(describing: added?.frame))")
        layouts.undo()
        check(layouts.current?.blocks.count == count && layouts.selectedBlockID == nil, "editing: adding undoes")

        // Fonts: Choose Font… search, the style menu, and the missing-characters note.
        layouts.addTextBlock()
        guard let newID = layouts.selectedBlockID else { check(false, "editing: the new block is selected"); return }
        let found = await layouts.searchFamilies("hoefler")
        check(found.map(\.name).contains("Hoefler Text"), "editing: Choose Font… finds a family by name", "\(found.map(\.name))")
        guard let hoefler = found.first(where: { $0.name == "Hoefler Text" }) else { return }
        await layouts.chooseFamily(hoefler)
        let representative = try? store.reference(forFace: hoefler.representativeID)
        check(layouts.selectedBlock?.font == representative, "editing: choosing a family sets its representative",
              "\(String(describing: layouts.selectedBlock?.font)) vs \(String(describing: representative))")
        let styles = await layouts.styles(for: layouts.selectedBlock?.font)
        check(styles.count > 1 && styles.allSatisfy { $0.reference.family == "Hoefler Text" },
              "editing: the style menu lists the family's styles", "\(styles.map(\.name))")
        if let other = styles.first(where: { $0.reference != representative }) {
            layouts.setFont(other.reference)
            check(layouts.selectedBlock?.font == other.reference, "editing: choosing a style applies it")
            layouts.undo()
            check(layouts.selectedBlock?.font == representative, "editing: a style change undoes")
        }
        layouts.setText("Tiếng Việt", for: newID)
        let noted = await eventually(within: .seconds(3)) { layouts.missingCharacters(in: newID) == 2 }
        check(noted && !layouts.isFontMissing(newID),
              "editing: a Latin-only font with Vietnamese text notes 2 characters missing",
              "\(layouts.missingCharacters(in: newID)) / \(layouts.report)")
        layouts.select(newID)
        layouts.deleteSelectedBlock()
        check(layouts.current?.blocks.count == count, "editing: the test block is removed")

        // Text still in the in-place editor (simulated through the canvas's commit hook) is saved by a flush.
        if let url = layouts.currentURL {
            layouts.commitPendingTextEdit = { layouts.setText("Typed, not yet committed", for: id) }
            await layouts.flush()
            check(layouts.commitPendingTextEdit == nil && current()?.text == "Typed, not yet committed"
                  && ((try? String(contentsOf: url, encoding: .utf8))?.contains("Typed, not yet committed") ?? false),
                  "editing: a flush (quit, window close) commits and saves the editor's pending text")
            layouts.undo()
        }

        // PageTransform: view ↔ page round trip.
        let frame = LayoutFrame(x: 12.5, y: 40, w: 300, h: 100)
        let roundTrips = [0.05, 1, 8].allSatisfy { (zoom: CGFloat) in
            let t = PageTransform(origin: CGPoint(x: 37, y: 19), zoom: zoom)
            let r = t.viewRect(frame)
            let p = t.pagePoint(r.origin), q = t.pagePoint(CGPoint(x: r.maxX, y: r.maxY))
            return abs(p.x - 12.5) < 1e-9 && abs(p.y - 40) < 1e-9 && abs(q.x - 312.5) < 1e-9 && abs(q.y - 140) < 1e-9
                && abs(r.width - 300 * zoom) < 1e-9 && t.pageDelta(CGSize(width: 10 * zoom, height: -4 * zoom)) == CGSize(width: 10, height: -4)
        }
        check(roundTrips, "editing: the canvas's page ↔ view mapping round-trips at 5 %, 100 % and 800 %")
    }

    /// An image's pixels, for comparing two renders.
    private static func imageBytes(_ image: CGImage) -> Data? {
        image.dataProvider?.data as Data?
    }

    // MARK: Google Fonts task 6: controller

    /// Serves a small catalogue, its manifests and font bytes from memory; never touches the network.
    final class FakeGoogleTransport: GoogleTransport, @unchecked Sendable {
        struct Family {
            var modified: String
            var font: Data
            var category = "Sans Serif"
            var subsets = ["latin", "vietnamese"]
        }
        private let lock = NSLock()
        private var families: [String: Family] = [:]
        private var failsCatalog = false
        private var fontDelay: Duration = .zero
        private var count = 0

        var requests: Int { lock.withLock { count } }
        /// A family's category and subsets are kept when not given.
        func set(_ name: String, modified: String, font: Data, category: String? = nil, subsets: [String]? = nil) {
            lock.withLock {
                var family = families[name] ?? Family(modified: modified, font: font)
                family.modified = modified
                family.font = font
                if let category { family.category = category }
                if let subsets { family.subsets = subsets }
                families[name] = family
            }
        }
        func setFailsCatalog(_ fails: Bool) { lock.withLock { failsCatalog = fails } }
        func setFontDelay(_ delay: Duration) { lock.withLock { fontDelay = delay } }

        static func fileName(_ family: String) -> String { family.replacingOccurrences(of: " ", with: "") + "-Regular.ttf" }
        static func fontURL(_ family: String) -> URL {
            URL(string: "https://fonts.gstatic.com/s/smoke/\(fileName(family))")!
        }

        func data(from url: URL) async throws -> Data {
            let (fams, fails, delay) = lock.withLock { count += 1; return (families, failsCatalog, fontDelay) }
            func json(_ object: Any) throws -> Data {
                Data(")]}'\n".utf8) + (try JSONSerialization.data(withJSONObject: object))
            }
            if url == GoogleCatalog.catalogURL {
                if fails { throw URLError(.notConnectedToInternet) }
                let list = fams.keys.sorted().enumerated().map { i, name in
                    ["family": name, "category": fams[name]!.category, "lastModified": fams[name]!.modified,
                     "subsets": fams[name]!.subsets, "designers": ["Smoke"], "popularity": i + 1,
                     "size": fams[name]!.font.count] as [String: Any]
                }
                return try json(["familyMetadataList": list])
            }
            if url.host() == "fonts.google.com", url.path() == "/download/list",
               let family = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "family" })?.value,
               fams[family] != nil {
                return try json(["manifest": [
                    "files": [["filename": "OFL.txt", "contents": "Smoke licence"]],
                    "fileRefs": [["filename": "static/" + Self.fileName(family), "url": Self.fontURL(family).absoluteString]],
                ] as [String: Any]])
            }
            if let (_, family) = fams.first(where: { Self.fontURL($0.key) == url }) {
                if delay > .zero { try await Task.sleep(for: delay) }
                return family.font
            }
            throw GoogleTransportError.http(404)
        }
    }

    private static func googleIDs(_ store: FontStore) -> Set<Int64> {
        Set((try? store.faceIDs(for: LibraryQuery(scope: .googleFonts, includeSystem: true))) ?? [])
    }

    private static func activatedIDs(_ store: FontStore) -> Set<Int64> {
        Set((try? store.faceIDs(for: LibraryQuery(scope: .activated, includeSystem: true))) ?? [])
    }

    private static func googleFace(_ store: FontStore, postScriptName: String) -> Int64? {
        let ids = Array(googleIDs(store))
        return ((try? store.rows(ids: ids)) ?? [:]).values.first { $0.postScriptName == postScriptName }?.id
    }

    private static func samePath(_ a: String?, _ b: URL) -> Bool {
        guard let a else { return false }
        return URL(fileURLWithPath: a).resolvingSymlinksInPath().path == b.resolvingSymlinksInPath().path
    }

    /// A temporary library and root, a private defaults suite, the fake transport and `SmokeRegistrar`: enabling,
    /// updates, offline/mount, catalogue failure and both folder changes. Nothing is activated on the Mac.
    private static func googleSteps() async {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("FontoryGoogleSmoke-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: root) }
        let suiteName = "FontorySmoke-\(UUID().uuidString)"
        guard let suite = UserDefaults(suiteName: suiteName) else { check(false, "google: settings suite"); return }
        defer { suite.removePersistentDomain(forName: suiteName) }
        let keys = [SettingsKey.googleFontsEnabled, SettingsKey.googleFontsLastCheck, SettingsKey.googleFontsPaused]
        let standardBefore = keys.map { String(describing: UserDefaults.standard.object(forKey: $0)) }

        let fonts = root.appendingPathComponent("Fonts", isDirectory: true)
        let google = root.appendingPathComponent("Google Fonts", isDirectory: true)
        let supplemental = URL(fileURLWithPath: "/System/Library/Fonts/Supplemental", isDirectory: true)
        let transport = FakeGoogleTransport()
        let registrar = SmokeRegistrar()
        let backend: LibraryBackend
        let arial: Data, georgia: Data, courier: Data
        do {
            try fm.createDirectory(at: fonts, withIntermediateDirectories: true)
            // Read-only use of the system fonts: their bytes are served by the fake transport.
            arial = try Data(contentsOf: supplemental.appendingPathComponent("Arial.ttf"))
            georgia = try Data(contentsOf: supplemental.appendingPathComponent("Georgia.ttf"))
            courier = try Data(contentsOf: supplemental.appendingPathComponent("Courier New.ttf"))
            transport.set("Smoke Sans", modified: "2025-01-01", font: arial)
            transport.set("Smoke Serif", modified: "2025-01-01", font: georgia, category: "Serif", subsets: ["latin"])
            transport.set("Smoke Mono", modified: "2025-01-01", font: courier, category: "Monospace")
            backend = try LibraryBackend(databaseURL: root.appendingPathComponent("library.sqlite"), registrar: registrar)
        } catch {
            check(false, "google: setup", "\(error)"); return
        }
        let store = backend.store
        let model = AppModel()
        model.settingsDefaults = suite
        model.suppressesPreviewSaveForSmoke = true
        await model.attachBackendForSmoke(backend)
        guard let fontsLoc = await model.runBackground({ try backend.addFolder(fonts) }) else {
            check(false, "google: add the user folder", model.alert?.message ?? ""); return
        }
        await model.reloadLocations()
        let controller = GoogleFontsController(model: model, transport: transport, defaults: suite, minimumFamilies: 1, backoff: [])
        model.google = controller
        func googleLocations() -> [LocationRecord] { ((try? store.locations()) ?? []).filter { $0.kind == .googleFonts } }
        func settled() async -> Bool {
            let ok = await eventually(within: .seconds(20)) {
                if case .downloading = controller.phase { return false }
                return controller.phase != .checking
            }
            await model.waitForScansForSmoke()
            return ok
        }

        check(samePath(controller.defaultFolder.path, root.appendingPathComponent("Google Fonts")),
              "google: default folder is a sibling of the first location", controller.defaultFolder.path)
        await controller.loadEstimate()
        check(controller.estimatedBytes == arial.count + georgia.count + courier.count && controller.estimatedFamilies == 3,
              "google: estimate from the catalogue", "\(String(describing: controller.estimatedBytes))")

        // The sidebar row before consent: the browser shows the empty state (no catalogue request).
        let requestsBeforeRow = transport.requests
        model.applySidebarSelection([.scope(.googleFonts)], modifiers: [])
        check(model.query.scope == .googleFonts && model.showsGoogleEmptyState && !model.showsGoogleFilterBar
              && transport.requests == requestsBeforeRow,
              "google ui: empty state when disabled", "\(model.query.scope) \(model.showsGoogleEmptyState)")
        model.applySidebarSelection([.scope(.all)], modifiers: [])

        // Refused: inside a user location, and the user location itself (never converted to kind 4).
        let inside = fonts.appendingPathComponent("Google Fonts", isDirectory: true)
        let requestsBefore = transport.requests
        for (target, name) in [(inside, "google: enable inside an existing location is refused"),
                               (fonts, "google: enable on an existing location is refused")] {
            var refused = false
            do { try await controller.enable(at: target) } catch let error as LibraryError {
                if case .overlapsLocation = error { refused = true }
                if case .alreadyInLibrary = error { refused = true }
            } catch {}
            check(refused && googleLocations().isEmpty && transport.requests == requestsBefore
                  && !suite.bool(forKey: SettingsKey.googleFontsEnabled) && !fm.fileExists(atPath: inside.path)
                  && (try? store.locations())?.first(where: { $0.id == fontsLoc.id })?.kind == .folder,
                  name, "\(googleLocations().count) \(transport.requests - requestsBefore) \(controller.phase)")
        }

        // Enable: the folder is created, every family downloaded and indexed, nothing activated.
        do { try await controller.enable(at: google) } catch { check(false, "google: enable", "\(error)") }
        let enabledSettled = await settled()
        let ids = googleIDs(store)
        check(enabledSettled && controller.phase == .idle && ids.count == 3 && activatedIDs(store).isDisjoint(with: ids)
              && suite.bool(forKey: SettingsKey.googleFontsEnabled) && suite.object(forKey: SettingsKey.googleFontsLastCheck) != nil
              && (try? store.googleProgress()).map { $0 == (3, 3) } == true
              && fm.fileExists(atPath: google.appendingPathComponent("Smoke Sans/SmokeSans-Regular.ttf").path)
              && fm.fileExists(atPath: google.appendingPathComponent("Smoke Sans/OFL.txt").path),
              "google: enable downloads, indexes, nothing activated", "\(controller.phase) \(ids.count)")
        guard let loc = controller.location, samePath(loc.lastKnownPath, google) else {
            check(false, "google: location", "\(String(describing: controller.location))"); return
        }

        await googleFilterBarSteps(model, store: store)

        // A check within 24 h is skipped without a request.
        let beforeSkip = transport.requests
        await controller.checkForUpdates(force: false)
        check(transport.requests == beforeSkip, "google: check skipped within 24 h")

        // Update: same file name, new bytes (same PostScript name), newer lastModified → still active.
        guard let sans = googleFace(store, postScriptName: "ArialMT") else { check(false, "google: ArialMT indexed"); return }
        await model.setActivation([sans], .on)
        let sansFile = indexedPaths(store, loc.id)["Smoke Sans/SmokeSans-Regular.ttf"]
        let newer = arial + Data(count: 4)
        transport.set("Smoke Sans", modified: "2026-01-01", font: newer)
        await controller.checkForUpdates(force: true)
        let updateSettled = await settled()
        let sansAfter = googleFace(store, postScriptName: "ArialMT")
        let size = (try? fm.attributesOfItem(atPath: google.appendingPathComponent("Smoke Sans/SmokeSans-Regular.ttf").path))?[.size] as? Int
        check(updateSettled && size == newer.count && sansAfter != nil && activatedIDs(store).contains(sansAfter ?? -1)
              && indexedPaths(store, loc.id)["Smoke Sans/SmokeSans-Regular.ttf"] == sansFile,
              "google: update keeps activation", "\(String(describing: size)) \(String(describing: sansAfter))")

        // Offline: an unmount of the root stops the run; the mount resumes it.
        transport.setFontDelay(.milliseconds(400))
        transport.set("Smoke Serif", modified: "2026-01-01", font: georgia + Data(count: 4))
        transport.set("Smoke Mono", modified: "2026-01-01", font: courier + Data(count: 4))
        await controller.checkForUpdates(force: true)
        let started = await eventually(within: .seconds(5)) { if case .downloading = controller.phase { return true }; return false }
        await model.handle(.unmounted(volumeURL: google))
        let offline = controller.phase == .offline
        try? await Task.sleep(for: .milliseconds(600))
        let doneWhileOffline = (try? store.googleProgress())?.done ?? -1
        check(started && offline && controller.phase == .offline && doneWhileOffline < 3,
              "google: offline pauses", "\(started) \(controller.phase) \(doneWhileOffline)")
        await model.handle(.mounted(volumeURL: URL(fileURLWithPath: "/"), uuid: loc.volumeUUID))
        var resumed = false
        if case .downloading = controller.phase { resumed = true }
        let mountSettled = await settled()
        check(resumed && mountSettled && controller.phase == .idle && (try? store.googleProgress()).map { $0 == (3, 3) } == true,
              "google: offline pauses and mount resumes", "\(resumed) \(controller.phase)")
        transport.setFontDelay(.zero)

        // Catalogue failure: the error is shown and nothing else changes.
        func snapshot() -> String {
            let files = (fm.subpaths(atPath: google.path) ?? []).sorted().joined(separator: ",")
            let progress = (try? store.googleProgress()).map { "\($0.done)/\($0.total)" } ?? "-"
            let last = String(describing: suite.object(forKey: SettingsKey.googleFontsLastCheck))
            return "\(files)|\(progress)|\(googleIDs(store).sorted())|\(googleLocations().map(\.id))|\(last)"
        }
        let before = snapshot()
        transport.setFailsCatalog(true)
        await controller.checkForUpdates(force: true)
        check(controller.phase == .error("Couldn't reach Google Fonts") && snapshot() == before,
              "google: catalogue failure shows error and changes nothing", "\(controller.phase)")
        transport.setFailsCatalog(false)

        // A new folder inside or containing the current one is refused (move and leave) and nothing changes.
        let diskBefore = snapshot()
        for (target, move) in [(google.appendingPathComponent("Sub", isDirectory: true), true),
                               (google.appendingPathComponent("Sub", isDirectory: true), false),
                               (root, true)] {
            var refused = false
            do { try await controller.changeFolder(to: target, moveFiles: move) } catch let error as LibraryError {
                if case .overlapsLocation = error { refused = true }
            } catch {}
            check(refused && snapshot() == diskBefore && controller.location?.id == loc.id
                  && samePath(controller.location?.lastKnownPath, google) && fm.fileExists(atPath: google.path),
                  "google: change into or around the current folder is refused (\(target.lastPathComponent), move \(move))",
                  "\(refused) \(controller.phase)")
        }

        // Move Files: the folder moves, the location is relinked (same id) and activation is kept.
        let moved = root.appendingPathComponent("Moved/Google Fonts", isDirectory: true)
        let eventsBeforeMove = registrar.events.count
        do {
            try fm.createDirectory(at: moved.deletingLastPathComponent(), withIntermediateDirectories: true)
            try await controller.changeFolder(to: moved, moveFiles: true)
        } catch { check(false, "google: move folder", "\(error)") }
        let moveSettled = await settled()
        let sansMoved = googleFace(store, postScriptName: "ArialMT")
        check(moveSettled && controller.location?.id == loc.id && samePath(controller.location?.lastKnownPath, moved)
              && !fm.fileExists(atPath: google.path)
              && fm.fileExists(atPath: moved.appendingPathComponent("Smoke Sans/SmokeSans-Regular.ttf").path)
              && googleIDs(store).count == 3 && activatedIDs(store).contains(sansMoved ?? -1),
              "google: move folder keeps activation", "\(controller.phase) \(String(describing: controller.location?.lastKnownPath))")
        func unregisterBeforeRegister(since start: Int, old: URL, new: URL) -> Bool {
            let events = Array(registrar.events.dropFirst(start))
            // Temp paths may be spelled /var/… or /private/var/…; the moved-away files no longer resolve.
            func norm(_ path: String) -> String { path.hasPrefix("/private/") ? String(path.dropFirst(8)) : path }
            let oldPath = norm(old.standardizedFileURL.path), newPath = norm(new.standardizedFileURL.path)
            func under(_ path: String, _ base: String) -> Bool { norm(path).hasPrefix(base + "/") }
            guard let lastUnregister = events.lastIndex(where: { !$0.register && under($0.path, oldPath) }),
                  let firstRegister = events.firstIndex(where: { $0.register && under($0.path, newPath) }) else { return false }
            return lastUnregister < firstRegister && !events.contains { $0.register && under($0.path, oldPath) }
        }
        check(unregisterBeforeRegister(since: eventsBeforeMove, old: google, new: moved),
              "google: move unregisters the old files before registering the new ones",
              "\(registrar.events.dropFirst(eventsBeforeMove).map { "\($0.register ? "+" : "-")\($0.path)" })")

        // Move Files across volumes (forced copy, then delete): watcher and scans are held, activation is kept.
        let copied = root.appendingPathComponent("Copied/Google Fonts", isDirectory: true)
        let eventsBeforeCopy = registrar.events.count
        controller.forcesCrossVolumeMove = true
        do { try await controller.changeFolder(to: copied, moveFiles: true) } catch { check(false, "google: copy folder", "\(error)") }
        controller.forcesCrossVolumeMove = false
        let copySettled = await settled()
        // Past the folder-event delay: a watcher left on the old folder would have rescanned (and pruned) by now.
        try? await Task.sleep(for: .seconds(6))
        await model.waitForScansForSmoke()
        let sansCopied = googleFace(store, postScriptName: "ArialMT")
        check(copySettled && controller.location?.id == loc.id && samePath(controller.location?.lastKnownPath, copied)
              && !fm.fileExists(atPath: moved.path)
              && fm.fileExists(atPath: copied.appendingPathComponent("Smoke Sans/SmokeSans-Regular.ttf").path)
              && googleIDs(store).count == 3 && activatedIDs(store).contains(sansCopied ?? -1)
              && unregisterBeforeRegister(since: eventsBeforeCopy, old: moved, new: copied),
              "google: cross-volume move keeps activation", "\(controller.phase) \(googleIDs(store).count)")

        // Leave Them: a new location, the old files stay, everything is downloaded again into the new root.
        let left = root.appendingPathComponent("Leave/Google Fonts", isDirectory: true)
        let requestsBeforeLeave = transport.requests
        do { try await controller.changeFolder(to: left, moveFiles: false) } catch { check(false, "google: leave folder", "\(error)") }
        let leaveSettled = await settled()
        check(leaveSettled && controller.phase == .idle && googleLocations().count == 1
              && controller.location.map { $0.id != loc.id && samePath($0.lastKnownPath, left) } == true
              && fm.fileExists(atPath: copied.appendingPathComponent("Smoke Sans/SmokeSans-Regular.ttf").path)
              && ["Smoke Sans", "Smoke Serif", "Smoke Mono"].allSatisfy {
                  fm.fileExists(atPath: left.appendingPathComponent("\($0)/\(FakeGoogleTransport.fileName($0))").path)
              }
              && transport.requests - requestsBeforeLeave >= 6 && googleIDs(store).count == 3
              && (try? store.googleProgress()).map { $0 == (3, 3) } == true,
              "google: leave folder re-downloads into new root", "\(controller.phase) \(googleLocations().count)")

        // Enable elsewhere fails after the run stopped (a file where the folder's parent should be): the location,
        // the download state and the phase come back as they were.
        let blocker = root.appendingPathComponent("Blocker")
        fm.createFile(atPath: blocker.path, contents: Data())
        let leftID = controller.location?.id
        // A run is going when it fails, so a missing restart would leave the phase stuck at downloading.
        transport.setFontDelay(.milliseconds(400))
        transport.set("Smoke Mono", modified: "2026-06-01", font: courier + Data(count: 8))
        await controller.checkForUpdates(force: true)
        let runningBeforeFailure = await eventually(within: .seconds(5)) { if case .downloading = controller.phase { return true }; return false }
        var enableFailed = false
        do { try await controller.enable(at: blocker.appendingPathComponent("Google Fonts")) } catch { enableFailed = true }
        let afterFailure = await settled()
        transport.setFontDelay(.zero)
        check(runningBeforeFailure && enableFailed && afterFailure && controller.phase == .idle && controller.location?.id == leftID
              && googleLocations().count == 1 && (try? store.googleProgress()).map { $0 == (3, 3) } == true,
              "google: a failed enable elsewhere restarts and changes nothing", "\(enableFailed) \(controller.phase)")

        // Pause, Stop Syncing and Remove from Library: files stay on disk.
        controller.pause()
        check(controller.phase == .paused && suite.bool(forKey: SettingsKey.googleFontsPaused), "google: pause")
        controller.disable()
        check(controller.phase == .off && !suite.bool(forKey: SettingsKey.googleFontsEnabled) && controller.location != nil,
              "google: disable keeps the location")
        do { try await controller.removeFromLibrary() } catch { check(false, "google: remove", "\(error)") }
        await model.waitForScansForSmoke()
        check(controller.location == nil && googleLocations().isEmpty && googleIDs(store).isEmpty
              && fm.fileExists(atPath: left.appendingPathComponent("Smoke Sans/SmokeSans-Regular.ttf").path),
              "google: remove from library keeps the files")

        let standardAfter = keys.map { String(describing: UserDefaults.standard.object(forKey: $0)) }
        check(standardAfter == standardBefore, "google: nothing written to the user's defaults")
    }

    /// The Google filter bar on the downloaded fixture (Smoke Mono: Monospace, vietnamese, popularity 1; Smoke Sans:
    /// Sans Serif, vietnamese, 2; Smoke Serif: Serif, latin only, 3): category, Vietnamese and Popular reach the
    /// browser's query; leaving the scope clears them and restores the previous sort.
    private static func googleFilterBarSteps(_ model: AppModel, store: FontStore) async {
        guard let mono = googleFace(store, postScriptName: "CourierNewPSMT"), let sans = googleFace(store, postScriptName: "ArialMT"),
              let serif = googleFace(store, postScriptName: "Georgia") else {
            check(false, "google ui: fixture faces", "\(googleIDs(store))"); return
        }
        model.clearFilters()
        model.chooseSort(.name)
        model.applySidebarSelection([.scope(.googleFonts)], modifiers: [])
        let all = await shown(model)
        check(all == [mono, sans, serif] && !model.showsGoogleEmptyState && model.showsGoogleFilterBar,
              "google ui: enabled scope shows the faces and the filter bar", "\(all) \(model.showsGoogleEmptyState)")

        model.filters.googleCategory = "Serif"
        let serifOnly = await shown(model)
        model.filters.googleCategory = "Monospace"
        let monoOnly = await shown(model)
        check(serifOnly == [serif] && monoOnly == [mono] && model.query.filters.googleCategory == "Monospace",
              "google ui: category filter narrows", "\(serifOnly) \(monoOnly)")
        model.filters.googleCategory = nil

        model.filters.googleVietnamese = true
        let vietnamese = await shown(model)
        check(vietnamese == [mono, sans] && model.query.filters.googleVietnamese,
              "google ui: vietnamese filter narrows", "\(vietnamese)")

        model.chooseSort(.popularity)
        model.filters.googleVietnamese = false
        _ = await shown(model)
        check(model.query.sort == .popularity && model.query.ascending && model.faceIDs == [mono, sans, serif],
              "google ui: popularity sort orders", "\(model.faceIDs)")

        model.filters.googleCategory = "Serif"
        model.filters.googleVietnamese = true
        model.applySidebarSelection([.scope(.all)], modifiers: [])
        check(model.filters.googleCategory == nil && !model.filters.googleVietnamese && model.query.filters.googleCategory == nil
              && !model.query.filters.googleVietnamese && model.query.sort == .name && model.query.ascending
              && !model.showsGoogleFilterBar,
              "google ui: leaving the scope clears the google filters and the popularity sort",
              "\(model.filters.googleCategory ?? "-") \(model.query.sort)")
        model.chooseSort(.family)
    }

    /// Polls (on the main actor) until `condition` holds or `budget` passes.
    private static func eventually(within budget: Duration, _ condition: () -> Bool) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now + budget
        while clock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }
}
#endif

/// A main-actor flag set by a smoke task.
@MainActor
private final class SmokeFlag {
    var value = false
}
