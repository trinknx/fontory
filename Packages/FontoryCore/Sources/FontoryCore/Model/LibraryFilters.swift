import Foundation

/// The toolbar Filters popover's state, ANDed into every library query (`LibraryQuery.filters`).
public struct LibraryFilters: Sendable, Hashable {
    public enum TriState: Sendable, Hashable { case any, only, exclude }
    public enum Outline: Sendable, Hashable { case any, trueType, cff, bitmap }
    public enum XHeight: Sendable, Hashable { case any, low, medium, high }

    /// Every character the face must have; whitespace is ignored and each Unicode scalar counts once.
    public var requiredCharacters: String = ""
    /// Index into `ScriptCoverage.scripts` (the face's script bit).
    public var scriptIndex: Int? = nil
    /// Covers every precomposed Vietnamese letter (`VietnameseLetters.scalars`).
    public var vietnamese = false
    /// nil = any.
    public var figures: FigureStyle? = nil
    /// OpenType tags, all required.
    public var features: [String] = []
    public var outline: Outline = .any
    public var variable: TriState = .any, color: TriState = .any
    public var xHeight: XHeight = .any

    public init() {}

    /// Unique required scalars, ascending.
    var requiredScalars: [UInt32] {
        let set = Set(requiredCharacters.unicodeScalars.filter { !$0.properties.isWhitespace }.map(\.value))
        return set.sorted()
    }

    /// Trimmed, non-empty, unique tags in the order given.
    var cleanFeatures: [String] {
        var seen = Set<String>()
        return features.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    public var isEmpty: Bool { activeCount == 0 }

    /// Filters in effect, for the toolbar badge: one per control (the feature list counts once).
    public var activeCount: Int {
        var n = 0
        if !requiredScalars.isEmpty { n += 1 }
        if scriptIndex != nil { n += 1 }
        if vietnamese { n += 1 }
        if figures != nil { n += 1 }
        if !cleanFeatures.isEmpty { n += 1 }
        if outline != .any { n += 1 }
        if variable != .any { n += 1 }
        if color != .any { n += 1 }
        if xHeight != .any { n += 1 }
        return n
    }

    /// x-height / cap-height band limits.
    static let lowBelow = 0.66, highAbove = 0.74

    /// WHERE clauses for the active filters, every value bound; none when `isEmpty`.
    func clauses() -> (clauses: [String], bindings: [SQLValue]) {
        var clauses: [String] = []
        var bindings: [SQLValue] = []

        var needed = Set(requiredScalars)
        if vietnamese { needed.formUnion(VietnameseLetters.scalars) }
        if !needed.isEmpty {
            // One probe of the face's coverage row; a face without one fails.
            clauses.append("EXISTS (SELECT 1 FROM face_coverage WHERE face_coverage.face_id = faces.id AND fontory_covers(face_coverage.ranges, ?))")
            bindings.append(.blob(Self.encode(needed.sorted())))
        }
        if let scriptIndex {
            if scriptIndex >= 0 && scriptIndex < ScriptCoverage.scripts.count && scriptIndex < 63 {
                clauses.append("((faces.scripts_bitmask >> ?) & 1) = 1")
                bindings.append(.int(Int64(scriptIndex)))
            } else {
                clauses.append("0")
            }
        }
        if let figures {
            clauses.append("faces.figure_style = ?")
            bindings.append(.int(Int64(figures.rawValue)))
        }
        for tag in cleanFeatures {
            clauses.append("instr(faces.features, ' ' || ? || ' ') > 0")
            bindings.append(.text(tag))
        }
        switch outline {
        case .any: break
        case .trueType: clauses.append("faces.outline_type = ?"); bindings.append(.text("truetype"))
        case .cff: clauses.append("faces.outline_type IN (?, ?)"); bindings += [.text("cff"), .text("cff2")]
        case .bitmap: clauses.append("faces.outline_type = ?"); bindings.append(.text("bitmap"))
        }
        for (state, column) in [(variable, "faces.is_variable"), (color, "faces.is_color")] {
            switch state {
            case .any: break
            case .only: clauses.append("\(column) != 0")
            case .exclude: clauses.append("\(column) = 0")
            }
        }
        if xHeight != .any {
            // No metrics, no band.
            let ratio = "faces.x_height / faces.cap_height"
            let band: String
            switch xHeight {
            case .low: band = "\(ratio) < ?"; bindings.append(.double(Self.lowBelow))
            case .medium: band = "\(ratio) >= ? AND \(ratio) <= ?"; bindings += [.double(Self.lowBelow), .double(Self.highAbove)]
            default: band = "\(ratio) > ?"; bindings.append(.double(Self.highAbove))
            }
            clauses.append("faces.x_height > 0 AND faces.cap_height > 0 AND \(band)")
        }
        return (clauses, bindings)
    }

    /// Little-endian `UInt32` per scalar, the `needed` argument of `fontory_covers`.
    static func encode(_ scalars: [UInt32]) -> Data {
        var data = Data(count: scalars.count * 4)
        data.withUnsafeMutableBytes { raw in
            for (i, s) in scalars.enumerated() { raw.storeBytes(of: s.littleEndian, toByteOffset: i * 4, as: UInt32.self) }
        }
        return data
    }
}

/// The precomposed Vietnamese letters (upper and lower case) of `PreviewSamples.accented`'s Vietnamese part.
public enum VietnameseLetters {
    public static let scalars: [UInt32] = {
        let text = PreviewSamples.accented.text
        guard let start = text.range(of: "Ă") else { return [] }
        let letters = text[start.lowerBound...].unicodeScalars.filter { !$0.properties.isWhitespace }
        return Set(letters.map(\.value)).sorted()
    }()
}

/// The `needed` argument of `fontory_covers` as runs of consecutive scalars. It is the same for every row of a query,
/// so SQLite keeps one per statement (auxiliary data) and a row costs one search per run, not per scalar.
final class NeededRuns {
    let starts: [UInt32], ends: [UInt32]

