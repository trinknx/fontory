import AppKit

/// A grid of equal items in one section, laid out arithmetically: the frame of item i follows from i, the column
/// count and the item size, so preparing the layout and changing the item size cost O(1), and a query returns only
/// the rows that intersect the rect. (A flow layout measures every item on each reload and invalidation, which is
/// O(n) on the main thread for fonts with 50 000+ glyphs.)
///
/// Columns fill the width; leftover width is spread between columns, as a flow layout does.
final class GlyphGridLayout: NSCollectionViewLayout {
    var itemSize = CGSize(width: 64, height: 64) {
        didSet { if itemSize != oldValue { invalidateLayout() } }
    }
    var spacing: CGFloat = 6
    var inset: CGFloat = 12

    private var count = 0
    private var width: CGFloat = 0
    private var columns = 1
    private var columnStep: CGFloat = 70

    private var availableWidth: CGFloat {
        guard let cv = collectionView else { return 0 }
        return cv.enclosingScrollView?.contentView.bounds.width ?? cv.bounds.width
    }

    override func prepare() {
        super.prepare()
        count = collectionView.map { $0.numberOfSections > 0 ? $0.numberOfItems(inSection: 0) : 0 } ?? 0
        width = availableWidth
        let usable = max(0, width - inset * 2)
        columns = max(1, Int((usable + spacing) / (itemSize.width + spacing)))
        let gap = columns > 1 ? max(spacing, (usable - CGFloat(columns) * itemSize.width) / CGFloat(columns - 1)) : 0
        columnStep = itemSize.width + gap
    }

    private var rows: Int { (count + columns - 1) / columns }
    private var rowStep: CGFloat { itemSize.height + spacing }

    override var collectionViewContentSize: NSSize {
        let height = rows == 0 ? 0 : inset * 2 + CGFloat(rows) * rowStep - spacing
        return NSSize(width: width, height: height)
    }

    func frame(ofItem index: Int) -> CGRect {
        let row = index / columns, column = index % columns
        return CGRect(x: inset + CGFloat(column) * columnStep, y: inset + CGFloat(row) * rowStep,
                      width: itemSize.width, height: itemSize.height)
    }

    /// The items whose rows intersect `rect`.
    func itemRange(in rect: CGRect) -> Range<Int> {
        guard count > 0, rect.height > 0 || rect.width > 0 else { return 0..<0 }
        let firstRow = max(0, Int(floor((rect.minY - inset) / rowStep)))
        let lastRow = min(rows - 1, Int(floor((rect.maxY - inset) / rowStep)))
        guard firstRow <= lastRow else { return 0..<0 }
        return (firstRow * columns)..<min(count, (lastRow + 1) * columns)
    }

    override func layoutAttributesForElements(in rect: NSRect) -> [NSCollectionViewLayoutAttributes] {
        itemRange(in: rect).compactMap { i in
            let frame = frame(ofItem: i)
            guard frame.intersects(rect) else { return nil }
            let attributes = NSCollectionViewLayoutAttributes(forItemWith: IndexPath(item: i, section: 0))
            attributes.frame = frame
            return attributes
        }
    }

    override func layoutAttributesForItem(at indexPath: IndexPath) -> NSCollectionViewLayoutAttributes? {
        guard indexPath.section == 0, (0..<count).contains(indexPath.item) else { return nil }
        let attributes = NSCollectionViewLayoutAttributes(forItemWith: indexPath)
        attributes.frame = frame(ofItem: indexPath.item)
        return attributes
    }

    override func shouldInvalidateLayout(forBoundsChange newBounds: NSRect) -> Bool {
        abs(availableWidth - width) > 0.5
    }
}
