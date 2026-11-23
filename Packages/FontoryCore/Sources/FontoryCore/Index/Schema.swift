import Foundation

public enum Schema {
    public static let currentVersion: Int32 = 4

    private static let steps: [(version: Int32, sql: String)] = [(1, v1), (2, v2), (3, v3), (4, v4)]

    /// Runs each step whose version is greater than the database's `user_version`.
    public static func migrate(_ db: Database) throws {
        let s = try db.prepare("PRAGMA user_version")
        guard try s.step() else { return }
        let current = Int32(s.int64(0))
        s.reset()
        for step in steps where step.version > current {
            try db.transaction {
                try db.execute(step.sql)
                try db.execute("PRAGMA user_version = \(step.version)")
            }
        }
    }

    /// Wave 3A: per-face coverage (little-endian UInt32 `[start, end]` pairs, inclusive, sorted, non-overlapping),
    /// feature tags (`" liga smcp "`), default figure style (0 unknown, 1 lining, 2 oldstyle) and the version of that
    /// metadata (`FaceMetadata.version`; the backfill fills rows below it), plus the files the user removed from the
    /// library. Only constant-default columns and new tables: the cost does not depend on the row count.
    static let v4 = """
    CREATE TABLE face_coverage(face_id INTEGER PRIMARY KEY REFERENCES faces(id) ON DELETE CASCADE, ranges BLOB NOT NULL);
    ALTER TABLE faces ADD COLUMN features TEXT NOT NULL DEFAULT '';
    ALTER TABLE faces ADD COLUMN figure_style INTEGER NOT NULL DEFAULT 0;
    ALTER TABLE faces ADD COLUMN meta_version INTEGER NOT NULL DEFAULT 0;
    CREATE TABLE excluded_files(location_id INTEGER NOT NULL REFERENCES locations(id) ON DELETE CASCADE,
      relative_path TEXT NOT NULL, fingerprint TEXT NOT NULL, PRIMARY KEY(location_id, relative_path));
    """

    /// Activation views follow the Mac's real state. Locations: kind 3 (user-installed, read-only) for every
    /// former system location outside /System, plus `auto_indexed` for folders the inventory indexes on its own.
    /// Files: `external_active`, set while someone other than Fontory has the file registered.
    /// Organization: hierarchical tags (plain or smart), per-face tag links, the Quick Collection, and the
    /// style-class columns the classifier fills. Notes already live on `faces.note`.
    static let v3 = """
    CREATE TABLE tags(id INTEGER PRIMARY KEY, parent_id INTEGER REFERENCES tags(id) ON DELETE CASCADE,
      name TEXT NOT NULL, kind INTEGER NOT NULL DEFAULT 0, rule_json TEXT, created_at REAL NOT NULL);
    CREATE TABLE face_tags(face_id INTEGER NOT NULL REFERENCES faces(id) ON DELETE CASCADE,
      tag_id INTEGER NOT NULL REFERENCES tags(id) ON DELETE CASCADE, PRIMARY KEY(face_id, tag_id));
    CREATE INDEX face_tags_tag ON face_tags(tag_id);
    CREATE TABLE quick_collection(face_id INTEGER PRIMARY KEY REFERENCES faces(id) ON DELETE CASCADE, added_at REAL NOT NULL);
    ALTER TABLE faces ADD COLUMN style_class INTEGER NOT NULL DEFAULT 0;
    ALTER TABLE faces ADD COLUMN class_version INTEGER NOT NULL DEFAULT 0;
    """

    static let v2 = """
    ALTER TABLE locations ADD COLUMN auto_indexed INTEGER NOT NULL DEFAULT 0;
    UPDATE locations SET kind = 3
      WHERE kind = 2 AND last_known_path != '/System' AND substr(last_known_path, 1, 8) != '/System/';
    ALTER TABLE files ADD COLUMN external_active INTEGER NOT NULL DEFAULT 0;
    CREATE INDEX files_external ON files(external_active) WHERE external_active != 0;
    """

