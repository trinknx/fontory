import Foundation

/// The Layouts and Templates folders: one pretty-printed JSON file per item, named `<name>.json`.
///
/// Built-in templates are recorded at install time: `installBuiltInTemplates(from:)` writes the bundle's
/// `order.json` (an array of file names; without one, every `.json` in the bundle sorted by name) into the
/// templates folder as the hidden `.builtin-order.json`. `listTemplates()` reads that file to know which
/// templates are built-in and in what order; hidden files are never listed.
public struct LayoutLibrary: Sendable {
    public struct Item: Sendable, Equatable {
        public let url: URL
        public let name: String
        public let isBuiltIn: Bool
        /// Non-nil when the file could not be read as a layout document.
        public let error: String?
    }

    public enum LibraryError: Error, Equatable { case nameTaken(String), invalidName }

    public let layoutsDirectory: URL
    public let templatesDirectory: URL
    static let orderFileName = "order.json"
    static let recordedOrderFileName = ".builtin-order.json"
    /// Names of built-ins already copied once; a later install skips them even if the user deleted the file.
    static let installedFileName = ".builtin-installed.json"

    public init(layoutsDirectory: URL, templatesDirectory: URL) {
        self.layoutsDirectory = layoutsDirectory
        self.templatesDirectory = templatesDirectory
    }

    public func listLayouts() -> [Item] { list(layoutsDirectory, builtIn: []) }

    public func listTemplates() -> [Item] {
        let recorded = Self.readOrder(templatesDirectory.appendingPathComponent(Self.recordedOrderFileName))
        let builtIn = recorded.map(Self.stem)
        return list(templatesDirectory, builtIn: builtIn)
    }

    public func load(_ url: URL) throws -> LayoutDocument {
        try JSONDecoder().decode(LayoutDocument.self, from: Data(contentsOf: url))
    }

    /// Atomic: written to a temporary file beside the destination, then moved into place.
    public func save(_ doc: LayoutDocument, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try Self.writeAtomically(try encoder.encode(doc), to: url)
    }

    public func newLayout(from template: URL) throws -> URL {
        try copyUnique(template, intoDirectory: layoutsDirectory, baseName: Self.stem(template.lastPathComponent))
    }

    public func duplicate(_ url: URL) throws -> URL {
        try copyUnique(url, intoDirectory: url.deletingLastPathComponent(), baseName: Self.stem(url.lastPathComponent))
    }

    public func rename(_ url: URL, to name: String) throws -> URL {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, !clean.contains("/"), !clean.contains(":"), !clean.hasPrefix(".") else { throw LibraryError.invalidName }
        let dest = url.deletingLastPathComponent().appendingPathComponent("\(clean).json")
        if dest.standardizedFileURL == url.standardizedFileURL { return url }
        guard !FileManager.default.fileExists(atPath: dest.path) else { throw LibraryError.nameTaken(clean) }
        try FileManager.default.moveItem(at: url, to: dest)
        return dest
    }

    /// Copies each bundled template once: an existing file is never overwritten, and one the user deleted is not
    /// restored (installed names are recorded in `.builtin-installed.json`). A newly bundled name is copied once.
    public func installBuiltInTemplates(from bundleDirectory: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: templatesDirectory, withIntermediateDirectories: true)
        var order = Self.readOrder(bundleDirectory.appendingPathComponent(Self.orderFileName))
        if order.isEmpty {
            let files = (try? fm.contentsOfDirectory(atPath: bundleDirectory.path)) ?? []
            order = files.filter { $0.hasSuffix(".json") && $0 != Self.orderFileName && !$0.hasPrefix(".") }
                .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        }
        let installedURL = templatesDirectory.appendingPathComponent(Self.installedFileName)
        var installed = Set(Self.readOrder(installedURL))
        for file in order where !installed.contains(file) {
            let src = bundleDirectory.appendingPathComponent(file)
            let dst = templatesDirectory.appendingPathComponent(file)
            guard fm.fileExists(atPath: src.path) else { continue }
            if !fm.fileExists(atPath: dst.path) { try Self.writeAtomically(try Data(contentsOf: src), to: dst) }
            installed.insert(file)
        }
        try Self.writeAtomically(try JSONEncoder().encode(installed.sorted()), to: installedURL)
        try Self.writeAtomically(try JSONEncoder().encode(order),
                                 to: templatesDirectory.appendingPathComponent(Self.recordedOrderFileName))
    }

    // MARK: - Helpers

    private func list(_ dir: URL, builtIn: [String]) -> [Item] {
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        let items: [Item] = files
            .filter { $0.pathExtension.lowercased() == "json" && !$0.lastPathComponent.hasPrefix(".") }
            .map { url in
                let name = Self.stem(url.lastPathComponent)
                var err: String?
                do { _ = try load(url) } catch { err = error.localizedDescription }
                return Item(url: url, name: name, isBuiltIn: builtIn.contains(name), error: err)
            }
        let first = items.filter(\.isBuiltIn).sorted { builtIn.firstIndex(of: $0.name)! < builtIn.firstIndex(of: $1.name)! }
        let rest = items.filter { !$0.isBuiltIn }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        return first + rest
    }

    private func copyUnique(_ src: URL, intoDirectory dir: URL, baseName: String) throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        var n = 1
        var dest = dir.appendingPathComponent("\(baseName).json")
        while fm.fileExists(atPath: dest.path) {
            n += 1
            dest = dir.appendingPathComponent("\(baseName) \(n).json")
        }
        try Self.writeAtomically(try Data(contentsOf: src), to: dest)
        return dest
    }

    static func stem(_ fileName: String) -> String {
        fileName.hasSuffix(".json") ? String(fileName.dropLast(5)) : fileName
    }

    static func readOrder(_ url: URL) -> [String] {
        guard let data = try? Data(contentsOf: url), let names = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return names
    }

    static func writeAtomically(_ data: Data, to url: URL) throws {
        let fm = FileManager.default
        let tmp = url.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).tmp")
        defer { try? fm.removeItem(at: tmp) }
        try data.write(to: tmp)
        if fm.fileExists(atPath: url.path) {
            _ = try fm.replaceItemAt(url, withItemAt: tmp)
        } else {
            try fm.moveItem(at: tmp, to: url)
        }
    }
}
