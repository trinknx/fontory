import Foundation

/// Assigns a coarse `StyleClass` from OS/2 `sFamilyClass`, PANOSE, CoreText's monospace trait, the cmap and the names.
/// The decision order is spec section 17, "Style classification", steps 1 to 7. Pure and stateless.
public enum StyleClassifier {
    /// Bump to reclassify every face in the background (see `FaceBackfill`). 2: version 1 was briefly computed
    /// without CoreText's class mask, so faces marked 1 may hold wrong classes. 3: a stray (3,0) cmap beside a
    /// Unicode one no longer makes a face Symbol.
    public static let version = 3

    public struct Input: Sendable, Hashable {
        public var familyClass: Int?      // sFamilyClass high byte
        public var familySubclass: Int?
        public var classMask: Int?        // CoreText symbolic-trait class (top 4 bits), same numbering as sFamilyClass
        public var panose: [UInt8]?       // 10 bytes
        public var isMonospace: Bool
        public var hasSymbolCmap: Bool    // a (3,0) subtable
        public var hasUnicodeCmap: Bool   // a (3,1), (3,10) or platform-0 subtable
        public var coversLatin: Bool
        public var names: [String]        // family, full name, style

        public init(familyClass: Int? = nil, familySubclass: Int? = nil, classMask: Int? = nil, panose: [UInt8]? = nil, isMonospace: Bool = false,
                    hasSymbolCmap: Bool = false, hasUnicodeCmap: Bool = false, coversLatin: Bool = true, names: [String] = []) {
            self.familyClass = familyClass
            self.familySubclass = familySubclass
            self.classMask = classMask
            self.panose = panose
            self.isMonospace = isMonospace
            self.hasSymbolCmap = hasSymbolCmap
            self.hasUnicodeCmap = hasUnicodeCmap
            self.coversLatin = coversLatin
            self.names = names
        }
    }

    public static func classify(_ input: Input) -> StyleClass {
        // OS/2 sFamilyClass is often 0 and PANOSE empty; CoreText's class mask is the second source for the same numbers.
        let classes = Set([input.familyClass ?? 0, input.classMask ?? 0])
        func cls(_ n: Int...) -> Bool { n.contains { classes.contains($0) } }
        let panose = input.panose.flatMap { $0.count >= 10 ? $0 : nil }
        let family = panose.map { Int($0[0]) }       // bFamilyType
        let serifStyle = panose.map { Int($0[1]) }   // bSerifStyle (meaningful for family 2, Latin text)
        let proportion = panose.map { Int($0[3]) }   // bProportion
        let name = input.names.joined(separator: " ").lowercased()
        func named(_ words: String...) -> Bool { words.contains { name.contains($0) } }

        // 1. Symbol. The cmap test stands in for "pictographic glyphs": a (3,0) subtable marks a symbol encoding,
        // but only when there is no Unicode subtable (legacy text fonts often carry a stray (3,0) beside (3,1)).
        if cls(12) || family == 5 || (input.hasSymbolCmap && !input.hasUnicodeCmap) { return .symbol }
        // 2. Mono
        if input.isMonospace || proportion == 9 { return .mono }
        // 3. Script
        if cls(10) || family == 3 || named("script", "hand", "brush", "calligraph") { return .script }
        // 4. Slab
        if cls(4, 5) || named("slab") { return .slab }
        // 5. Sans
        if cls(8) || (family == 2 && (11...13).contains(serifStyle ?? 0)) || named("sans", "grotesk", "gothic") { return .sans }
        // 6. Serif
        if cls(1, 2, 3, 7) || (family == 2 && (2...10).contains(serifStyle ?? 0)) || named("serif") { return .serif }
        // 7. Display
        if cls(9) || family == 4 || input.coversLatin { return .display }
        return .unknown
    }
}
