import CoreText
import Foundation

/// A `FontReference` looked up in the library. The reference is carried verbatim so a layout whose fonts sit on
/// an unplugged drive keeps them: it draws in the system font, and plugging the drive back restores the look.
public struct ResolvedFont: Sendable {
    public var reference: FontReference
    public var faceID: Int64?
    /// The font file; nil when the face is unresolved or its location is offline.
    public var url: URL?
    public var faceIndex: Int
    /// True when unresolved or offline: the font cannot be drawn from a file.
    public var isMissing: Bool

    public init(reference: FontReference, faceID: Int64?, url: URL?, faceIndex: Int, isMissing: Bool) {
        self.reference = reference
        self.faceID = faceID
        self.url = url
        self.faceIndex = faceIndex
        self.isMissing = isMissing
    }
}

/// One style of a family in the order the family list uses, then the named instances of its variable faces.
public struct PairingStyle: Sendable, Hashable {
    public var reference: FontReference
    public var name: String
    public var weight: Double
    public var width: Double
    public var isItalic: Bool

    public init(reference: FontReference, name: String, weight: Double, width: Double, isItalic: Bool) {
        self.reference = reference
        self.name = name
        self.weight = weight
        self.width = width
        self.isItalic = isItalic
    }
}

extension FontStore {
    private struct LocatedFace {
        var id: Int64
        var faceIndex: Int
        var url: URL?
    }

    private static let locateColumns = """
    SELECT faces.id, faces.face_index, locations.online, locations.last_known_path, files.relative_path
    FROM faces JOIN files ON files.id = faces.file_id JOIN locations ON locations.id = files.location_id
    """

    private static func located(_ s: Statement) -> LocatedFace {
        var url: URL?
        if s.int64(2) != 0 {
            let base = URL(fileURLWithPath: s.text(3))
            let rel = s.text(4)
            url = rel.isEmpty ? base : base.appendingPathComponent(rel)
        }
        return LocatedFace(id: s.int64(0), faceIndex: Int(s.int64(1)), url: url)
    }

    /// Looks each reference up: fingerprint plus PostScript name first, then a PostScript name that is unique in
    /// the library. Anything else is unresolved. "Unique" means one font file identity: copies of one file (rows
    /// sharing `files.fingerprint`, e.g. the same font in two folders) count as a single font. Among copies an
    /// online one is preferred, then the lowest face id. An offline face keeps its `faceID` but has no `url`.
    public func resolve(_ refs: [FontReference]) throws -> [FontReference: ResolvedFont] {
        try reader.withLock {
            var out: [FontReference: ResolvedFont] = [:]
            let byFingerprint = try reader.prepare(Self.locateColumns
                + " WHERE files.fingerprint = ?1 AND faces.postscript_name = ?2"
                + " ORDER BY locations.online DESC, faces.id LIMIT 1")
            defer { byFingerprint.reset() }
            // The preferred copy of each fingerprint carrying the name; two rows mean two different fonts.
            let byName = try reader.prepare(Self.locateColumns + """
                 WHERE faces.id IN (
                   SELECT (SELECT f2.id FROM faces f2 JOIN files fi2 ON fi2.id = f2.file_id
                           JOIN locations l2 ON l2.id = fi2.location_id
                           WHERE f2.postscript_name = ?1 AND fi2.fingerprint = fi.fingerprint
                           ORDER BY l2.online DESC, f2.id LIMIT 1)
                   FROM faces fa JOIN files fi ON fi.id = fa.file_id
                   WHERE fa.postscript_name = ?1 GROUP BY fi.fingerprint LIMIT 2)
                """)
            defer { byName.reset() }
            for ref in refs where out[ref] == nil {
                var found: LocatedFace?
                if let fp = ref.fingerprint {
                    byFingerprint.reset()
                    try byFingerprint.bind([.text(fp), .text(ref.postScriptName)])
                    if try byFingerprint.step() { found = Self.located(byFingerprint) }
                    byFingerprint.reset()
                }
                if found == nil {
                    byName.reset()
                    try byName.bind([.text(ref.postScriptName)])
                    var rows: [LocatedFace] = []
                    while try byName.step() { rows.append(Self.located(byName)) }
                    byName.reset()
                    if rows.count == 1 { found = rows[0] }
                }
                if let found {
                    out[ref] = ResolvedFont(reference: ref, faceID: found.id, url: found.url, faceIndex: found.faceIndex,
                                            isMissing: found.url == nil)
                } else {
                    out[ref] = ResolvedFont(reference: ref, faceID: nil, url: nil, faceIndex: 0, isMissing: true)
                }
            }
            return out
        }
    }

