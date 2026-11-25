import Foundation
import Testing
@testable import FontoryCore

@Suite struct GoogleCatalogTests {
    private func catalog(count: Int) -> Data {
        var entries = ["{\"family\":\"ABeeZee\",\"category\":\"Sans Serif\",\"subsets\":[\"menu\",\"latin\",\"vietnamese\"],\"designers\":[\"Anja Meiners\"],\"lastModified\":\"2025-09-08\",\"popularity\":156}"]
        for i in 1..<max(count, 1) {
            entries.append("{\"family\":\"Fam\(i)\",\"category\":\"Serif\",\"subsets\":[\"latin\"],\"designers\":[],\"lastModified\":\"2024-01-01\",\"popularity\":\(i),\"size\":1234}")
        }
        let list = count == 0 ? "" : entries.joined(separator: ",")
        return Data(")]}'\n{\"axisRegistry\":[],\"familyMetadataList\":[\(list)]}".utf8)
    }

    private func manifest(_ refs: [String], files: [String] = ["OFL.txt"]) -> Data {
        let f = files.map { "{\"filename\":\"\($0)\",\"contents\":\"text of \($0)\"}" }.joined(separator: ",")
        let r = refs.map { "{\"filename\":\"\($0)\",\"url\":\"https://fonts.gstatic.com/s/x/\($0.replacingOccurrences(of: "/", with: "_"))\"}" }.joined(separator: ",")
        return Data(")]}'\n{\"zipName\":\"X.zip\",\"manifest\":{\"files\":[\(f)],\"fileRefs\":[\(r)]}}".utf8)
    }

    @Test func parsesCatalogAfterXSSIPrefix() throws {
        let fams = try GoogleCatalog.parseCatalog(catalog(count: 1000))
        #expect(fams.count == 1000)
        #expect(fams[0].family == "ABeeZee")
        #expect(fams[0].subsets.contains("vietnamese"))
        #expect(fams[0].popularity == 156)
        #expect(fams[0].size == nil)
        #expect(fams[1].size == 1234)
    }

    @Test func rejectsShortCatalog() {
        #expect(throws: GoogleCatalogError.tooFewFamilies(999)) {
            try GoogleCatalog.parseCatalog(catalog(count: 999))
        }
    }

    @Test func rejectsMalformedCatalog() {
        for s in ["garbage", "<html>nope</html>", ")]}'\n{\"other\":[]}", ""] {
            #expect(throws: GoogleCatalogError.malformed) {
                try GoogleCatalog.parseCatalog(Data(s.utf8), minimumFamilies: 0)
            }
        }
    }

    @Test func manifestPrefersStatic() throws {
        let m = try GoogleCatalog.parseManifest(manifest(["Roboto-VariableFont_wght.ttf", "static/Roboto-Bold.ttf", "static/Roboto-Thin.ttf"]))
        #expect(m.fontRefs.map(\.name) == ["Roboto-Bold.ttf", "Roboto-Thin.ttf"])
    }

    @Test func manifestFallsBackToVariableWhenNoStatic() throws {
        let m = try GoogleCatalog.parseManifest(manifest(["X-VariableFont_wght.ttf"]))
        #expect(m.fontRefs.map(\.name) == ["X-VariableFont_wght.ttf"])
    }

    @Test func manifestKeepsTxtOnly() throws {
        let m = try GoogleCatalog.parseManifest(manifest(["a.ttf"], files: ["OFL.txt", "README.txt", "README.md", "index.html"]))
        #expect(m.textFiles.map(\.name) == ["OFL.txt", "README.txt"])
        #expect(m.textFiles[0].contents == "text of OFL.txt")
    }

    @Test func manifestWithNoFontsThrows() {
        #expect(throws: GoogleCatalogError.noFonts) {
            try GoogleCatalog.parseManifest(manifest([]))
        }
    }

    @Test func folderNameSanitizesAndDedupes() {
        #expect(GoogleCatalog.folderName(for: "A/B:C", taken: []) == "A-B-C")
        #expect(GoogleCatalog.folderName(for: "Foo", taken: ["foo"]) == "Foo (2)")
        #expect(GoogleCatalog.folderName(for: "Foo", taken: ["foo", "foo (2)"]) == "Foo (3)")
    }

    @Test func manifestURLEncodesSpaces() {
        #expect(GoogleCatalog.manifestURL(for: "AR One Sans").absoluteString == "https://fonts.google.com/download/list?family=AR%20One%20Sans")
    }
}
