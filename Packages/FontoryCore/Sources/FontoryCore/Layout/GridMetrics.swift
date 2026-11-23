import CoreGraphics
import Foundation

/// Size-driven layout of the font grid, as in Typeface: one slider sets the preview point size, and the column
/// count follows from it (smaller text, more fonts per row). Pure function of (zoom, width) so it can be unit tested.
public struct GridMetrics: Sendable, Equatable {
    public let columns: Int
    public let itemSize: CGSize
    public let previewPointSize: CGFloat

    /// The preview size range the zoom (0…1) spans, exponentially.
    public static let minPointSize: CGFloat = 8
    public static let maxPointSize: CGFloat = 200
    /// A cell aims to be this many times the point size wide (about one short sentence).
    static let widthPerPoint: CGFloat = 20
    static let minItemWidth: CGFloat = 160
    /// The cell's name strip and padding around the preview (matches `FontGridItem`).
    static let chromeHeight: CGFloat = 38
    static let lineHeightFactor: CGFloat = 1.6

    /// The preview point size for a zoom level (0…1, clamped), whole points.
    public static func pointSize(zoom: Double) -> CGFloat {
        let z = CGFloat(min(1, max(0, zoom)))
        return (minPointSize * pow(maxPointSize / minPointSize, z)).rounded()
    }

    /// The zoom level that shows `pointSize` (clamped to the range).
    public static func zoom(pointSize: CGFloat) -> Double {
        let p = min(maxPointSize, max(minPointSize, pointSize))
        return Double(log(p / minPointSize) / log(maxPointSize / minPointSize))
    }

    /// `singleColumn`: the list view, one font per row at any size.
    public static func compute(zoom: Double, availableWidth: CGFloat, spacing: CGFloat = 12,
                               singleColumn: Bool = false) -> GridMetrics {
        let points = pointSize(zoom: zoom)
        let targetW = max(minItemWidth, points * widthPerPoint)
        let columns = singleColumn ? 1 : max(1, Int(floor((availableWidth - spacing) / (targetW + spacing))))
        let itemW = (availableWidth - spacing * CGFloat(columns + 1)) / CGFloat(columns)
        let itemH = min(520, max(64, (chromeHeight + points * lineHeightFactor).rounded(.up)))
        return GridMetrics(columns: columns, itemSize: CGSize(width: itemW, height: itemH), previewPointSize: points)
    }
}