    /// The reference to a face: its PostScript name, effective family and file fingerprint.
    public func reference(forFace id: Int64) throws -> FontReference {
        try reader.withLock {
            let s = try reader.prepare("""
            SELECT faces.postscript_name, \(LibraryQuery.effectiveFamily), files.fingerprint
            FROM faces JOIN files ON files.id = faces.file_id WHERE faces.id = ?
            """)
            defer { s.reset() }
            try s.bind([.int(id)])
            guard try s.step() else { throw LayoutFontError.noSuchFace(id) }
            return FontReference(postScriptName: s.text(0), family: s.text(1), fingerprint: s.text(2))
        }
    }

    /// One reference per effective family among `faceIDs` (compared lowercased), in first-seen order, each to the
    /// family's representative face.
    public func candidateReferences(faceIDs: [Int64]) throws -> [FontReference] {
        var order: [String] = []
        var first: [String: Int64] = [:]
        var names: [String: String] = [:]
        for id in faceIDs {
            guard let ref = try? reference(forFace: id) else { continue }
            let key = ref.family.lowercased()
            if first[key] == nil { first[key] = id; names[key] = ref.family; order.append(key) }
        }
        return try order.compactMap { key in
            if let group = try family(named: names[key]!, includeSystem: true) {
                return try reference(forFace: group.representativeID)
            }
            return try reference(forFace: first[key]!)
        }
    }

    /// The faces of the family of `ref`, sorted as in `families(for:)`, followed by each variable face's named
    /// instances (the same file and face with `variations` set).
    public func styles(ofFamilyOf ref: FontReference) throws -> [PairingStyle] {
        var group = try family(named: ref.family, includeSystem: true)
        if group == nil, let face = try resolve([ref])[ref]?.faceID {
            group = try family(named: try reference(forFace: face).family, includeSystem: true)
        }
        guard let group else { return [] }

        struct Row {
            var style: PairingStyle
            var isVariable: Bool
            var faceIndex: Int
            var url: URL?
        }
        let rows: [Row] = try reader.withLock {
            let s = try reader.prepare("""
            SELECT faces.postscript_name, faces.style, faces.weight, faces.width, faces.is_italic, faces.is_variable,
              faces.face_index, files.fingerprint, locations.online, locations.last_known_path, files.relative_path
            FROM faces JOIN files ON files.id = faces.file_id JOIN locations ON locations.id = files.location_id
            WHERE faces.id = ?
            """)
            defer { s.reset() }
            var out: [Row] = []
            for id in group.faceIDs {
                s.reset()
                try s.bind([.int(id)])
                guard try s.step() else { continue }
                var url: URL?
                if s.int64(8) != 0 {
                    let base = URL(fileURLWithPath: s.text(9))
                    let rel = s.text(10)
                    url = rel.isEmpty ? base : base.appendingPathComponent(rel)
                }
                let reference = FontReference(postScriptName: s.text(0), family: group.name, fingerprint: s.text(7))
                out.append(Row(style: PairingStyle(reference: reference, name: s.text(1), weight: s.double(2),
                                                   width: s.double(3), isItalic: s.int64(4) != 0),
                               isVariable: s.int64(5) != 0, faceIndex: Int(s.int64(6)), url: url))
            }
            return out
        }

        var styles = rows.map(\.style)
        for row in rows where row.isVariable {
            guard let url = row.url, let font = FontFile.font(at: url, faceIndex: row.faceIndex, size: 12) else { continue }
            for instance in VariationInfo.read(font).instances {
                var coordinates: [String: Double] = [:]
                for (code, value) in instance.coordinates { coordinates[VariationInfo.tagString(code)] = value }
                var reference = row.style.reference
                reference.variations = coordinates
                styles.append(PairingStyle(reference: reference, name: instance.name,
                                           weight: coordinates["wght"] ?? row.style.weight, width: row.style.width,
                                           isItalic: row.style.isItalic))
            }
        }
        return styles
    }
}

public enum LayoutFontError: Error, Equatable {
    case noSuchFace(Int64)
}
