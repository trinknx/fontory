import CoreGraphics
import Foundation

/// Zoom-driven layout of the font grid. Pure function of (zoom, width) so it can be unit tested.
public struct GridMetrics: Sendable, Equatable {
    public let columns: Int
    public let itemSize: CGSize
    public let previewPointSize: CGFloat

    static let minItemWidth: CGFloat = 140

    public static func compute(zoom: Double, availableWidth: CGFloat, spacing: CGFloat = 12) -> GridMetrics {
        let z = CGFloat(min(1, max(0, zoom)))
        let minW = minItemWidth
        let targetW = minW + (availableWidth - spacing * 2 - minW) * z * z
        let columns = max(1, Int(floor((availableWidth - spacing) / (targetW + spacing))))
        let itemW = (availableWidth - spacing * CGFloat(columns + 1)) / CGFloat(columns)
        let itemH = min(520, max(90, itemW * 0.55))
        return GridMetrics(columns: columns,
                           itemSize: CGSize(width: itemW, height: itemH),
                           previewPointSize: itemH * 0.38)
    }
}
