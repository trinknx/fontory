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
                #expect(m.itemSize.height >= 90 && m.itemSize.height <= 520)
            }
        }
    }
}
