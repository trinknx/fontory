import CoreGraphics
import CoreText
import Foundation

/// OpenType features a preview can switch. `standard` (ligatures only) is the font's default behavior.
public struct PreviewFeatures: OptionSet, Sendable, Hashable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    /// `liga` (and `clig`); on by default, so turning it off is what changes rendering.
    public static let ligatures = PreviewFeatures(rawValue: 1 << 0)
    /// `dlig`.
    public static let discretionaryLigatures = PreviewFeatures(rawValue: 1 << 1)
    /// `salt` + `swsh`.
    public static let alternates = PreviewFeatures(rawValue: 1 << 2)
    /// `smcp`, plus `c2sc` when the text is all capitals.
    public static let smallCaps = PreviewFeatures(rawValue: 1 << 3)

    public static let standard: PreviewFeatures = [.ligatures]
}

/// Everything that determines a rendered preview bitmap. Hashable so callers can use it as (part of) a cache key;
/// colors are compared by their sRGB components, not object identity.
public struct PreviewRequest: Sendable, Hashable {
    public var text: String
    public var pointSize: CGFloat
    public var tracking: CGFloat = 0
    public var foreground: CGColor { didSet { foregroundComponents = Self.components(foreground) } }
    public var background: CGColor { didSet { backgroundComponents = Self.components(background) } }
    public var alignment: CTTextAlignment = .left
    public var smoothing: Bool = true
    /// Dashed baseline, x-height, cap-height, ascender and descender lines behind the text.
    public var showGuides = false
    /// Characters the face lacks are drawn as a dotted-circle placeholder instead of a fallback font.
    public var showMissingGlyphs = false
    /// Glyphs are stroked, not filled.
    public var outline = false
    public var underline = false
    public var features: PreviewFeatures = .standard
    /// Further feature settings (Features tab), applied after `features`; a tag set here overrides the same tag
    /// from `features`.
    public var featureSettings: [FontFeatureSetting] = []
    /// Kerning off. CoreText ignores `"kern" 0` in feature settings, so this sets `kCTKernAttributeName` to 0
    /// instead; non-zero tracking takes precedence.
    public var disablesKerning = false
    /// BCP 47 language of the text (`kCTLanguageAttributeName`), which selects `locl` forms; nil for none.
    public var language: String?
    /// Variation-axis coordinates (axis tag code → value, `kCTFontVariationAttribute`); empty keeps the font's
    /// default instance.
    public var variations: [UInt32: Double] = [:]
    public var size: CGSize          // in points; pixel size = size * scale
    public var scale: CGFloat
    /// sRGB components, computed once when a color is set so == and hash never convert colors.
    private var foregroundComponents: [CGFloat]
    private var backgroundComponents: [CGFloat]

    public init(text: String, pointSize: CGFloat, tracking: CGFloat = 0,
                foreground: CGColor, background: CGColor,
                alignment: CTTextAlignment = .left, smoothing: Bool = true,
                size: CGSize, scale: CGFloat) {
        self.text = text; self.pointSize = pointSize; self.tracking = tracking
        self.foreground = foreground; self.background = background
        self.alignment = alignment; self.smoothing = smoothing
        self.size = size; self.scale = scale
        foregroundComponents = Self.components(foreground)
        backgroundComponents = Self.components(background)
    }

    static let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

    /// sRGB components of a color (gray colors are converted).
    public static func components(_ color: CGColor) -> [CGFloat] {
        let c = color.converted(to: sRGB, intent: .defaultIntent, options: nil) ?? color
        return (c.components ?? []).map { $0 + 0 }   // +0 folds -0 into 0
    }

    public static func == (a: PreviewRequest, b: PreviewRequest) -> Bool {
        a.text == b.text && a.pointSize == b.pointSize && a.tracking == b.tracking
            && a.foregroundComponents == b.foregroundComponents
            && a.backgroundComponents == b.backgroundComponents
            && a.alignment == b.alignment && a.smoothing == b.smoothing
            && a.size == b.size && a.scale == b.scale
            && a.showGuides == b.showGuides && a.showMissingGlyphs == b.showMissingGlyphs
            && a.outline == b.outline && a.underline == b.underline && a.features == b.features
            && a.featureSettings == b.featureSettings && a.disablesKerning == b.disablesKerning
            && a.language == b.language && a.variations == b.variations
    }

    public func hash(into h: inout Hasher) {
        h.combine(text); h.combine(pointSize); h.combine(tracking)
        h.combine(foregroundComponents); h.combine(backgroundComponents)
        h.combine(alignment.rawValue); h.combine(smoothing)
        h.combine(size.width); h.combine(size.height); h.combine(scale)
        h.combine(showGuides); h.combine(showMissingGlyphs); h.combine(outline); h.combine(underline)
        h.combine(features.rawValue)
        h.combine(featureSettings)
        h.combine(disablesKerning)
        h.combine(language)
        h.combine(variations)
    }
}
