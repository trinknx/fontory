import Foundation
import Testing
@testable import FontoryCore

@Suite struct GridMetricsTests {
    @Test func zoomExtremes() {
        #expect(GridMetrics.compute(zoom: 0, availableWidth: 1440).columns >= 8)
        #expect(GridMetrics.compute(zoom: 1, availableWidth: 1440).columns == 1)
        #expect(GridMetrics.compute(zoom: -5, availableWidth: 1440) == GridMetrics.compute(zoom: 0, availableWidth: 1440))
        #expect(GridMetrics.compute(zoom: 9, availableWidth: 1440) == GridMetrics.compute(zoom: 1, availableWidth: 1440))
    }

    @Test func monotonicColumns() {
        var last = Int.max
        for i in 0...100 {
            let c = GridMetrics.compute(zoom: Double(i) / 100, availableWidth: 1440).columns
            #expect(c <= last)
            last = c
        }
    }

    @Test func fillsRowExactly() {
        for width in [600.0, 1000, 1440, 2560] {
            for i in 0...20 {
                let m = GridMetrics.compute(zoom: Double(i) / 20, availableWidth: CGFloat(width))
                let total = CGFloat(m.columns) * m.itemSize.width + CGFloat(m.columns + 1) * 12
                #expect(abs(total - CGFloat(width)) <= 1)
                #expect(m.itemSize.height >= 64 && m.itemSize.height <= 520)
            }
        }
    }

    /// The slider is a point size: the preview uses it, and the cell is tall enough for it.
    @Test func pointSizeDrivesPreviewAndHeight() {
        #expect(GridMetrics.pointSize(zoom: 0) == GridMetrics.minPointSize)
        #expect(GridMetrics.pointSize(zoom: 1) == GridMetrics.maxPointSize)
        for i in 0...20 {
            let m = GridMetrics.compute(zoom: Double(i) / 20, availableWidth: 1440)
            #expect(m.previewPointSize == GridMetrics.pointSize(zoom: Double(i) / 20))
            #expect(m.itemSize.height - 38 >= m.previewPointSize * 1.6 - 1)
        }
    }

    @Test func zoomRoundTripsThroughPointSize() {
        for points in [8.0, 18, 36, 60, 144, 200] {
            #expect(GridMetrics.pointSize(zoom: GridMetrics.zoom(pointSize: CGFloat(points))) == CGFloat(points))
        }
    }

    /// Typeface-like density on a ~1000 pt wide window: 18 pt shows two columns, 60 pt one.
    @Test func columnsFollowPointSize() {
        let at18 = GridMetrics.compute(zoom: GridMetrics.zoom(pointSize: 18), availableWidth: 1000)
        let at60 = GridMetrics.compute(zoom: GridMetrics.zoom(pointSize: 60), availableWidth: 1000)
        #expect(at18.columns == 2)
        #expect(at60.columns == 1)
    }

    @Test func singleColumnKeepsOneFontPerRow() {
        for i in 0...20 {
            let zoom = Double(i) / 20
            let list = GridMetrics.compute(zoom: zoom, availableWidth: 1440, singleColumn: true)
            let grid = GridMetrics.compute(zoom: zoom, availableWidth: 1440)
            #expect(list.columns == 1)
            #expect(abs(list.itemSize.width - (1440 - 24)) <= 1)
            #expect(list.itemSize.height == grid.itemSize.height)
            #expect(list.previewPointSize == grid.previewPointSize)
        }
    }
}
