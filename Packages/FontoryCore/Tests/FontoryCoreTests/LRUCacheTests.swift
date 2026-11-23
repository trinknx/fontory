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

    @Test func evictsByTotalCost() {
        let c = LRUCache<String, Int>(limit: 100, costLimit: 10)
        c.setValue(1, forKey: "a", cost: 4)
        c.setValue(2, forKey: "b", cost: 4)
        #expect(c.totalCost == 8)
        _ = c["a"]                              // b is now least recent
        c.setValue(3, forKey: "c", cost: 4)     // 12 > 10: evicts b
        #expect(c["b"] == nil && c["a"] == 1 && c["c"] == 3)
        #expect(c.totalCost == 8)
        c.setValue(4, forKey: "a", cost: 1)     // replacing updates the cost
        #expect(c.totalCost == 5)
        c["c"] = nil
        #expect(c.totalCost == 1)
        c.setValue(5, forKey: "big", cost: 50)  // larger than the budget: not kept, nothing else evicted
        #expect(c["big"] == nil && c["a"] == 4)
        c.removeAll()
        #expect(c.totalCost == 0)
    }

    @Test func countLimitStillApplies() {
        let c = LRUCache<Int, Int>(limit: 2, costLimit: 1000)
        for i in 0..<3 { c.setValue(i, forKey: i, cost: 1) }
        #expect(c[0] == nil && c[1] == 1 && c[2] == 2 && c.totalCost == 2)
    }
}
