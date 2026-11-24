import Foundation

extension FontStore {
    /// Snapshot of the user's data for a backup. `locationRank` holds current location ids, highest first;
    /// ids with no location are dropped. Dates are whole seconds (ISO 8601), so a manifest survives a write/read unchanged. Only faces with user data, or that are a family's representative, are listed.
    public func makeBackupManifest(created: Date, appVersion: String, locationRank: [Int64],
                                   skipDuplicatesOnImport: Bool) throws -> BackupManifest {
        try reader.withLock {
            // Locations
            var locations: [BackupManifest.Location] = []
            var indexByID: [Int64: Int] = [:]
            let ls = try reader.prepare("SELECT id, kind, volume_uuid, relative_path, display_name, last_known_path FROM locations ORDER BY id")
            while try ls.step() {
                let id = ls.int64(0)
                indexByID[id] = locations.count
                locations.append(.init(index: locations.count, id: id, kind: Int(ls.int64(1)), volumeUUID: ls.text(2),
                                       relativePath: ls.text(3), displayName: ls.text(4), lastKnownPath: ls.text(5),
                                       members: nil))
            }
            ls.reset()
            let ms = try reader.prepare("SELECT relative_path FROM files WHERE location_id = ? ORDER BY relative_path")
            for (id, i) in indexByID where locations[i].kind == LocationKind.fileSet.rawValue {
                ms.reset()
                try ms.bind([.int(id)])
                var members: [String] = []
                while try ms.step() { members.append(ms.text(0)) }
                locations[i].members = members
            }
            ms.reset()

            // Tags
            var tags: [BackupManifest.Tag] = []
            let ts = try reader.prepare("SELECT id, parent_id, name, kind, rule_json FROM tags ORDER BY id")
            while try ts.step() {
                tags.append(.init(id: ts.int64(0), parentID: ts.isNull(1) ? nil : ts.int64(1), name: ts.text(2),
                                  kind: Int(ts.int64(3)), rule: ts.isNull(4) ? nil : ts.text(4)))
            }
            ts.reset()

            // Representatives (family key -> face id), resolved to indexes below.
            var repFace: [String: Int64] = [:]
            let rs = try reader.prepare("SELECT family_key, representative_face_id FROM family_prefs WHERE representative_face_id IS NOT NULL")
            while try rs.step() { repFace[rs.text(0)] = rs.int64(1) }
            rs.reset()
            let repIDs = Set(repFace.values)

            // Faces with user data
            var faces: [BackupManifest.Face] = []
            var indexByFace: [Int64: Int] = [:]
            let fs = try reader.prepare("""
            SELECT f.id, fi.fingerprint, fi.location_id, fi.relative_path, f.face_index, f.postscript_name,
                   f.note, q.added_at, f.custom_family, f.activation,
                   EXISTS(SELECT 1 FROM face_tags t WHERE t.face_id = f.id)
            FROM faces f JOIN files fi ON fi.id = f.file_id
            LEFT JOIN quick_collection q ON q.face_id = f.id
            ORDER BY f.id
            """)
            var pending: [(Int64, BackupManifest.Face)] = []
            while try fs.step() {
                let id = fs.int64(0)
                let note = fs.isNull(6) || fs.text(6).isEmpty ? nil : fs.text(6)
                let qc: Date? = fs.isNull(7) ? nil : Date(timeIntervalSince1970: fs.double(7).rounded(.down))
                let custom = fs.isNull(8) ? nil : fs.text(8)
                let activation = Int(fs.int64(9))
                let hasTags = fs.int64(10) != 0
                guard hasTags || note != nil || qc != nil || custom != nil || activation != 0 || repIDs.contains(id),
                      let loc = indexByID[fs.int64(2)] else { continue }
                pending.append((id, .init(fingerprint: fs.text(1), locationIndex: loc, relativePath: fs.text(3),
                                          faceIndex: Int(fs.int64(4)), postScriptName: fs.text(5), tagIDs: [],
                                          note: note, quickCollectionAdded: qc, customFamily: custom,
                                          activation: activation)))
            }
            fs.reset()
            for (id, face) in pending {
                indexByFace[id] = faces.count
                faces.append(face)
            }
            let fts = try reader.prepare("SELECT face_id, tag_id FROM face_tags ORDER BY face_id, tag_id")
            while try fts.step() {
                if let i = indexByFace[fts.int64(0)] { faces[i].tagIDs.append(fts.int64(1)) }
            }
            fts.reset()

            var representatives: [String: Int] = [:]
            for (key, id) in repFace { if let i = indexByFace[id] { representatives[key] = i } }

            let rank = locationRank.compactMap { indexByID[$0] }
            return BackupManifest(created: Date(timeIntervalSince1970: created.timeIntervalSince1970.rounded(.down)), appVersion: appVersion, locations: locations, tags: tags,
                                  faces: faces, representatives: representatives,
                                  settings: .init(locationRank: rank, skipDuplicatesOnImport: skipDuplicatesOnImport))
        }
    }
}

