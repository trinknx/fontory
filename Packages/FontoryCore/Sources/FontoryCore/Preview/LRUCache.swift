import Foundation

/// Thread-safe least-recently-used cache with O(1) get/set (dictionary + doubly linked list).
public final class LRUCache<Key: Hashable & Sendable, Value>: @unchecked Sendable {
    private final class Node {
        let key: Key
        var value: Value
        var prev: Node?
        unowned(unsafe) var next: Node?
        init(key: Key, value: Value) { self.key = key; self.value = value }
    }

    private let limit: Int
    private let lock = NSLock()
    private var nodes: [Key: Node] = [:]
    private var head: Node?   // most recently used
    private var tail: Node?   // least recently used

    public init(limit: Int) {
        self.limit = max(1, limit)
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
                if let node = nodes.removeValue(forKey: key) { unlink(node) }
                return
            }
            if let node = nodes[key] {
                node.value = newValue
                moveToFront(node)
                return
            }
            let node = Node(key: key, value: newValue)
            nodes[key] = node
            pushFront(node)
            if nodes.count > limit, let lru = tail {
                unlink(lru)
                nodes.removeValue(forKey: lru.key)
            }
        }
    }

    public func removeAll() {
        lock.lock(); defer { lock.unlock() }
        // Break the links so long chains don't deallocate recursively.
        var node = head
        while let n = node { node = n.next; n.prev = nil; n.next = nil }
        nodes.removeAll()
        head = nil; tail = nil
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
