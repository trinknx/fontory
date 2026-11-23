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
