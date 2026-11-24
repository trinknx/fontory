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
                locations.append(.init(index: locations.count, kind: Int(ls.int64(1)), volumeUUID: ls.text(2),
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
