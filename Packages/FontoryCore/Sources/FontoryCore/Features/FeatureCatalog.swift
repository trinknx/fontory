import Foundation

/// The Features tab's groups, in display order.
public enum FeatureGroup: String, CaseIterable, Sendable, Hashable {
    case ligatures, alternates, letterCase, numbers, positional, other

    public var title: String {
        switch self {
        case .ligatures: "Ligatures"
        case .alternates: "Alternates"
        case .letterCase: "Letter Case"
        case .numbers: "Numbers"
        case .positional: "Positional"
        case .other: "Script-Specific & Other"
        }
    }
}

/// Human names, groups and defaults of the registered OpenType feature tags.
public enum FeatureCatalog {
    public struct Entry: Sendable, Hashable {
        public let name: String
        public let group: FeatureGroup
    }

    /// Known tags in display order within their group.
    private static let known: [(tag: String, name: String, group: FeatureGroup)] = [
        // Ligatures
        ("liga", "Standard Ligatures", .ligatures),
        ("clig", "Contextual Ligatures", .ligatures),
        ("dlig", "Discretionary Ligatures", .ligatures),
        ("hlig", "Historical Ligatures", .ligatures),
        ("rlig", "Required Ligatures", .ligatures),
        // Alternates (ssXX and cvXX are added by number)
        ("calt", "Contextual Alternates", .alternates),
        ("salt", "Stylistic Alternates", .alternates),
        ("swsh", "Swash", .alternates),
        ("cswh", "Contextual Swash", .alternates),
        ("aalt", "Access All Alternates", .alternates),
        ("hist", "Historical Forms", .alternates),
        ("nalt", "Alternate Annotation Forms", .alternates),
        ("rand", "Randomize", .alternates),
        ("titl", "Titling", .letterCase),
        // Letter case
        ("smcp", "Small Capitals", .letterCase),
        ("c2sc", "Small Capitals from Capitals", .letterCase),
        ("pcap", "Petite Capitals", .letterCase),
        ("c2pc", "Petite Capitals from Capitals", .letterCase),
        ("case", "Case-Sensitive Forms", .letterCase),
        ("unic", "Unicase", .letterCase),
        ("cpsp", "Capital Spacing", .positional),
        // Numbers
        ("lnum", "Lining Figures", .numbers),
        ("onum", "Oldstyle Figures", .numbers),
        ("pnum", "Proportional Figures", .numbers),
        ("tnum", "Tabular Figures", .numbers),
        ("frac", "Fractions", .numbers),
        ("afrc", "Alternative Fractions", .numbers),
        ("zero", "Slashed Zero", .numbers),
        ("sups", "Superscript", .numbers),
        ("subs", "Subscript", .numbers),
        ("sinf", "Scientific Inferiors", .numbers),
        ("ordn", "Ordinals", .numbers),
        ("numr", "Numerators", .numbers),
        ("dnom", "Denominators", .numbers),
        // Positional
        ("kern", "Kerning", .positional),
        ("mark", "Mark Positioning", .positional),
        ("mkmk", "Mark-to-Mark Positioning", .positional),
        ("dist", "Distances", .positional),
        ("curs", "Cursive Positioning", .positional),
        ("palt", "Proportional Alternate Widths", .positional),
        ("halt", "Alternate Half Widths", .positional),
        ("vkrn", "Vertical Kerning", .positional),
        ("vpal", "Proportional Alternate Vertical Metrics", .positional),
        ("vhal", "Alternate Vertical Half Metrics", .positional),
        ("opbd", "Optical Bounds", .positional),
        ("lfbd", "Left Bounds", .positional),
        ("rtbd", "Right Bounds", .positional),
        // Script-specific and other
        ("ccmp", "Glyph Composition / Decomposition", .other),
        ("locl", "Localized Forms", .other),
        ("rvrn", "Required Variation Alternates", .other),
        ("init", "Initial Forms", .other),
        ("medi", "Medial Forms", .other),
        ("med2", "Medial Forms #2", .other),
        ("fina", "Terminal Forms", .other),
        ("fin2", "Terminal Forms #2", .other),
        ("fin3", "Terminal Forms #3", .other),
        ("isol", "Isolated Forms", .other),
        ("rclt", "Required Contextual Alternates", .other),
        ("mset", "Mark Positioning via Substitution", .other),
        ("stch", "Stretching Glyph Decomposition", .other),
        ("jalt", "Justification Alternates", .other),
        ("rtla", "Right-to-Left Alternates", .other),
        ("rtlm", "Right-to-Left Mirrored Forms", .other),
        ("ltra", "Left-to-Right Alternates", .other),
        ("ltrm", "Left-to-Right Mirrored Forms", .other),
        ("abvf", "Above-Base Forms", .other),
        ("abvm", "Above-Base Mark Positioning", .other),
        ("abvs", "Above-Base Substitutions", .other),
        ("akhn", "Akhand", .other),
        ("blwf", "Below-Base Forms", .other),
        ("blwm", "Below-Base Mark Positioning", .other),
        ("blws", "Below-Base Substitutions", .other),
        ("cfar", "Conjunct Form After Ro", .other),
        ("cjct", "Conjunct Forms", .other),
        ("half", "Half Forms", .other),
        ("haln", "Halant Forms", .other),
        ("nukt", "Nukta Forms", .other),
        ("pref", "Pre-Base Forms", .other),
        ("pres", "Pre-Base Substitutions", .other),
        ("pstf", "Post-Base Forms", .other),
        ("psts", "Post-Base Substitutions", .other),
        ("rkrf", "Rakar Forms", .other),
        ("rphf", "Reph Form", .other),
        ("vatu", "Vattu Variants", .other),
        ("ljmo", "Leading Jamo Forms", .other),
        ("vjmo", "Vowel Jamo Forms", .other),
        ("tjmo", "Trailing Jamo Forms", .other),
        ("vert", "Vertical Writing", .other),
        ("vrt2", "Vertical Alternates and Rotation", .other),
        ("vrtr", "Vertical Alternates for Rotation", .other),
        ("vkna", "Vertical Kana Alternates", .other),
        ("hkna", "Horizontal Kana Alternates", .other),
        ("ruby", "Ruby Notation Forms", .other),
        ("pkna", "Proportional Kana", .other),
        ("fwid", "Full Widths", .other),
        ("hwid", "Half Widths", .other),
        ("pwid", "Proportional Widths", .other),
        ("qwid", "Quarter Widths", .other),
        ("twid", "Third Widths", .other),
        ("expt", "Expert Forms", .other),
        ("hojo", "Hojo Kanji Forms", .other),
        ("jp78", "JIS78 Forms", .other),
        ("jp83", "JIS83 Forms", .other),
        ("jp90", "JIS90 Forms", .other),
        ("jp04", "JIS2004 Forms", .other),
        ("nlck", "NLC Kanji Forms", .other),
        ("smpl", "Simplified Forms", .other),
        ("trad", "Traditional Forms", .other),
        ("tnam", "Traditional Name Forms", .other),
        ("ital", "Italics", .other),
        ("ornm", "Ornaments", .other),
        ("dtls", "Dotless Forms", .other),
        ("flac", "Flattened Accent Forms", .other),
        ("mgrk", "Mathematical Greek", .other),
        ("ssty", "Math Script-Style Alternates", .other),
        ("size", "Optical Size", .other),
        ("valt", "Alternate Vertical Metrics", .other),
    ]