    /// `needed`: little-endian `UInt32` scalars in any order.
    init(needed: UnsafeRawBufferPointer) {
        var scalars = [UInt32](repeating: 0, count: needed.count / 4)
        scalars.withUnsafeMutableBytes { dst in
            if let src = needed.baseAddress, dst.count > 0 { memcpy(dst.baseAddress!, src, dst.count) }
        }
        scalars = scalars.map { UInt32(littleEndian: $0) }.sorted()
        var starts: [UInt32] = [], ends: [UInt32] = []
        for scalar in scalars {
            if let last = ends.last, scalar <= last || (last < .max && scalar == last + 1) {
                ends[ends.count - 1] = max(last, scalar)
            } else {
                starts.append(scalar)
                ends.append(scalar)
            }
        }
        self.starts = starts
        self.ends = ends
    }

    /// Aligned copy of the row's ranges, reused across rows: typed reads are far cheaper than unaligned loads. Statements
    /// run one at a time under the connection lock, and each statement has its own `NeededRuns`.
    private var scratch = UnsafeMutablePointer<UInt32>.allocate(capacity: 1024)
    private var capacity = 1024

    deinit { scratch.deallocate() }

    /// True when every run lies inside one range of `ranges` (little-endian `UInt32` `[start, end]` pairs, sorted,
    /// merged). The search resumes where the last run ended, and the ends of the list reject most misses at once.
    func covered(by ranges: UnsafeRawBufferPointer) -> Bool {
        let pairs = ranges.count / 8
        guard !starts.isEmpty else { return true }
        guard pairs > 0, let base = ranges.baseAddress else { return false }
        if pairs * 2 > capacity {
            scratch.deallocate()
            capacity = pairs * 2
            scratch = .allocate(capacity: capacity)
        }
        memcpy(scratch, base, pairs * 8)
        let w = scratch   // w[2i] = start, w[2i + 1] = end (little-endian host: Apple platforms)
        guard starts[0] >= w[0], ends[ends.count - 1] <= w[pairs * 2 - 1] else { return false }
        var lo = 0
        for r in 0..<starts.count {
            let s = starts[r]
            var hi = pairs
            while lo < hi {
                let mid = (lo + hi) / 2
                if w[mid * 2 + 1] < s { lo = mid + 1 } else { hi = mid }
            }
            guard lo < pairs, w[lo * 2] <= s, w[lo * 2 + 1] >= ends[r] else { return false }
        }
        return true
    }
}
