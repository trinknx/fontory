import CoreGraphics
import CoreText
import Foundation

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

    static func components(_ color: CGColor) -> [CGFloat] {
        let c = color.converted(to: sRGB, intent: .defaultIntent, options: nil) ?? color
        return (c.components ?? []).map { $0 + 0 }   // +0 folds -0 into 0
    }

    public static func == (a: PreviewRequest, b: PreviewRequest) -> Bool {
        a.text == b.text && a.pointSize == b.pointSize && a.tracking == b.tracking
            && a.foregroundComponents == b.foregroundComponents
            && a.backgroundComponents == b.backgroundComponents
            && a.alignment == b.alignment && a.smoothing == b.smoothing
            && a.size == b.size && a.scale == b.scale
    }

    public func hash(into h: inout Hasher) {
        h.combine(text); h.combine(pointSize); h.combine(tracking)
        h.combine(foregroundComponents); h.combine(backgroundComponents)
        h.combine(alignment.rawValue); h.combine(smoothing)
        h.combine(size.width); h.combine(size.height); h.combine(scale)
    }
}
