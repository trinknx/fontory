import Foundation

/// Naming, listing and retention for `.fontorybackup` files in one folder.
public struct BackupFiles: Sendable {
    public struct Entry: Sendable, Equatable {
        public let url: URL
        public let date: Date
        public let isSafety: Bool
        public let size: Int64
    }

    public static let fileExtension = "fontorybackup"
    private static let dailyPrefix = "Fontory "
    private static let safetyPrefix = "Fontory before restore "

    public let directory: URL
    public let calendar: Calendar

    public init(directory: URL, calendar: Calendar = .current) {
        self.directory = directory
        self.calendar = calendar
    }

    private func formatter(_ format: String) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = calendar
        f.timeZone = calendar.timeZone
        f.dateFormat = format
        return f
    }

    public func dailyURL(for date: Date) -> URL {
        directory.appendingPathComponent("Fontory \(formatter("yyyy-MM-dd").string(from: date)).\(Self.fileExtension)")
    }

    public func safetyURL(for date: Date) -> URL {
        directory.appendingPathComponent("Fontory before restore \(formatter("yyyy-MM-dd HHmmss").string(from: date)).\(Self.fileExtension)")
    }

    public func hasDaily(for date: Date) -> Bool {
        FileManager.default.fileExists(atPath: dailyURL(for: date).path)
    }

    private func parse(_ name: String) -> (date: Date, isSafety: Bool)? {
        let suffix = "." + Self.fileExtension
        guard name.hasSuffix(suffix) else { return nil }
        let stem = String(name.dropLast(suffix.count))
        let isSafety = stem.hasPrefix(Self.safetyPrefix)
        let body: String
        let format: String
        if isSafety {
            body = String(stem.dropFirst(Self.safetyPrefix.count)); format = "yyyy-MM-dd HHmmss"
        } else if stem.hasPrefix(Self.dailyPrefix) {
            body = String(stem.dropFirst(Self.dailyPrefix.count)); format = "yyyy-MM-dd"
        } else { return nil }
        let f = formatter(format)
        f.isLenient = false
        guard let d = f.date(from: body), f.string(from: d) == body else { return nil }
        return (d, isSafety)
    }

    /// Parsed backups, newest first. Files whose names don't parse are ignored.
    public func list() -> [Entry] {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.fileSizeKey], options: [.skipsHiddenFiles])) ?? []
        var out: [Entry] = []
        for url in urls {
            guard let p = parse(url.lastPathComponent) else { continue }
            let size = Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            out.append(Entry(url: url, date: p.date, isSafety: p.isSafety, size: size))
        }
        return out.sorted { $0.date != $1.date ? $0.date > $1.date : $0.url.lastPathComponent < $1.url.lastPathComponent }
    }

    /// Deletes backups dated before the start of the day `keepDays` days before `now`'s day.
    @discardableResult
    public func prune(now: Date, keepDays: Int = 10) throws -> [URL] {
        let today = calendar.startOfDay(for: now)
        guard let cutoff = calendar.date(byAdding: .day, value: -keepDays, to: today) else { return [] }
        var removed: [URL] = []
        for e in list() where e.date < cutoff {
            try FileManager.default.removeItem(at: e.url)
            removed.append(e.url)
        }
        return removed
    }
}