    private static let table: [String: (index: Int, entry: Entry)] = {
        var out: [String: (Int, Entry)] = [:]
        for (i, k) in known.enumerated() where out[k.tag] == nil { out[k.tag] = (i, Entry(name: k.name, group: k.group)) }
        return out
    }()

    /// Name and group of a tag; unknown tags are named by the tag itself, in Script-Specific & Other.
    public static func entry(for tag: String) -> Entry {
        if let n = number(tag, prefix: "ss"), (1...20).contains(n) { return Entry(name: "Stylistic Set \(n)", group: .alternates) }
        if let n = number(tag, prefix: "cv"), (1...99).contains(n) { return Entry(name: "Character Variant \(n)", group: .alternates) }
        return table[tag]?.entry ?? Entry(name: "“\(tag)”", group: .other)
    }

    /// Display order within a group: catalog order, then ssXX, then cvXX, then unknown tags alphabetically.
    public static func sortKey(_ tag: String) -> (Int, String) {
        if let n = number(tag, prefix: "ss") { return (1000 + n, tag) }
        if let n = number(tag, prefix: "cv") { return (2000 + n, tag) }
        if let i = table[tag]?.index { return (i, tag) }
        return (10_000, tag)
    }

    /// Features shapers apply unless told otherwise: switching one of these off is what changes rendering.
    public static let onByDefault: Set<String> = [
        "liga", "clig", "rlig", "calt", "rclt", "kern", "mark", "mkmk", "ccmp", "locl", "rvrn", "dist", "curs",
        "init", "medi", "med2", "fina", "fin2", "fin3", "isol", "mset", "stch", "rtla", "rtlm", "ltra", "ltrm",
        "abvf", "abvm", "abvs", "akhn", "blwf", "blwm", "blws", "cfar", "cjct", "half", "haln", "nukt", "pref",
        "pres", "pstf", "psts", "rkrf", "rphf", "vatu", "ljmo", "vjmo", "tjmo",
    ]

    private static func number(_ tag: String, prefix: String) -> Int? {
        LayoutFeatureInventory.isNumbered(tag, prefix: prefix) ? Int(tag.dropFirst(2)) : nil
    }

    // MARK: Demo strings

    /// A short string that shows the feature off, for the tags where one exists.
    public static func demoText(for tag: String) -> String? {
        if number(tag, prefix: "ss") != nil || number(tag, prefix: "cv") != nil || tag == "salt" || tag == "aalt" {
            return "Rag & Quick Jagged Gyrus 0123456789"
        }
        return demo[tag]
    }

    private static let demo: [String: String] = [
        "liga": "fi fl ff ffi ffl", "clig": "fi fl ff ffi ffl", "dlig": "ct st sp Th fb fh fj fk",
        "hlig": "ct st sp ſt ſſ", "calt": "Contextual alternates", "swsh": "Quick Brown Fox Rag Jumps",
        "cswh": "Quick Brown Fox Rag Jumps", "hist": "ſlowly reſt", "titl": "TITLING CAPITALS",
        "smcp": "Small Capitals", "c2sc": "CAPITALS TO SMALL CAPS", "pcap": "Petite Capitals",
        "c2pc": "CAPITALS TO PETITE CAPS", "case": "(H-O-[M]-E) «¿¡HELLO!?» @HOME", "unic": "Unicase Text",
        "cpsp": "CAPITAL SPACING", "lnum": "0123456789", "onum": "0123456789", "pnum": "1111 0123456789",
        "tnum": "1111 0123456789", "frac": "1/2 3/4 5/8 7/16", "afrc": "1/2 3/4 5/8", "zero": "0 10 100 O0O",
        "sups": "x2 y3 E=mc2", "subs": "H2O CO2 x1", "sinf": "H2O C6H12O6", "ordn": "1a 2o No 1st 2nd",
        "numr": "123/456", "dnom": "123/456", "kern": "AVATAR Wave To Yo LT",
        "mark": "à é î õ ü ç ñ", "mkmk": "ệ ặ ẫ ổ ữ", "ccmp": "à é î õ ü ç ñ",
    ]
}
