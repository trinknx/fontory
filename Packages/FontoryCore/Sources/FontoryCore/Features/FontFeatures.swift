import CoreText
import Foundation

/// One feature setting applied to a font: an OpenType tag with a value, or an AAT type/selector pair (for fonts
/// whose layout is `morx` only, where CoreText does not translate most OpenType tags).
public enum FontFeatureSetting: Sendable, Hashable {
    case openType(tag: String, value: Int)
    case aat(type: Int, selector: Int)

    /// The `kCTFontFeatureSettingsAttribute` entry.
    var attribute: [String: Any] {
        switch self {
        case let .openType(tag, value):
            [kCTFontOpenTypeFeatureTag as String: tag, kCTFontOpenTypeFeatureValue as String: value]
        case let .aat(type, selector):
            [kCTFontFeatureTypeIdentifierKey as String: type, kCTFontFeatureSelectorIdentifierKey as String: selector]
        }
    }

    var openTypeTag: String? {
        if case let .openType(tag, _) = self { return tag }
        return nil
    }
}

/// One switchable feature of a face, as the Features tab lists it.
public struct LayoutFeature: Sendable, Hashable, Identifiable {
    public enum Source: Sendable, Hashable {
        case openType
        /// An AAT selector; `exclusive` types allow one selector at a time.
        case aat(type: Int, selector: Int, exclusive: Bool)
    }

    /// The OpenType tag, or "aat:type:selector".
    public let id: String
    /// The OpenType tag; for AAT selectors the equivalent tag when there is an unambiguous one (for CSS).
    public let tag: String?
    public let name: String
    /// Secondary label: the tag, or the AAT feature type's name.
    public let detail: String
    public let group: FeatureGroup
    public let isOnByDefault: Bool
    public let source: Source

    /// The setting that turns the feature on or off; nil when "off" is simply the font's default (exclusive AAT).
    public func setting(on: Bool) -> FontFeatureSetting? {
        switch source {
        case .openType:
            guard let tag else { return nil }
            return .openType(tag: tag, value: on ? 1 : 0)
        case let .aat(type, selector, exclusive):
            if on { return .aat(type: type, selector: selector) }
            return exclusive ? nil : .aat(type: type, selector: selector | 1)   // non-exclusive: off = on + 1
        }
    }

    /// False for features CoreText applies even when switched off (`mark`, `mkmk`, `ccmp`): the switch still
    /// counts for CSS, but the sample cannot show it.
    public var previewsWhenOff: Bool {
        !(isOnByDefault && tag.map(FeatureCatalog.alwaysAppliedByCoreText.contains) == true)
    }

    /// A sample that shows the feature off, when one is known.
    public var demoText: String? { tag.flatMap(FeatureCatalog.demoText(for:)) }
}

/// The switchable features of a face: OpenType (`GSUB`/`GPOS`) when it has any, otherwise its AAT features.
public struct FontFeatureSet: Sendable, Equatable {
    public let inventory: LayoutFeatureInventory
    /// AAT features from `CTFontCopyFeatures`, used only when the face has no OpenType layout features.
    public let aatFeatures: [LayoutFeature]

    public init(inventory: LayoutFeatureInventory, aatFeatures: [LayoutFeature]) {
        self.inventory = inventory
        self.aatFeatures = aatFeatures
    }

    public static func read(_ font: CTFont) -> FontFeatureSet {
        let inventory = LayoutFeatureInventory.read(font)
        return FontFeatureSet(inventory: inventory, aatFeatures: inventory.isEmpty ? Self.aat(font) : [])
    }

    public var usesOpenType: Bool { !inventory.isEmpty }
    public var isEmpty: Bool { inventory.isEmpty && aatFeatures.isEmpty }

