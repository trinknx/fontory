import Foundation

/// Everything the index knows about one face, for the family page's Info tab. Read by `FontStore.faceInfo(id:)`.
public struct FaceInfo: Sendable, Hashable, Identifiable {
    public var id: Int64
    public var faceIndex: Int
    public var postScriptName: String
    public var fullName: String
    /// The family as shown (a custom family when one is set).
    public var family: String
    /// The family name stored in the font.
    public var fontFamily: String
    public var style: String
    public var version: String?
    public var vendor: String?
    public var designer: String?
    public var format: String
    /// Built from the location's last known path, whether or not it is online.
    public var fileURL: URL
    public var online: Bool
    public var fileSize: Int64
    public var addedAt: Date?
    public var glyphCount: Int
    public var weight: Double
    public var width: Double
    public var slant: Double
    public var isItalic: Bool
    public var metrics: FaceMetrics
    /// The OS/2 `fsType` field; nil when the font has no OS/2 table.
    public var fsType: Int?
    public var outlineType: OutlineType
    public var isColor: Bool
    public var isBitmap: Bool
    public var isVariable: Bool
    public var axes: [VariationAxis]
    public var hasGSUB: Bool
    public var hasGPOS: Bool
    public var note: String?
    public var activation: ActivationState
    public var lastActivated: Date?
    public var locationKind: LocationKind

    public var embedding: EmbeddingPermissions? { fsType.map(EmbeddingPermissions.init(fsType:)) }
}

/// One axis of a variable font, as stored in `faces.axes_json`.
public struct VariationAxis: Sendable, Hashable, Codable {
    public var tag: String
    public var name: String?
    public var min: Double
    public var max: Double
    public var defaultValue: Double

    public init(tag: String, name: String?, min: Double, max: Double, defaultValue: Double) {
        self.tag = tag
        self.name = name
        self.min = min
        self.max = max
        self.defaultValue = defaultValue
    }

    private enum CodingKeys: String, CodingKey {
        case tag, name, min, max
        case defaultValue = "default"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        tag = (try? c.decodeIfPresent(String.self, forKey: .tag)) ?? "????"
        name = try? c.decodeIfPresent(String.self, forKey: .name)
        min = (try? c.decodeIfPresent(Double.self, forKey: .min)) ?? 0
        max = (try? c.decodeIfPresent(Double.self, forKey: .max)) ?? 0
        defaultValue = (try? c.decodeIfPresent(Double.self, forKey: .defaultValue)) ?? min
    }

    /// The axes in `axes_json`; empty for nil or unreadable JSON.
    public static func decode(json: String?) -> [VariationAxis] {
        guard let json, let data = json.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([VariationAxis].self, from: data)) ?? []
    }
}

/// The embedding licensing rights in the OS/2 `fsType` field (OpenType spec, OS/2 table).
public struct EmbeddingPermissions: Sendable, Hashable {
    public enum Usage: Sendable, Hashable {
        /// 0: may be embedded and permanently installed.
        case installable
        /// Bit 1: must not be embedded without the legal owner's permission.
        case restricted
        /// Bit 2: may be embedded for previewing and printing, not editing.
        case previewAndPrint
        /// Bit 3: may be embedded in documents that are edited.
        case editable

        public var title: String {
            switch self {
            case .installable: "Installable"
            case .restricted: "Restricted License"
            case .previewAndPrint: "Preview & Print"
            case .editable: "Editable"
            }
        }
    }

    public var fsType: Int
    public var usage: Usage
    /// Bit 8: the font must not be subset before embedding.
    public var noSubsetting: Bool
    /// Bit 9: only bitmaps in the font may be embedded.
    public var bitmapOnly: Bool

    /// Older fonts may set several usage bits; the least restrictive one applies
    /// (editable, then preview & print, then restricted). No usage bit means installable; bit 0 is reserved.
    public init(fsType: Int) {
        self.fsType = fsType
        if fsType & 0x0008 != 0 {
            usage = .editable
        } else if fsType & 0x0004 != 0 {
            usage = .previewAndPrint
        } else if fsType & 0x0002 != 0 {
            usage = .restricted
        } else {
            usage = .installable
        }
        noSubsetting = fsType & 0x0100 != 0
        bitmapOnly = fsType & 0x0200 != 0
    }

    /// "Editable", "Preview & Print · No subsetting · Bitmap only", …
    public var summary: String {
        var parts = [usage.title]
        if noSubsetting { parts.append("No subsetting") }
        if bitmapOnly { parts.append("Bitmap embedding only") }
        return parts.joined(separator: " · ")
    }

    /// The field as hex, e.g. "0x0108".
    public var hex: String {
        let s = String(fsType & 0xFFFF, radix: 16, uppercase: true)
        return "0x" + String(repeating: "0", count: max(0, 4 - s.count)) + s
    }
}
