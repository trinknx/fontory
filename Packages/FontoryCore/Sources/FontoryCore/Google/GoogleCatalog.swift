import Foundation

public struct GoogleFamily: Sendable, Hashable {
    public let family: String
    public let category: String
    public let lastModified: String
    public let subsets: [String]
    public let designers: [String]
    public let popularity: Int
    public let size: Int?

    public init(family: String, category: String, lastModified: String, subsets: [String],
                designers: [String], popularity: Int, size: Int?) {
        self.family = family
        self.category = category
        self.lastModified = lastModified
        self.subsets = subsets
        self.designers = designers
        self.popularity = popularity
        self.size = size
    }
}

public struct GoogleManifest: Sendable {
    /// Licence / README files (`.txt` only), flattened to basenames.
    public let textFiles: [(name: String, contents: String)]
    /// Static fonts when present, otherwise top-level fonts; basenames flattened.
    public let fontRefs: [(name: String, url: URL)]

    public init(textFiles: [(name: String, contents: String)], fontRefs: [(name: String, url: URL)]) {
        self.textFiles = textFiles
        self.fontRefs = fontRefs
    }
}

public enum GoogleCatalogError: Error, Equatable {
    case malformed
    case tooFewFamilies(Int)
    case noFonts
}

public enum GoogleCatalog {
    public static let minimumFamilies = 1000
    public static let catalogURL = URL(string: "https://fonts.google.com/metadata/fonts")!

    public static func manifestURL(for family: String) -> URL {
        var c = URLComponents(string: "https://fonts.google.com/download/list")!
        c.percentEncodedQueryItems = [URLQueryItem(name: "family", value: encode(family))]
        return c.url!
    }

    private static func encode(_ s: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }

    /// Both Google JSON responses start with `)]}'`; parse from the first `{`.
    private static func jsonObject(_ data: Data) throws -> [String: Any] {
        guard let brace = data.firstIndex(of: UInt8(ascii: "{")),
              let obj = try? JSONSerialization.jsonObject(with: data[brace...]) as? [String: Any]
        else { throw GoogleCatalogError.malformed }
        return obj
    }

    public static func parseCatalog(_ data: Data, minimumFamilies: Int = minimumFamilies) throws -> [GoogleFamily] {
        let root = try jsonObject(data)
        guard let list = root["familyMetadataList"] as? [[String: Any]] else { throw GoogleCatalogError.malformed }
        let families: [GoogleFamily] = list.compactMap { e in
            guard let name = e["family"] as? String, !name.isEmpty else { return nil }
            return GoogleFamily(
                family: name,
                category: e["category"] as? String ?? "",
                lastModified: e["lastModified"] as? String ?? "",
                subsets: e["subsets"] as? [String] ?? [],
                designers: e["designers"] as? [String] ?? [],
                popularity: (e["popularity"] as? NSNumber)?.intValue ?? 0,
                size: (e["size"] as? NSNumber)?.intValue)
        }
        guard families.count >= minimumFamilies else { throw GoogleCatalogError.tooFewFamilies(families.count) }
        return families
    }

    public static func parseManifest(_ data: Data) throws -> GoogleManifest {
        let root = try jsonObject(data)
        guard let manifest = root["manifest"] as? [String: Any] else { throw GoogleCatalogError.malformed }
        let files = manifest["files"] as? [[String: Any]] ?? []
        let refs = manifest["fileRefs"] as? [[String: Any]] ?? []

        let texts: [(name: String, contents: String)] = files.compactMap { f in
            guard let n = f["filename"] as? String, n.lowercased().hasSuffix(".txt"),
                  let c = f["contents"] as? String else { return nil }
            return (basename(n), c)
        }

        let fonts: [(path: String, url: URL)] = refs.compactMap { r in
            guard let n = r["filename"] as? String, let u = r["url"] as? String,
                  let url = URL(string: u) else { return nil }
            let ext = (n as NSString).pathExtension.lowercased()
            guard ext == "ttf" || ext == "otf" else { return nil }
            return (n, url)
        }
        let statics = fonts.filter { $0.path.hasPrefix("static/") }
        let chosen = statics.isEmpty ? fonts.filter { !$0.path.contains("/") } : statics
        guard !chosen.isEmpty else { throw GoogleCatalogError.noFonts }
        return GoogleManifest(textFiles: texts, fontRefs: chosen.map { (basename($0.path), $0.url) })
    }

    private static func basename(_ path: String) -> String {
        path.split(separator: "/").last.map(String.init) ?? path
    }

    /// `taken` holds lowercased folder names already in use.
    public static func folderName(for family: String, taken: Set<String>) -> String {
        let base = family.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        guard taken.contains(base.lowercased()) else { return base }
        var n = 2
        while taken.contains("\(base) (\(n))".lowercased()) { n += 1 }
        return "\(base) (\(n))"
    }
}
