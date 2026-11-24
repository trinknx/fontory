import CoreGraphics
import Foundation

public struct LayoutSize: Codable, Sendable, Hashable {
    public var w: Double
    public var h: Double
    public init(w: Double, h: Double) { self.w = w; self.h = h }
}

/// Points, origin top-left.
public struct LayoutFrame: Codable, Sendable, Hashable {
    public var x: Double
    public var y: Double
    public var w: Double
    public var h: Double
    public init(x: Double, y: Double, w: Double, h: Double) { self.x = x; self.y = y; self.w = w; self.h = h }
}

public enum LayoutAlignment: String, Codable, Sendable, CaseIterable {
    case left, center, right, justified
}

/// A font named by a layout. Resolution (fingerprint + PostScript name, then a unique PostScript name) happens
/// elsewhere; the reference itself is kept verbatim so a layout survives a missing drive.
public struct FontReference: Codable, Sendable, Hashable {
    public var postScriptName: String
    public var family: String
    public var fingerprint: String?
    public var variations: [String: Double]?

    public init(postScriptName: String, family: String, fingerprint: String? = nil, variations: [String: Double]? = nil) {
        self.postScriptName = postScriptName
        self.family = family
        self.fingerprint = fingerprint
        self.variations = variations
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        postScriptName = try c.decodeIfPresent(String.self, forKey: .postScriptName) ?? ""
        family = try c.decodeIfPresent(String.self, forKey: .family) ?? ""
        fingerprint = try? c.decodeIfPresent(String.self, forKey: .fingerprint)
        variations = try? c.decodeIfPresent([String: Double].self, forKey: .variations)
    }
}

/// "#RRGGBB" strings to components or CGColor.
public enum LayoutColor {
    public static func isValid(_ hex: String) -> Bool { rgb(hex) != nil }

    public static func rgb(_ hex: String) -> (Double, Double, Double)? {
        guard hex.count == 7, hex.hasPrefix("#"), hex.dropFirst().allSatisfy(\.isHexDigit),
              let v = UInt32(hex.dropFirst(), radix: 16) else { return nil }
        return (Double((v >> 16) & 0xFF) / 255, Double((v >> 8) & 0xFF) / 255, Double(v & 0xFF) / 255)
    }

    /// sRGB colour, or nil for a malformed string.
    public static func cgColor(_ hex: String) -> CGColor? {
        guard let (r, g, b) = rgb(hex), let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        return CGColor(colorSpace: space, components: [r, g, b, 1])
    }
}

public struct LayoutBlock: Codable, Sendable, Equatable, Identifiable {
    public enum Kind: String, Codable, Sendable { case text, waterfall, charset }

    public var id: UUID
    public var kind: Kind
    public var frame: LayoutFrame
    public var text: String
    public var font: FontReference
    public var size: Double
    /// A multiple of the font size.
    public var lineHeight: Double
    /// 1/1000 em.
    public var tracking: Double
    public var alignment: LayoutAlignment
    public var color: String?
    /// Waterfall only.
    public var sizes: [Double]

    public init(id: UUID = UUID(), kind: Kind, frame: LayoutFrame, text: String, font: FontReference, size: Double,
                lineHeight: Double = 1.2, tracking: Double = 0, alignment: LayoutAlignment = .left,
                color: String? = nil, sizes: [Double] = []) {
        self.id = id; self.kind = kind; self.frame = frame; self.text = text; self.font = font; self.size = size
        self.lineHeight = lineHeight; self.tracking = tracking; self.alignment = alignment
        self.color = color; self.sizes = sizes
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decodeIfPresent(UUID.self, forKey: .id)) ?? UUID()
        kind = try c.decode(Kind.self, forKey: .kind)
        frame = try c.decode(LayoutFrame.self, forKey: .frame)
        text = (try? c.decodeIfPresent(String.self, forKey: .text)) ?? ""
        font = (try? c.decodeIfPresent(FontReference.self, forKey: .font)) ?? FontReference(postScriptName: "", family: "")
        size = (try? c.decodeIfPresent(Double.self, forKey: .size)) ?? 24
        lineHeight = (try? c.decodeIfPresent(Double.self, forKey: .lineHeight)) ?? 1.2
        tracking = (try? c.decodeIfPresent(Double.self, forKey: .tracking)) ?? 0
        alignment = (try? c.decodeIfPresent(LayoutAlignment.self, forKey: .alignment)) ?? .left
        let hex = try? c.decodeIfPresent(String.self, forKey: .color)
        color = hex.flatMap { $0 }.flatMap { LayoutColor.isValid($0) ? $0 : nil }
        sizes = (try? c.decodeIfPresent([Double].self, forKey: .sizes)) ?? []
    }
}

/// A layout page (also the shape of a template). Decoding is lenient so hand-edited files still open: unknown
/// keys are ignored, missing optionals take defaults, and a bad colour falls back to the default.
public struct LayoutDocument: Codable, Sendable, Equatable {
    public static let currentVersion = 1
    public static let defaultBackground = "#FFFFFF"
    public static let defaultForeground = "#000000"

    public var version: Int
    public var name: String
    public var pageSize: LayoutSize
    public var background: String
    public var foreground: String
    public var showMissing: Bool
    public var blocks: [LayoutBlock]
    public var candidates: [FontReference]

    public init(name: String, pageSize: LayoutSize, background: String = defaultBackground,
                foreground: String = defaultForeground, showMissing: Bool = true,
                blocks: [LayoutBlock] = [], candidates: [FontReference] = []) {
        self.version = Self.currentVersion
        self.name = name; self.pageSize = pageSize; self.background = background; self.foreground = foreground
        self.showMissing = showMissing; self.blocks = blocks; self.candidates = candidates
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = (try? c.decodeIfPresent(Int.self, forKey: .version)) ?? Self.currentVersion
        name = (try? c.decodeIfPresent(String.self, forKey: .name)) ?? "Untitled"
        pageSize = try c.decode(LayoutSize.self, forKey: .pageSize)
        func colour(_ key: CodingKeys, _ fallback: String) -> String {
            if let s = (try? c.decodeIfPresent(String.self, forKey: key)) ?? nil, LayoutColor.isValid(s) { return s }
            return fallback
        }
        background = colour(.background, Self.defaultBackground)
        foreground = colour(.foreground, Self.defaultForeground)
        showMissing = (try? c.decodeIfPresent(Bool.self, forKey: .showMissing)) ?? true
        // A wrong-typed array is treated as empty; a malformed block inside a well-typed array still fails the file.
        var decoded: [LayoutBlock] = []
        if var list = try? c.nestedUnkeyedContainer(forKey: .blocks) {
            while !list.isAtEnd { decoded.append(try list.decode(LayoutBlock.self)) }
        }
        blocks = decoded
        candidates = (try? c.decodeIfPresent([FontReference].self, forKey: .candidates)) ?? []
    }
}