/// What `FontStore.restore` did. The store never touches activation or settings; the app applies
/// `activations`, `locationRank` and `skipDuplicatesOnImport` itself.
public struct RestoreResult: Sendable, Equatable {
    public var tagCount: Int
    /// Library faces that received backup data.
    public var restoredFaceCount: Int
    /// PostScript names of backup faces that matched nothing, in manifest order.
    public var notFound: [String]
    /// Matched face id -> saved activation state, for saved states other than off.
    public var activations: [Int64: Int]
    /// Current location ids, highest rank first; backup locations with no current location are dropped.
    public var locationRank: [Int64]
    public var skipDuplicatesOnImport: Bool
    /// Display names of backup folder and file-set locations missing from the location map.
    public var unreachableLocations: [String]

    public init(tagCount: Int, restoredFaceCount: Int, notFound: [String], activations: [Int64: Int],
                locationRank: [Int64], skipDuplicatesOnImport: Bool, unreachableLocations: [String]) {
        self.tagCount = tagCount; self.restoredFaceCount = restoredFaceCount; self.notFound = notFound
        self.activations = activations; self.locationRank = locationRank
        self.skipDuplicatesOnImport = skipDuplicatesOnImport; self.unreachableLocations = unreachableLocations
    }
}

extension FontStore {
    /// Backup location index -> current location id, matched by volume UUID and relative path.
    public func locationMap(for m: BackupManifest) throws -> [Int: Int64] {
        struct Key: Hashable { let volume: String, path: String }
        let current: [Key: Int64] = try reader.withLock {
            let s = try reader.prepare("SELECT id, volume_uuid, relative_path FROM locations")
            defer { s.reset() }
            var out: [Key: Int64] = [:]
            while try s.step() { out[Key(volume: s.text(1), path: s.text(2))] = s.int64(0) }
            return out
        }
        var map: [Int: Int64] = [:]
        for loc in m.locations {
            if let id = current[Key(volume: loc.volumeUUID, path: loc.relativePath)] { map[loc.index] = id }
        }
        return map
    }

