import Foundation
import Testing
@testable import FontoryCore

@Suite struct BackupFilesTests {
    private var cal: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(secondsFromGMT: 7 * 3600)!
        return c
    }

    private func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 12, _ mi: Int = 0, _ s: Int = 0) -> Date {
        cal.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: mi, second: s))!
    }

    private func tempDir() throws -> URL {
        let u = FileManager.default.temporaryDirectory.appendingPathComponent("BackupFilesTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    private func touch(_ url: URL) throws { try Data("x".utf8).write(to: url) }

    @Test func namesUseLocalDate() throws {
        let dir = try tempDir()
        let files = BackupFiles(directory: dir, calendar: cal)
        // 23:30 local on 2026-03-05 is still 2026-03-05 even though UTC is 16:30 same day; use 01:30 local (previous day in UTC).
        let d = date(2026, 3, 5, 1, 30, 7)
        #expect(files.dailyURL(for: d).lastPathComponent == "Fontory 2026-03-05.fontorybackup")
        #expect(files.safetyURL(for: d).lastPathComponent == "Fontory before restore 2026-03-05 013007.fontorybackup")
        #expect(!files.hasDaily(for: d))
        try touch(files.dailyURL(for: d))
        #expect(files.hasDaily(for: d))
    }

    @Test func listSortsNewestFirstAndIgnoresOtherFiles() throws {
        let dir = try tempDir()
        let files = BackupFiles(directory: dir, calendar: cal)
        try touch(files.dailyURL(for: date(2026, 3, 1)))
        try touch(files.dailyURL(for: date(2026, 3, 3)))
        try touch(files.safetyURL(for: date(2026, 3, 3, 15, 0, 0)))
        try touch(dir.appendingPathComponent("notes.txt"))
        try touch(dir.appendingPathComponent("Fontory 2026-13-45.fontorybackup"))
        try touch(dir.appendingPathComponent("Other 2026-03-02.fontorybackup"))
        let list = files.list()
        #expect(list.count == 3)
        #expect(list.map(\.isSafety) == [true, false, false])
        #expect(list[0].date == date(2026, 3, 3, 15, 0, 0))
        #expect(list[1].date == date(2026, 3, 3, 0, 0, 0))
        #expect(list[2].date == date(2026, 3, 1, 0, 0, 0))
        #expect(list[0].size == 1)
    }

    @Test func pruneKeepsTenDays() throws {
        let dir = try tempDir()
        let files = BackupFiles(directory: dir, calendar: cal)
        let now = date(2026, 3, 20, 9)
        for back in 0...12 {
            try touch(files.dailyURL(for: cal.date(byAdding: .day, value: -back, to: now)!))
        }
        try touch(dir.appendingPathComponent("notes.txt"))
        let removed = try files.prune(now: now)
        #expect(removed.count == 2)
        let left = files.list()
        #expect(left.count == 11)
        #expect(left.last?.date == date(2026, 3, 10, 0, 0, 0))
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("notes.txt").path))
    }

    @Test func pruneAppliesToSafetyBackups() throws {
        let dir = try tempDir()
        let files = BackupFiles(directory: dir, calendar: cal)
        let now = date(2026, 3, 20, 9)
        let old = files.safetyURL(for: date(2026, 3, 9, 23, 59, 59))
        let kept = files.safetyURL(for: date(2026, 3, 10, 0, 0, 0))
        try touch(old); try touch(kept)
        let removed = try files.prune(now: now)
        #expect(removed.map(\.lastPathComponent) == [old.lastPathComponent])
        #expect(!FileManager.default.fileExists(atPath: old.path))
        #expect(FileManager.default.fileExists(atPath: kept.path))
    }
}
