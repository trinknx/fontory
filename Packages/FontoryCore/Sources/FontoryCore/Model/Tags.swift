import Foundation

public enum TagKind: Int, Sendable, Codable { case tag = 0, smart = 1 }

public struct TagRecord: Sendable, Hashable, Identifiable {
    public var id: Int64
    public var parentID: Int64?
    public var name: String
    public var kind: TagKind
    public var ruleJSON: String?
    public var createdAt: Date

    public init(id: Int64, parentID: Int64?, name: String, kind: TagKind, ruleJSON: String?, createdAt: Date) {
        self.id = id; self.parentID = parentID; self.name = name
        self.kind = kind; self.ruleJSON = ruleJSON; self.createdAt = createdAt
    }
}

public enum TagError: Error, Equatable { case duplicateName, cycle, notFound, emptyName }

/// One sidebar tag pick. `rule` is set for smart tags (resolved by the app from `TagRecord.ruleJSON`).
public struct TagPick: Sendable, Hashable {
    public var tagID: Int64
    public var inverted: Bool
    public var rule: SmartRule?
    public init(tagID: Int64, inverted: Bool = false, rule: SmartRule? = nil) {
        self.tagID = tagID; self.inverted = inverted; self.rule = rule
    }
}

public struct OrganizationCounts: Sendable, Equatable {
    public var untagged = 0
    public var quickCollection = 0
    /// Plain tags only, including descendants' faces, distinct faces. Smart-tag counts are the app's job.
    public var perTag: [Int64: Int] = [:]
    public var perStyle: [StyleClass: Int] = [:]
    public init() {}
}
