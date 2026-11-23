import Foundation

public enum LocationKind: Int, Sendable { case folder = 0, fileSet = 1, system = 2 }
public enum ActivationState: Int, Sendable { case off = 0, on = 1, temporary = 2 }
public enum OutlineType: String, Sendable { case truetype, cff, cff2, bitmap, unknown }

public struct LocationRecord: Sendable, Identifiable, Hashable {
    public var id: Int64
    public var kind: LocationKind
    public var volumeUUID: String
    public var relativePath: String
    public var displayName: String
    public var lastKnownPath: String
    public var online: Bool
    public var lastScan: Date?
}

public struct FileRecord: Sendable, Hashable {
    public var id: Int64
    public var locationID: Int64
    public var relativePath: String
    public var size: Int64
    public var mtime: Date
    public var format: String
    public var fingerprint: String

    public init(id: Int64 = 0, locationID: Int64, relativePath: String, size: Int64, mtime: Date, format: String, fingerprint: String) {
        self.id = id
        self.locationID = locationID
        self.relativePath = relativePath
        self.size = size
        self.mtime = mtime
        self.format = format
        self.fingerprint = fingerprint
    }
}

/// Vertical metrics in font units.
public struct FaceMetrics: Sendable, Hashable {
    public var unitsPerEm: Int
    public var ascender: Double
    public var descender: Double
    public var capHeight: Double
    public var xHeight: Double

    public init(unitsPerEm: Int, ascender: Double, descender: Double, capHeight: Double, xHeight: Double) {
        self.unitsPerEm = unitsPerEm
        self.ascender = ascender
        self.descender = descender
        self.capHeight = capHeight
        self.xHeight = xHeight
    }
}

public struct ParsedFace: Sendable, Hashable {
    public var faceIndex: Int
    public var postScriptName: String
    public var family: String
    public var style: String
    public var fullName: String
    public var weight: Double
    public var width: Double
    public var slant: Double
    public var isItalic: Bool
    public var isVariable: Bool
    public var axesJSON: String?
    public var vendor: String?
    public var designer: String?
    public var version: String?
    public var glyphCount: Int
    public var scriptsBitmask: Int64
    public var metrics: FaceMetrics
    public var fsType: Int?
    public var outlineType: OutlineType
    public var isColor: Bool
    public var isBitmap: Bool
    public var hasGSUB: Bool
    public var hasGPOS: Bool

    public init(
        faceIndex: Int = 0, postScriptName: String, family: String, style: String, fullName: String,
        weight: Double = 400, width: Double = 5, slant: Double = 0, isItalic: Bool = false, isVariable: Bool = false,
        axesJSON: String? = nil, vendor: String? = nil, designer: String? = nil, version: String? = nil,
        glyphCount: Int = 0, scriptsBitmask: Int64 = 0,
        metrics: FaceMetrics = FaceMetrics(unitsPerEm: 1000, ascender: 800, descender: -200, capHeight: 700, xHeight: 500),
        fsType: Int? = nil, outlineType: OutlineType = .truetype,
        isColor: Bool = false, isBitmap: Bool = false, hasGSUB: Bool = false, hasGPOS: Bool = false
    ) {
        self.faceIndex = faceIndex
        self.postScriptName = postScriptName
        self.family = family
        self.style = style
        self.fullName = fullName
        self.weight = weight
        self.width = width
        self.slant = slant
        self.isItalic = isItalic
        self.isVariable = isVariable
        self.axesJSON = axesJSON
        self.vendor = vendor
        self.designer = designer
        self.version = version
        self.glyphCount = glyphCount
        self.scriptsBitmask = scriptsBitmask
        self.metrics = metrics
        self.fsType = fsType
        self.outlineType = outlineType
        self.isColor = isColor
        self.isBitmap = isBitmap
        self.hasGSUB = hasGSUB
        self.hasGPOS = hasGPOS
    }
}

public struct FaceRow: Sendable, Identifiable, Hashable {
    public var id: Int64
    public var fileID: Int64
    public var faceIndex: Int
    public var postScriptName: String
    public var family: String
    public var style: String
    public var fullName: String
    public var weight: Double
    public var isVariable: Bool
    public var format: String
    public var vendor: String?
    public var version: String?
    public var glyphCount: Int
    public var activation: ActivationState
    public var lastActivated: Date?
    public var online: Bool
    /// nil when the file's location is offline.
    public var fileURL: URL?
    public var locationID: Int64
}

public struct FamilyGroup: Sendable, Identifiable, Hashable {
    /// family_key: lowercased effective family.
    public var id: String
    public var name: String
    public var faceIDs: [Int64]
    public var representativeID: Int64
}