    static let v1 = """
    CREATE TABLE locations(id INTEGER PRIMARY KEY, kind INTEGER NOT NULL, -- 0 user folder, 1 user file-set, 2 system (3 user-installed: v2)
      volume_uuid TEXT NOT NULL, relative_path TEXT NOT NULL, display_name TEXT NOT NULL,
      last_known_path TEXT NOT NULL, online INTEGER NOT NULL DEFAULT 1, last_scan REAL,
      UNIQUE(volume_uuid, relative_path));
    CREATE TABLE files(id INTEGER PRIMARY KEY, location_id INTEGER NOT NULL REFERENCES locations(id) ON DELETE CASCADE,
      relative_path TEXT NOT NULL, size INTEGER NOT NULL, mtime REAL NOT NULL, format TEXT NOT NULL,
      fingerprint TEXT NOT NULL, content_hash TEXT, added_at REAL NOT NULL, import_batch INTEGER NOT NULL,
      UNIQUE(location_id, relative_path));
    CREATE INDEX files_fp ON files(fingerprint);
    CREATE TABLE faces(id INTEGER PRIMARY KEY, file_id INTEGER NOT NULL REFERENCES files(id) ON DELETE CASCADE,
      face_index INTEGER NOT NULL, postscript_name TEXT NOT NULL, family TEXT NOT NULL, style TEXT NOT NULL,
      full_name TEXT NOT NULL, custom_family TEXT, weight REAL NOT NULL, width REAL NOT NULL, slant REAL NOT NULL,
      is_italic INTEGER NOT NULL, is_variable INTEGER NOT NULL, axes_json TEXT, vendor TEXT, designer TEXT,
      version TEXT, glyph_count INTEGER NOT NULL, scripts_bitmask INTEGER NOT NULL DEFAULT 0,
      units_per_em INTEGER NOT NULL, ascender REAL NOT NULL, descender REAL NOT NULL, cap_height REAL NOT NULL,
      x_height REAL NOT NULL, fs_type INTEGER, outline_type TEXT NOT NULL, -- truetype|cff|cff2|bitmap|unknown
      is_color INTEGER NOT NULL, is_bitmap INTEGER NOT NULL, has_gsub INTEGER NOT NULL, has_gpos INTEGER NOT NULL,
      activation INTEGER NOT NULL DEFAULT 0, -- 0 off, 1 on, 2 temp
      last_activated REAL, note TEXT, UNIQUE(file_id, face_index));
    CREATE INDEX faces_family ON faces(family COLLATE NOCASE, weight, width, slant);
    CREATE INDEX faces_ps ON faces(postscript_name);
    CREATE INDEX faces_activation ON faces(activation);
    CREATE TABLE family_prefs(family_key TEXT PRIMARY KEY, representative_face_id INTEGER REFERENCES faces(id) ON DELETE SET NULL);
    CREATE VIRTUAL TABLE faces_fts USING fts5(family, style, full_name, postscript_name, vendor, designer, note,
      content='faces', content_rowid='id', tokenize='unicode61 remove_diacritics 2');
    CREATE TRIGGER faces_ai AFTER INSERT ON faces BEGIN
      INSERT INTO faces_fts(rowid, family, style, full_name, postscript_name, vendor, designer, note)
      VALUES (new.id, new.family, new.style, new.full_name, new.postscript_name, new.vendor, new.designer, new.note);
    END;
    CREATE TRIGGER faces_ad AFTER DELETE ON faces BEGIN
      INSERT INTO faces_fts(faces_fts, rowid, family, style, full_name, postscript_name, vendor, designer, note)
      VALUES ('delete', old.id, old.family, old.style, old.full_name, old.postscript_name, old.vendor, old.designer, old.note);
    END;
    CREATE TRIGGER faces_au AFTER UPDATE OF family, style, full_name, postscript_name, vendor, designer, note ON faces BEGIN
      INSERT INTO faces_fts(faces_fts, rowid, family, style, full_name, postscript_name, vendor, designer, note)
      VALUES ('delete', old.id, old.family, old.style, old.full_name, old.postscript_name, old.vendor, old.designer, old.note);
      INSERT INTO faces_fts(rowid, family, style, full_name, postscript_name, vendor, designer, note)
      VALUES (new.id, new.family, new.style, new.full_name, new.postscript_name, new.vendor, new.designer, new.note);
    END;
    """
}
