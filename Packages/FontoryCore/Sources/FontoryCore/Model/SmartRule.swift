import Foundation

/// A smart tag's rule set: conditions combined with all/any, optionally inverted, stored as JSON on the tag
/// and compiled to one SQL condition over `faces JOIN files JOIN locations`.
public struct SmartRule: Sendable, Hashable, Codable {
    public enum Match: String, Sendable, Codable { case all, any }
    public var match: Match = .all
    public var inverted = false
    public var conditions: [Condition] = []

    public init() {}

    /// Stands in for a deleted tag or location in a condition's value; such a condition matches nothing.
    /// Tag and location ids can be reused, so deletions rewrite conditions to this (see `FontStore.deleteTag`).
    public static let deletedID: Int64 = -1

    public struct Condition: Sendable, Hashable, Codable {
        public var field: Field
        public var op: Op
        public var value: Value
        public init(field: Field, op: Op, value: Value = .none) {
            self.field = field; self.op = op; self.value = value
        }
    }

    public enum Field: String, Sendable, Codable, CaseIterable {
        case name, family, styleName, foundry, designer, styleClass, tag, activation,
             variable, italic, color, hasNote, weight, width, format, outlineType, script, location, dateAdded
    }

    public enum Op: String, Sendable, Codable { case contains, `is`, isNot, startsWith, has, hasNot, yes, no, between, withinDays }

    /// JSON shapes: a string, an integer, `[low, high]`, or null.
    public enum Value: Sendable, Hashable, Codable {
        case text(String), int(Int64), range(Double, Double), none

        public init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if c.decodeNil() { self = .none }
            else if let i = try? c.decode(Int64.self) { self = .int(i) }
            else if let s = try? c.decode(String.self) { self = .text(s) }
            else {
                let r = try c.decode([Double].self)
                guard r.count == 2 else { throw DecodingError.dataCorruptedError(in: c, debugDescription: "range needs two numbers") }
                self = .range(r[0], r[1])
            }
        }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.singleValueContainer()
            switch self {
            case .text(let s): try c.encode(s)
            case .int(let i): try c.encode(i)
            case .range(let a, let b): try c.encode([a, b])
            case .none: try c.encodeNil()
            }
        }
    }

    private enum CodingKeys: String, CodingKey { case match, inverted, conditions }

    /// "Script supported" values: the script name at each `scripts_bitmask` bit (the value is the index).
    public static var scriptNames: [String] { ScriptCoverage.scripts.map(\.name) }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        match = try c.decodeIfPresent(Match.self, forKey: .match) ?? .all
        inverted = try c.decodeIfPresent(Bool.self, forKey: .inverted) ?? false
        conditions = try c.decodeIfPresent([Condition].self, forKey: .conditions) ?? []
    }

    /// nil on malformed JSON or an unknown field/operator name (a rule from a newer version).
    public static func decode(_ json: String) -> SmartRule? {
        try? JSONDecoder().decode(SmartRule.self, from: Data(json.utf8))
    }

    public func encoded() -> String {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        return (try? enc.encode(self)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }

    /// SQL condition over faces/files/locations; bindings in order. Empty conditions give "1" (matches all),
    /// inverted or not. Every value is bound. A bad field/operator/value combination compiles to "0".
    /// `now` is only used by "date added within N days".
    public func sqlClause(now: Date = Date()) -> (sql: String, bindings: [SQLValue]) {
        guard !conditions.isEmpty else { return ("1", []) }
        var parts: [String] = []
        var bindings: [SQLValue] = []
        for cond in conditions {
            let (sql, b) = Self.compile(cond, now: now)
            parts.append(sql)
            bindings += b
        }
        let joined = "(" + parts.joined(separator: match == .all ? " AND " : " OR ") + ")"
        return (inverted ? "NOT \(joined)" : joined, bindings)
    }

    private static let never: (String, [SQLValue]) = ("0", [])

    private static func compile(_ c: Condition, now: Date) -> (String, [SQLValue]) {
        func text(_ column: String) -> (String, [SQLValue]) {
            guard case .text(let raw) = c.value else { return never }
            let v = TagName.fold(raw)
            // Folded on both sides; instr/substr instead of LIKE so '%' and '_' are literal.
            let col = "fontory_fold(COALESCE(\(column), ''))"
            switch c.op {
            case .contains: return ("instr(\(col), ?) > 0", [.text(v)])
            case .is: return ("\(col) = ?", [.text(v)])
            case .startsWith: return ("substr(\(col), 1, length(?)) = ?", [.text(v), .text(v)])
            default: return never
            }
        }
        func equality(_ column: String, _ value: SQLValue) -> (String, [SQLValue]) {
            switch c.op {
            case .is: return ("\(column) = ?", [value])
            case .isNot: return ("\(column) != ?", [value])
            default: return never
            }
        }
        func flag(_ sql: String) -> (String, [SQLValue]) {
            switch c.op {
            case .yes: return ("(\(sql))", [])
            case .no: return ("NOT (\(sql))", [])
            default: return never
            }
        }
        func range(_ column: String) -> (String, [SQLValue]) {
            guard c.op == .between, case .range(let a, let b) = c.value else { return never }
            return ("\(column) BETWEEN ? AND ?", [.double(min(a, b)), .double(max(a, b))])
        }
        func fixedText(_ column: String) -> (String, [SQLValue]) {
            guard case .text(let raw) = c.value else { return never }
            return equality("lower(\(column))", .text(raw.lowercased()))
        }

        switch c.field {
        case .name: return text("faces.full_name")
        case .family: return text(LibraryQuery.effectiveFamily)
        case .styleName: return text("faces.style")
        case .foundry: return text("faces.vendor")
        case .designer: return text("faces.designer")
        case .styleClass:
            guard case .int(let v) = c.value else { return never }
            return equality("faces.style_class", .int(v))
        case .tag:
            guard case .int(let id) = c.value, id != deletedID, c.op == .has || c.op == .hasNot else { return never }
            // A deleted tag, or a smart tag (which tags nothing), matches nothing either way.
            let exists = "EXISTS (SELECT 1 FROM tags WHERE id = ? AND kind = 0)"
            let member = "faces.id \(c.op == .has ? "IN" : "NOT IN") (SELECT face_id FROM face_tags WHERE tag_id IN (\(LibraryQuery.descendantsByID)))"
            return ("(\(exists) AND \(member))", [.int(id), .int(id)])
        case .activation: return flag(LibraryQuery.activatedClause)
        case .variable: return flag("faces.is_variable != 0")
        case .italic: return flag("faces.is_italic != 0")
        case .color: return flag("faces.is_color != 0")
        case .hasNote: return flag("COALESCE(faces.note, '') != ''")
        case .weight: return range("faces.weight")
        case .width: return range("faces.width")
        case .format: return fixedText("files.format")
        case .outlineType: return fixedText("faces.outline_type")
        case .script:
            guard case .int(let i) = c.value, c.op == .has || c.op == .hasNot,
                  i >= 0, i < Int64(ScriptCoverage.scripts.count), i < 63 else { return never }
            return ("((faces.scripts_bitmask >> ?) & 1) = ?", [.int(i), .int(c.op == .has ? 1 : 0)])
        case .location:
            // A removed location matches nothing, "is not" included (like a deleted tag).
            guard case .int(let id) = c.value, id != deletedID else { return never }
            return equality("files.location_id", .int(id))
        case .dateAdded:
            guard c.op == .withinDays, case .int(let days) = c.value, days >= 0, days < 365 * 1000 else { return never }
            return ("files.added_at >= ?", [.double(now.timeIntervalSince1970 - Double(days) * 86400)])
        }
    }
}
