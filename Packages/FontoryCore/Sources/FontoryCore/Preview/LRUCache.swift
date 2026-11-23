import Foundation

/// Thread-safe least-recently-used cache with O(1) get/set (dictionary + doubly linked list).
/// Bounded by an entry count and, optionally, by a total cost (e.g. bytes) given per entry with `setValue(_:forKey:cost:)`.
public final class LRUCache<Key: Hashable & Sendable, Value>: @unchecked Sendable {
    private final class Node {
        let key: Key
        var value: Value
        var cost = 0
        var prev: Node?
        unowned(unsafe) var next: Node?
        init(key: Key, value: Value) { self.key = key; self.value = value }
    }

    private let limit: Int
    private let costLimit: Int
    private var cost = 0
    private let lock = NSLock()
    private var nodes: [Key: Node] = [:]
    private var head: Node?   // most recently used
    private var tail: Node?   // least recently used

    public init(limit: Int, costLimit: Int = .max) {
        self.limit = max(1, limit)
        self.costLimit = max(0, costLimit)
    }

    /// Sum of the costs of the entries currently held.
    public var totalCost: Int {
        lock.lock(); defer { lock.unlock() }
        return cost
    }

    /// Stores `value` with `cost`, evicting least recently used entries until both limits hold.
    /// A value costing more than the whole budget is not stored (and any old value for the key is removed).
    public func setValue(_ value: Value, forKey key: Key, cost newCost: Int) {
        lock.lock(); defer { lock.unlock() }
        insert(value, forKey: key, cost: max(0, newCost))
    }

    public subscript(key: Key) -> Value? {
        get {
            lock.lock(); defer { lock.unlock() }
            guard let node = nodes[key] else { return nil }
            moveToFront(node)
            return node.value
        }
        set {
            lock.lock(); defer { lock.unlock() }
            guard let newValue else {
                if let node = nodes.removeValue(forKey: key) { unlink(node); cost -= node.cost }
                return
            }
            insert(newValue, forKey: key, cost: 0)
        }
    }

    // Callers hold the lock.
    private func insert(_ value: Value, forKey key: Key, cost newCost: Int) {
        if let old = nodes.removeValue(forKey: key) {
            unlink(old)
            cost -= old.cost
        }
        guard newCost <= costLimit else { return }
        let node = Node(key: key, value: value)
        node.cost = newCost
        nodes[key] = node
        pushFront(node)
        cost += newCost
        while nodes.count > limit || cost > costLimit, let lru = tail, lru !== node {
            unlink(lru)
            nodes.removeValue(forKey: lru.key)
            cost -= lru.cost
        }
    }

    /// Removes every entry whose key matches.
    public func removeAll(where shouldRemove: (Key) -> Bool) {
        lock.lock(); defer { lock.unlock() }
        for (key, node) in nodes where shouldRemove(key) {
            nodes.removeValue(forKey: key)
            unlink(node)
            cost -= node.cost
        }
    }

    public func removeAll() {
        lock.lock(); defer { lock.unlock() }
        // Break the links so long chains don't deallocate recursively.
        var node = head
        while let n = node { node = n.next; n.prev = nil; n.next = nil }
        nodes.removeAll()
        head = nil; tail = nil
        cost = 0
    }

    // Callers hold the lock.
    private func pushFront(_ node: Node) {
        node.prev = nil
        node.next = head
        head?.prev = node
        head = node
        if tail == nil { tail = node }
    }

    private func unlink(_ node: Node) {
        if let p = node.prev { p.next = node.next } else { head = node.next }
        if let n = node.next { n.prev = node.prev } else { tail = node.prev }
        node.prev = nil; node.next = nil
    }

    private func moveToFront(_ node: Node) {
        guard head !== node else { return }
        unlink(node)
        pushFront(node)
    }
}
