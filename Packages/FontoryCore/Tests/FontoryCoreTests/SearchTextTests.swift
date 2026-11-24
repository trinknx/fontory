import Testing
@testable import FontoryCore

@Suite struct SearchTextTests {
    @Test func parsesModes() {
        let s = SearchText("\"Helvetica Neue\" bold* *italic grot")
        #expect(s.terms.map(\.mode) == [.exact, .prefix, .suffix, .contains])
        #expect(s.terms.map(\.text) == ["Helvetica Neue", "bold", "italic", "grot"])
    }

    @Test func tagsAreKeptButNotFTS() {
        let s = SearchText("#serif")
        #expect(s.terms.map(\.mode) == [.tag])
        #expect(s.ftsMatch == nil)
    }

    @Test func ftsEscapesQuotes() {
        let s = SearchText("a\"b")
        #expect(s.ftsMatch?.contains("\"a\"\"b\"*") == true)
    }

    @Test func scopeLimitsColumns() {
        let s = SearchText("grot", scope: [.family])
        #expect(s.ftsMatch == "{family custom_family} : \"grot\"*")
        let all = SearchText("grot")
        #expect(all.ftsMatch?.hasPrefix("{") == true)
        #expect(all.ftsMatch?.contains("vendor") == true)
    }

    @Test func multipleTermsAnd() {
        #expect(SearchText("a b", scope: [.family]).ftsMatch == "{family custom_family} : \"a\"* AND {family custom_family} : \"b\"*")
    }

    @Test func emptyInputHasNoTerms() {
        #expect(SearchText("  * # ").terms.isEmpty)
        #expect(SearchText("").ftsMatch == nil)
    }
}