    /// Replaces tags, notes, the Quick Collection, custom family names and representatives with the backup's,
    /// in one transaction (all or nothing). The manifest is validated before anything is written.
    /// Faces are matched (1) by fingerprint and PostScript name, (2) by location, relative path and face index,
    /// (3) by a PostScript name unique in both the backup and the library. `faces.activation` is never written.
    public func restore(_ m: BackupManifest, locationMap: [Int: Int64]) throws -> RestoreResult {
        let tagOrder = try Self.validateForRestore(m)

        return try database.withLock {
            try database.transaction {
                // Lookups, read once before writing.
                struct FPKey: Hashable { let fingerprint: String, name: String }
                struct PathKey: Hashable { let location: Int64, path: String, index: Int }
                var byFingerprint: [FPKey: [Int64]] = [:]
                var byPath: [PathKey: Int64] = [:]
                var pathOf: [Int64: PathKey] = [:]
                var libraryNames: [String: [Int64]] = [:]
                var family: [Int64: String] = [:]
                let q = try database.prepare("""
                SELECT f.id, fi.fingerprint, f.postscript_name, fi.location_id, fi.relative_path, f.face_index, f.family
                FROM faces f JOIN files fi ON fi.id = f.file_id ORDER BY f.id
                """)
                while try q.step() {
                    let id = q.int64(0)
                    let name = q.text(2)
                    byFingerprint[FPKey(fingerprint: q.text(1), name: name), default: []].append(id)
                    let pk = PathKey(location: q.int64(3), path: q.text(4), index: Int(q.int64(5)))
                    byPath[pk] = id
                    pathOf[id] = pk
                    libraryNames[name, default: []].append(id)
                    family[id] = q.text(6)
                }
                q.reset()
                var backupNameCount: [String: Int] = [:]
                for face in m.faces { backupNameCount[face.postScriptName, default: 0] += 1 }

                // Match every backup face.
                var matched: [Int: Int64] = [:]  // backup face index -> face id
                var notFound: [String] = []
                for (i, face) in m.faces.enumerated() {
                    let pk = locationMap[face.locationIndex].map {
                        PathKey(location: $0, path: face.relativePath, index: face.faceIndex)
                    }
                    var id: Int64?
                    if let c = byFingerprint[FPKey(fingerprint: face.fingerprint, name: face.postScriptName)] {
                        id = c.first { pk != nil && pathOf[$0] == pk } ?? c.first
                    } else if let pk, let p = byPath[pk] {
                        id = p
                    } else if backupNameCount[face.postScriptName] == 1,
                              let c = libraryNames[face.postScriptName], c.count == 1 {
                        id = c[0]
                    }
                    if let id { matched[i] = id } else { notFound.append(face.postScriptName) }
                }

                // Clear everything restore replaces.
                for sql in ["DELETE FROM face_tags", "DELETE FROM tags", "UPDATE faces SET note = NULL WHERE note IS NOT NULL",
                            "DELETE FROM quick_collection",
                            "UPDATE faces SET custom_family = NULL WHERE custom_family IS NOT NULL",
                            "DELETE FROM family_prefs"] {
                    let s = try database.prepare(sql)
                    _ = try s.step()
                    s.reset()
                }

                // Tags, parents first; then their rules with remapped ids.
                var tagMap: [Int64: Int64] = [:]
                let ins = try database.prepare("INSERT INTO tags(parent_id, name, kind, rule_json, created_at) VALUES(?,?,?,?,?)")
                let now = Date().timeIntervalSince1970
                for tag in tagOrder {
                    ins.reset()
                    try ins.bind([tag.parentID.map { .int(tagMap[$0]!) } ?? .null, .text(tag.name), .int(Int64(tag.kind)),
                                  .null, .double(now)])
                    _ = try ins.step()
                    ins.reset()
                    tagMap[tag.id] = database.lastInsertRowID
                }
                // Rule location values are the backed-up library's ids: backup id -> index -> current id.
                var locationByOriginalID: [Int64: Int64] = [:]
                for loc in m.locations {
                    if let old = loc.id, let current = locationMap[loc.index] { locationByOriginalID[old] = current }
                }
                let ruleUp = try database.prepare("UPDATE tags SET rule_json = ? WHERE id = ?")
                for tag in tagOrder {
                    guard let json = tag.rule else { continue }
                    let remapped = Self.remapRule(json, tags: tagMap, locations: locationByOriginalID)
                    ruleUp.reset()
                    try ruleUp.bind([.text(remapped), .int(tagMap[tag.id]!)])
                    _ = try ruleUp.step()
                    ruleUp.reset()
                }

                // Face data.
                var custom: [Int64: String] = [:]
                var activations: [Int64: Int] = [:]
                let ft = try database.prepare("INSERT OR IGNORE INTO face_tags(face_id, tag_id) VALUES(?,?)")
                let note = try database.prepare("UPDATE faces SET note = ? WHERE id = ?")
                let qc = try database.prepare("INSERT OR REPLACE INTO quick_collection(face_id, added_at) VALUES(?,?)")
                let fam = try database.prepare("UPDATE faces SET custom_family = ? WHERE id = ?")
                for (i, face) in m.faces.enumerated() {
                    guard let id = matched[i] else { continue }
                    for t in face.tagIDs {
                        ft.reset()
                        try ft.bind([.int(id), .int(tagMap[t]!)])
                        _ = try ft.step()
                        ft.reset()
                    }
                    if let n = face.note, !n.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        note.reset()
                        try note.bind([.text(n), .int(id)])
                        _ = try note.step()
                        note.reset()
                    }
                    if let added = face.quickCollectionAdded {
                        qc.reset()
                        try qc.bind([.int(id), .double(added.timeIntervalSince1970)])
                        _ = try qc.step()
                        qc.reset()
                    }
                    if let name = face.customFamily?.trimmingCharacters(in: .whitespacesAndNewlines),
                       !name.isEmpty, name != family[id] {
                        fam.reset()
                        try fam.bind([.text(name), .int(id)])
                        _ = try fam.step()
                        fam.reset()
                        custom[id] = name
                    }
                    if face.activation != 0 { activations[id] = face.activation }
                }

                // Representatives, re-keyed to the matched face's effective family.
                let rep = try database.prepare("INSERT OR IGNORE INTO family_prefs(family_key, representative_face_id) VALUES(?,?)")
                for (_, i) in m.representatives.sorted(by: { $0.key < $1.key }) {
                    guard let id = matched[i], let name = custom[id] ?? family[id] else { continue }
                    rep.reset()
                    try rep.bind([.text(name.lowercased()), .int(id)])
                    _ = try rep.step()
                    rep.reset()
                }

                let userKinds: Set<Int> = [LocationKind.folder.rawValue, LocationKind.fileSet.rawValue]
                return RestoreResult(
                    tagCount: tagOrder.count,
                    restoredFaceCount: Set(matched.values).count,
                    notFound: notFound,
                    activations: activations,
                    locationRank: m.settings.locationRank.compactMap { locationMap[$0] },
                    skipDuplicatesOnImport: m.settings.skipDuplicatesOnImport,
                    unreachableLocations: m.locations.filter { userKinds.contains($0.kind) && locationMap[$0.index] == nil }
                        .map(\.displayName))
            }
        }
    }

    /// Checks the manifest's internal references and returns its tags with every parent before its children.
    /// Throws `BackupError.unreadable` on a duplicate tag id, a missing parent, a parent cycle, an unknown tag id
    /// on a face, or a location or representative index out of range.
    static func validateForRestore(_ m: BackupManifest) throws -> [BackupManifest.Tag] {
        var byID: [Int64: BackupManifest.Tag] = [:]
        for tag in m.tags {
            guard byID.updateValue(tag, forKey: tag.id) == nil else { throw BackupError.unreadable("duplicate tag id \(tag.id)") }
        }
        for tag in m.tags {
            if let p = tag.parentID, byID[p] == nil { throw BackupError.unreadable("tag \(tag.id) has a missing parent \(p)") }
        }
        var order: [BackupManifest.Tag] = []
        var placed = Set<Int64>()
        var remaining = m.tags
        while !remaining.isEmpty {
            let ready = remaining.filter { $0.parentID.map(placed.contains) ?? true }
            guard !ready.isEmpty else { throw BackupError.unreadable("tag parents form a cycle") }
            order += ready
            placed.formUnion(ready.map(\.id))
            remaining.removeAll { placed.contains($0.id) }
        }
        let locationIndexes = Set(m.locations.map(\.index))
        for face in m.faces {
            guard locationIndexes.contains(face.locationIndex) else {
                throw BackupError.unreadable("face \(face.postScriptName) has an unknown location \(face.locationIndex)")
            }
            for t in face.tagIDs where byID[t] == nil {
                throw BackupError.unreadable("face \(face.postScriptName) has an unknown tag \(t)")
            }
        }
        for (key, i) in m.representatives where !m.faces.indices.contains(i) {
            throw BackupError.unreadable("representative of \(key) is out of range")
        }
        return order
    }

    /// Points `.tag` and `.location` integer values at the new ids; unmapped values become `SmartRule.deletedID`.
    /// A rule that does not decode (from a newer version) is kept as it is.
    static func remapRule(_ json: String, tags: [Int64: Int64], locations: [Int64: Int64]) -> String {
        guard var rule = SmartRule.decode(json) else { return json }
        for i in rule.conditions.indices {
            guard case .int(let v) = rule.conditions[i].value else { continue }
            switch rule.conditions[i].field {
            case .tag: rule.conditions[i].value = .int(tags[v] ?? SmartRule.deletedID)
            case .location: rule.conditions[i].value = .int(locations[v] ?? SmartRule.deletedID)
            default: break
            }
        }
        return rule.encoded()
    }
}
