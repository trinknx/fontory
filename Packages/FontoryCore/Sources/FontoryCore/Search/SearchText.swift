import Foundation

/// Parsed library search box text.
///
/// Syntax: `"Helvetica Neue"` exact, `helv*` prefix, `*neue` suffix, bare word contains,
/// `#tag` tag (ignored in wave 1). Terms are ANDed.
public struct SearchText: Sendable, Hashable {
    public enum Field: String, Sendable, CaseIterable { case name, family, foundry, designer, notes }

    public struct Term: Sendable, Hashable {
        public enum Mode: Sendable, Hashable { case contains, exact, prefix, suffix, tag }
        public var text: String
        public var mode: Mode
        public init(text: String, mode: Mode) {
            self.text = text
            self.mode = mode
        }
    }

    public let terms: [Term]
    public let scope: Set<Field>

    public init(_ raw: String, scope: Set<Field> = Set(Field.allCases)) {
        self.scope = scope
        self.terms = Self.parse(raw)
    }

    private static func parse(_ raw: String) -> [Term] {
        var terms: [Term] = []
        var chars = Substring(raw)
        while let c = chars.first {
            if c.isWhitespace { chars.removeFirst(); continue }
            if c == "\"" {
                chars.removeFirst()
                let end = chars.firstIndex(of: "\"") ?? chars.endIndex
                let text = chars[..<end].trimmingCharacters(in: .whitespaces)
                chars = end < chars.endIndex ? chars[chars.index(after: end)...] : chars[end...]
                if !text.isEmpty { terms.append(Term(text: text, mode: .exact)) }
                continue
            }
            let end = chars.firstIndex(where: \.isWhitespace) ?? chars.endIndex
            var word = String(chars[..<end])
            chars = chars[end...]
            if word.hasPrefix("#") {
                word.removeFirst()
                if !word.isEmpty { terms.append(Term(text: word, mode: .tag)) }
                continue
            }
            let lead = word.hasPrefix("*"), trail = word.hasSuffix("*")
            word = word.trimmingCharacters(in: CharacterSet(charactersIn: "*"))
            if word.isEmpty { continue }
            let mode: Term.Mode = (lead && !trail) ? .suffix : (trail && !lead) ? .prefix : .contains
            terms.append(Term(text: word, mode: mode))
        }
        return terms
    }

    private static func columns(for field: Field) -> [String] {
        switch field {
        case .name: ["full_name", "postscript_name", "style"]
        case .family: ["family"]
        case .foundry: ["vendor"]
        case .designer: ["designer"]
        case .notes: ["note"]
        }
    }

    private var ftsColumns: [String] {
        Field.allCases.filter(scope.contains).flatMap(Self.columns(for:))
    }

    /// FTS5 MATCH expression for the contains and prefix terms, nil when there are none
    /// (or the scope is empty).
    public var ftsMatch: String? {
        let cols = ftsColumns
        guard !cols.isEmpty else { return nil }
        let filter = "{" + cols.joined(separator: " ") + "}"
        let parts = terms.filter { $0.mode == .contains || $0.mode == .prefix }.map {
            "\(filter) : \"\($0.text.replacingOccurrences(of: "\"", with: "\"\""))\"*"
        }
        return parts.isEmpty ? nil : parts.joined(separator: " AND ")
    }

    /// WHERE clauses (and bindings) for the exact and suffix terms, applied on top of the FTS match.
    func whereClauses(effectiveFamily: String) -> (clauses: [String], bindings: [SQLValue]) {
        var clauses: [String] = []
        var bindings: [SQLValue] = []
        for t in terms {
            let lowered = t.text.lowercased()
            switch t.mode {
            case .exact:
                var ors: [String] = []
                if scope.contains(.family) { ors.append("lower(\(effectiveFamily)) = ?"); bindings.append(.text(lowered)) }
                if scope.contains(.name) { ors.append("lower(faces.full_name) = ?"); bindings.append(.text(lowered)) }
                clauses.append(ors.isEmpty ? "0" : "(" + ors.joined(separator: " OR ") + ")")
            case .suffix:
                guard scope.contains(.name) else { clauses.append("0"); continue }
                let escaped = lowered
                    .replacingOccurrences(of: "\\", with: "\\\\")
                    .replacingOccurrences(of: "%", with: "\\%")
                    .replacingOccurrences(of: "_", with: "\\_")
                clauses.append("lower(faces.full_name) LIKE '%' || ? ESCAPE '\\'")
                bindings.append(.text(escaped))
            case .contains, .prefix, .tag: break
            }
        }
        return (clauses, bindings)
    }
}
