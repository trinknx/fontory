import Foundation
import Testing
@testable import FontoryCore

@Suite struct SQLiteTests {
    @Test func roundTrip() throws {
        let db = try Database(path: ":memory:")
        try db.execute("CREATE TABLE t(i INTEGER, d REAL, s TEXT, b BLOB, n TEXT)")
        let insert = try db.prepare("INSERT INTO t VALUES(?,?,?,?,?)")
        let blob = Data([0, 1, 2, 255])
        try insert.bind([.int(42), .double(3.5), .text("héllo"), .blob(blob), .null])
        #expect(try insert.step() == false)
        insert.reset()

        let select = try db.prepare("SELECT i, d, s, b, n FROM t")
        #expect(try select.step() == true)
        #expect(select.int64(0) == 42)
        #expect(select.double(1) == 3.5)
        #expect(select.text(2) == "héllo")
        #expect(select.blob(3) == blob)
        #expect(select.isNull(4))
        #expect(!select.isNull(0))
        #expect(try select.step() == false)
        select.reset()
        #expect(db.lastInsertRowID == 1)
    }

    @Test func transactionRollsBackOnThrow() throws {
        let db = try Database(path: ":memory:")
        try db.execute("CREATE TABLE t(i INTEGER)")
        struct Boom: Error {}
        #expect(throws: Boom.self) {
            try db.transaction {
                try db.execute("INSERT INTO t VALUES(1)")
                throw Boom()
            }
        }
        let count = try db.prepare("SELECT COUNT(*) FROM t")
        #expect(try count.step())
        #expect(count.int64(0) == 0)
        count.reset()
    }
}
