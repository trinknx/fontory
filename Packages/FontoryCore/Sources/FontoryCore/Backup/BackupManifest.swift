import Foundation

/// The contents of a `.fontorybackup`: the user's own data (tags, notes, Quick Collection, family names,
/// representatives) plus enough identity (locations, fingerprints) to match faces again on restore.
/// Pure data: no app types. Ids in `tags` are the backup's own; restore remaps them.
public struct BackupManifest: Codable, Sendable, Equatable {
    public static let formatName = "fontory-backup"
    public static let currentVersion = 1

    public var format: String = BackupManifest.formatName
    public var version: Int = BackupManifest.currentVersion
    public var created: Date
    public var appVersion: String
    public var locations: [Location]
    public var tags: [Tag]
    public var faces: [Face]
    /// Family key (lowercased effective name) -> index into `faces`.
    public var representatives: [String: Int]
    public var settings: Settings

    public struct Location: Codable, Sendable, Equatable {
        public var index: Int
        /// The backed-up library's location id, so location ids inside smart rules can be remapped.
        /// Optional: manifests written before it was added still decode.
        public var id: Int64?
        public var kind: Int
        public var volumeUUID: String
        public var relativePath: String
        public var displayName: String
        public var lastKnownPath: String
        /// Member relative paths; file sets only.
        public var members: [String]?
    }

    public struct Tag: Codable, Sendable, Equatable {
        public var id: Int64
        public var parentID: Int64?
        public var name: String
        public var kind: Int
        public var rule: String?
    }

    public struct Face: Codable, Sendable, Equatable {
        public var fingerprint: String
        public var locationIndex: Int
        public var relativePath: String
        public var faceIndex: Int
        public var postScriptName: String
        public var tagIDs: [Int64]
        public var note: String?
        public var quickCollectionAdded: Date?
        public var customFamily: String?
        public var activation: Int
    }

    public struct Settings: Codable, Sendable, Equatable {
        /// Location indexes, highest rank first.
        public var locationRank: [Int]
        public var skipDuplicatesOnImport: Bool
    }
}

public enum BackupError: Error, Equatable {
    case notABackup
    case unsupportedVersion(Int)
    case unreadable(String)
}
