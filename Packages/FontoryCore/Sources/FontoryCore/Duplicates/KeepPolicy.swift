import Foundation

/// Which copy of an exact duplicate group "Select Copies to Remove" keeps. A protected copy (in a system or
/// user-installed location, or active outside Fontory) can never be removed, so it is preferred as the keeper.
/// Then, in order:
/// 1. the active copy (a face on or temporary in Fontory, or the file active outside Fontory);
/// 2. format OTF > TTF > TTC/OTC > WOFF2 > WOFF > others;
/// 3. the location the user ranks higher (`locationRank`, first is highest; unranked locations last);
/// 4. the newer version (numeric parts of the version string; an unparsable or missing version compares lowest);
/// 5. the earliest added (then the lowest file id).
/// Protected files are never selected, whichever copy is kept.
public struct KeepPolicy: Sendable, Hashable, Codable {
    public var locationRank: [Int64]  // higher first

    public init(locationRank: [Int64] = []) { self.locationRank = locationRank }

    /// Files to remove from an exact group: every file but the kept one, minus protected files.
    /// Same-font groups are never auto-selected (empty). `rows` holds at least one face per file of the group.
    public func filesToRemove(in group: DuplicateGroup, rows: [Int64: FaceRow], files: [Int64: FileRecord]) -> Set<Int64> {
        guard group.kind == .exact, group.fileIDs.count > 1 else { return [] }
        var facesByFile: [Int64: [FaceRow]] = [:]
        for row in rows.values { facesByFile[row.fileID, default: []].append(row) }

        let candidates = group.fileIDs.map { id in Candidate(fileID: id, faces: facesByFile[id] ?? [], file: files[id], policy: self) }
        guard let kept = candidates.min(by: { $0.isBetter(than: $1) }) else { return [] }
        return Set(candidates.filter { $0.fileID != kept.fileID && !$0.isProtected }.map(\.fileID))
    }

    /// 0 is best: otf, ttf, ttc/otc, woff2, woff, then everything else.
    static func formatRank(_ format: String) -> Int {
        switch format.lowercased() {
        case "otf": 0
        case "ttf": 1
        case "ttc", "otc": 2
        case "woff2": 3
        case "woff": 4
        default: 5
        }
    }

    /// The numeric parts of the first number in a version string: "Version 2.013;hotconv 1.0" → [2, 13]. Nil when none.
    static func versionParts(_ version: String?) -> [Int]? {
        guard let version, let start = version.firstIndex(where: \.isASCIIDigit) else { return nil }
        let tail = version[start...]
        let token = tail.prefix { $0.isASCIIDigit || $0 == "." }
        let parts = token.split(separator: ".").compactMap { Int($0.prefix(18)) }
        return parts.isEmpty ? nil : parts
    }

    /// Lexicographic, missing parts as 0; nil is lowest. True when `a` is newer than `b`.
    static func isNewer(_ a: [Int]?, than b: [Int]?) -> Bool {
        guard let a else { return false }
        guard let b else { return true }
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0, y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    private struct Candidate {
        var fileID: Int64
        var active: Bool
        var isProtected: Bool
        var format: Int
        var location: Int
        var version: [Int]?
        var addedAt: Date

        init(fileID: Int64, faces: [FaceRow], file: FileRecord?, policy: KeepPolicy) {
            self.fileID = fileID
            active = faces.contains { $0.activation != .off || $0.externalActive }
            isProtected = faces.contains { $0.locationKind.isReadOnly || $0.externalActive }
            format = KeepPolicy.formatRank(file?.format ?? faces.first?.format ?? "")
            let locationID = file?.locationID ?? faces.first?.locationID
            location = locationID.flatMap { policy.locationRank.firstIndex(of: $0) } ?? policy.locationRank.count
            // The newest version among the file's faces (row order is not defined).
            version = faces.map { KeepPolicy.versionParts($0.version) }.reduce(nil) { KeepPolicy.isNewer($1, than: $0) ? $1 : $0 }
            addedAt = file?.addedAt ?? .distantFuture
        }

        func isBetter(than other: Candidate) -> Bool {
            if isProtected != other.isProtected { return isProtected }
            if active != other.active { return active }
            if format != other.format { return format < other.format }
            if location != other.location { return location < other.location }
            if KeepPolicy.isNewer(version, than: other.version) { return true }
            if KeepPolicy.isNewer(other.version, than: version) { return false }
            if addedAt != other.addedAt { return addedAt < other.addedAt }
            return fileID < other.fileID
        }
    }
}

private extension Character {
    var isASCIIDigit: Bool { ("0"..."9").contains(self) }
}