    /// The features for a picker selection, sorted by group and catalog order. AAT features ignore the selection.
    public func features(for selection: LayoutSelection) -> [LayoutFeature] {
        guard usesOpenType else { return aatFeatures }
        return Self.sorted(inventory.tags(for: selection).map { tag in
            let entry = FeatureCatalog.entry(for: tag)
            let fontName = inventory.featureNames[tag]
            return LayoutFeature(id: tag, tag: tag, name: fontName ?? entry.name,
                                 detail: fontName == nil ? tag : "\(tag) · \(entry.name)", group: entry.group,
                                 isOnByDefault: FeatureCatalog.onByDefault.contains(tag), source: .openType)
        })
    }

    static func sorted(_ features: [LayoutFeature]) -> [LayoutFeature] {
        let groupIndex = Dictionary(uniqueKeysWithValues: FeatureGroup.allCases.enumerated().map { ($1, $0) })
        return features.sorted { a, b in
            let ga = groupIndex[a.group]!, gb = groupIndex[b.group]!
            if ga != gb { return ga < gb }
            return FeatureCatalog.sortKey(a.tag ?? a.id) < FeatureCatalog.sortKey(b.tag ?? b.id)
        }
    }

    /// Features split into their non-empty groups, in group order.
    public static func grouped(_ features: [LayoutFeature]) -> [(group: FeatureGroup, features: [LayoutFeature])] {
        FeatureGroup.allCases.compactMap { group in
            let members = features.filter { $0.group == group }
            return members.isEmpty ? nil : (group, members)
        }
    }

    // MARK: AAT

    /// The face's AAT features: for exclusive types every non-default selector, for non-exclusive types each "on"
    /// (even) selector, which may be on by default. "All Typographic Features" is left out.
    static func aat(_ font: CTFont) -> [LayoutFeature] {
        guard let types = CTFontCopyFeatures(font) as? [[String: Any]] else { return [] }
        var out: [LayoutFeature] = []
        var seen = Set<String>()
        for type in types {
            guard let typeID = (type[kCTFontFeatureTypeIdentifierKey as String] as? NSNumber)?.intValue, typeID != 0,
                  let selectors = type[kCTFontFeatureTypeSelectorsKey as String] as? [[String: Any]] else { continue }
            let typeName = type[kCTFontFeatureTypeNameKey as String] as? String ?? "Feature \(typeID)"
            let exclusive = (type[kCTFontFeatureTypeExclusiveKey as String] as? NSNumber)?.boolValue ?? false
            for s in selectors {
                guard let selector = (s[kCTFontFeatureSelectorIdentifierKey as String] as? NSNumber)?.intValue else { continue }
                let isDefault = (s[kCTFontFeatureSelectorDefaultKey as String] as? NSNumber)?.boolValue ?? false
                if exclusive ? isDefault : selector % 2 != 0 { continue }
                let id = "aat:\(typeID):\(selector)"
                guard seen.insert(id).inserted else { continue }
                let name = s[kCTFontFeatureSelectorNameKey as String] as? String ?? "Selector \(selector)"
                out.append(LayoutFeature(id: id, tag: aatTag(type: typeID, selector: selector), name: name,
                                         detail: typeName, group: aatGroup(typeID), isOnByDefault: !exclusive && isDefault,
                                         source: .aat(type: typeID, selector: selector, exclusive: exclusive)))
            }
        }
        let groupIndex = Dictionary(uniqueKeysWithValues: FeatureGroup.allCases.enumerated().map { ($1, $0) })
        // Stable: keeps the font's own order within a group.
        return out.enumerated().sorted { a, b in
            let ga = groupIndex[a.element.group]!, gb = groupIndex[b.element.group]!
            return ga != gb ? ga < gb : a.offset < b.offset
        }.map(\.element)
    }

