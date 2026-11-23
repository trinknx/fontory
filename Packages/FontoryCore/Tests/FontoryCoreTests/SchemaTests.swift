import Foundation
import Testing
@testable import FontoryCore

@Suite struct SchemaTests {
    @Test func migrateCreatesTablesAndIsIdempotent() throws {
        let db = try Database(path: ":memory:")
        try Schema.migrate(db)
        try Schema.migrate(db)
        let v = try db.prepare("PRAGMA user_version")
        #expect(try v.step())
        #expect(v.int64(0) == Int64(Schema.currentVersion))
        v.reset()

        let names = try db.prepare("SELECT name FROM sqlite_master")
        var found = Set<String>()
        while try names.step() { found.insert(names.text(0)) }
        names.reset()
        for n in ["locations", "files", "faces", "faces_fts", "family_prefs"] {
            #expect(found.contains(n), "missing \(n)")
        }
    }

    @Test func ftsTracksFaces() throws {
        let db = try Database(path: ":memory:")
        try Schema.migrate(db)
        try db.execute("INSERT INTO locations(id,kind,volume_uuid,relative_path,display_name,last_known_path) VALUES(1,0,'v','p','n','/p')")
        try db.execute("INSERT INTO files(id,location_id,relative_path,size,mtime,format,fingerprint,added_at,import_batch) VALUES(1,1,'a.otf',1,0,'otf','fp',0,0)")
        try db.execute("""
        INSERT INTO faces(id,file_id,face_index,postscript_name,family,style,full_name,weight,width,slant,is_italic,is_variable,glyph_count,units_per_em,ascender,descender,cap_height,x_height,outline_type,is_color,is_bitmap,has_gsub,has_gpos)
        VALUES(7,1,0,'AvenirNext-Regular','Avenir Next','Regular','Avenir Next Regular',0,0,0,0,0,10,1000,800,-200,700,500,'cff',0,0,0,0)
        """)
        func match(_ q: String) throws -> [Int64] {
            let s = try db.prepare("SELECT rowid FROM faces_fts WHERE faces_fts MATCH ?")
            try s.bind([.text(q)])
            var ids: [Int64] = []
            while try s.step() { ids.append(s.int64(0)) }
            s.reset()
            return ids
        }
        #expect(try match("aven*") == [7])

        try db.execute("UPDATE faces SET family='Helvetica', full_name='Helvetica Regular', postscript_name='Helv' WHERE id=7")
        #expect(try match("aven*").isEmpty)
        #expect(try match("helv*") == [7])

        try db.execute("DELETE FROM faces WHERE id=7")
        #expect(try match("helv*").isEmpty)
    }

    @Test func v2MigrationReclassifiesUserFontFoldersAndAddsFlags() throws {
        let db = try Database(path: ":memory:")
        try db.execute(Schema.v1)
        try db.execute("PRAGMA user_version = 1")
        try db.execute("""
        INSERT INTO locations(id,kind,volume_uuid,relative_path,display_name,last_known_path) VALUES
          (1,2,'v','System/Library/Fonts','System Fonts','/System/Library/Fonts'),
          (2,2,'v','Library/Fonts','Computer Fonts','/Library/Fonts'),
          (3,2,'v','Users/me/Library/Fonts','User Fonts','/Users/me/Library/Fonts'),
          (4,0,'w','Type','Type','/Volumes/W/Type')
        """)
        try db.execute("INSERT INTO files(id,location_id,relative_path,size,mtime,format,fingerprint,added_at,import_batch) VALUES(1,2,'a.otf',1,0,'otf','fp',0,1)")
        try Schema.migrate(db)

        let v = try db.prepare("PRAGMA user_version")
        #expect(try v.step())
        #expect(v.int64(0) == Int64(Schema.currentVersion))
        v.reset()
        let s = try db.prepare("SELECT id, kind, auto_indexed FROM locations ORDER BY id")
        var kinds: [Int64: Int64] = [:]
        while try s.step() {
            kinds[s.int64(0)] = s.int64(1)
            #expect(s.int64(2) == 0)
        }
        s.reset()
        #expect(kinds == [1: 2, 2: 3, 3: 3, 4: 0])
        let fl = try db.prepare("SELECT external_active FROM files WHERE id = 1")
        #expect(try fl.step())
        #expect(fl.int64(0) == 0)
        fl.reset()
    }
}
