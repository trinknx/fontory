import Testing
@testable import FontoryCore

@Suite struct LRUCacheTests {
    @Test func evictsLeastRecentlyUsed() {
        let c = LRUCache<String, Int>(limit: 2)
        c["a"] = 1; c["b"] = 2
        _ = c["a"]          // a is now most recent
        c["c"] = 3          // evicts b
        #expect(c["a"] == 1)
        #expect(c["b"] == nil)
        #expect(c["c"] == 3)
        c["a"] = nil
        #expect(c["a"] == nil)
        c.removeAll()
        #expect(c["c"] == nil)
    }
}