    /// Group of an AAT feature type (SFNTLayoutTypes.h numbering).
    static func aatGroup(_ type: Int) -> FeatureGroup {
        switch type {
        case 1: .ligatures                                   // ligatures
        case 3, 37, 38: .letterCase                          // letter case, lower case, upper case
        case 6, 10, 11, 21: .numbers                         // number spacing, vertical position, fractions, number case
        case 8, 17, 18, 35, 36: .alternates                  // smart swash, character alternatives, design complexity, stylistic / contextual alternates
        case 22: .positional                                 // kTextSpacingType: proportional / monospaced / half-width text (CoreText also lists "No Kerning" here)
        default: .other
        }
    }

    /// The OpenType equivalent of an AAT selector, where Apple's mapping is unambiguous.
    static func aatTag(type: Int, selector: Int) -> String? {
        switch (type, selector) {
        case (1, 2): "liga"
        case (1, 4): "dlig"
        case (1, 0): "rlig"
        case (3, 3), (37, 1): "smcp"
        case (38, 1): "c2sc"
        case (37, 2): "pcap"
        case (38, 2): "c2pc"
        case (6, 0): "tnum"
        case (6, 1): "pnum"
        case (10, 1): "sups"
        case (10, 2): "subs"
        case (10, 3): "ordn"
        case (10, 4): "sinf"
        case (11, 1): "afrc"                                 // vertical (nut) fractions
        case (11, 2): "frac"                                 // diagonal fractions
        case (36, 0): "calt"
        case (35, let s) where s >= 2 && s <= 40 && s % 2 == 0: String(format: "ss%02d", s / 2)
        default: nil
        }
    }
}

/// Turning features on and off, and the resulting settings and CSS.
public enum FeatureToggles {
    /// Whether a feature is on, given the user's switches (`states`, by feature id).
    public static func isOn(_ feature: LayoutFeature, _ states: [String: Bool]) -> Bool {
        states[feature.id] ?? feature.isOnByDefault
    }

    /// The states after switching `feature`; switching on an exclusive AAT selector switches off its siblings.
    /// States equal to the default are dropped.
    public static func toggled(_ feature: LayoutFeature, on: Bool, in features: [LayoutFeature],
                               states: [String: Bool]) -> [String: Bool] {
        var out = states
        out[feature.id] = on == feature.isOnByDefault ? nil : on
        if on, case let .aat(type, _, true) = feature.source {
            for other in features where other.id != feature.id {
                if case .aat(type, _, _) = other.source { out[other.id] = nil }
            }
        }
        return out
    }

    /// Settings for every listed feature whose state differs from its default, in list order.
    public static func settings(_ features: [LayoutFeature], states: [String: Bool]) -> [FontFeatureSetting] {
        features.compactMap { f in
            let on = isOn(f, states)
            return on == f.isOnByDefault ? nil : f.setting(on: on)
        }
    }

    /// Whether the settings switch kerning off (applied through `PreviewRequest.disablesKerning`, since CoreText
    /// ignores `"kern" 0`).
    public static func disablesKerning(_ settings: [FontFeatureSetting]) -> Bool {
        settings.contains(.openType(tag: "kern", value: 0))
    }

    /// How many switched features (states differing from the default) are not in `listed`, e.g. hidden by the
    /// script filter.
    public static func hiddenChanges(all: [LayoutFeature], listed: [LayoutFeature], states: [String: Bool]) -> Int {
        let shown = Set(listed.map(\.id))
        return all.filter { !shown.contains($0.id) && isOn($0, states) != $0.isOnByDefault }.count
    }

    /// `font-feature-settings` for the switched features: 1 for features turned on, 0 for default features turned
    /// off; `normal` when nothing differs. AAT selectors without an OpenType equivalent are left out.
    public static func css(_ features: [LayoutFeature], states: [String: Bool]) -> String {
        var seen = Set<String>()
        let parts: [String] = features.compactMap { f in
            let on = isOn(f, states)
            guard on != f.isOnByDefault, let tag = f.tag, seen.insert(tag).inserted else { return nil }
            return "\"\(tag)\" \(on ? 1 : 0)"
        }
        return "font-feature-settings: \(parts.isEmpty ? "normal" : parts.joined(separator: ", "));"
    }
}
