"""
LRU Cache with O(1) get/put/evict.

Built from scratch:
  - Python dict for O(1) key lookup
  - Intrusive doubly-linked list for recency ordering
  - Sentinel head/tail nodes to eliminate edge cases

This is the classic systems-interview LRU: every operation is O(1),
the linked list maintains access order via prev/next pointers on Node
objects, and eviction is a constant-time pop from the tail.  Mutations
to `node.prev.next` propagate through shared references, exactly like
CPython.
"""


class _Node:
    """Intrusive doubly-linked list node."""

    def __init__(self, key, value):
        self.key = key
        self.value = value
        self.prev = None
        self.next = None


class LRUCache:
    """Least-recently-used cache.

    - get(key)        → O(1), promotes to head
    - put(key, value) → O(1), inserts at head, evicts tail if full
    - __len__         → O(1)
    """

    def __init__(self, capacity):
        if capacity <= 0:
            raise ValueError("capacity must be positive")
        self._capacity = capacity
        self._map = {}
        self._head = _Node(None, None)
        self._tail = _Node(None, None)
        self._head.next = self._tail
        self._tail.prev = self._head
        self._size = 0

    def _remove(self, node):
        """Unlink a node from the list."""
        node.prev.next = node.next
        node.next.prev = node.prev
        node.prev = None
        node.next = None

    def _push_front(self, node):
        """Insert node right after the head sentinel."""
        node.next = self._head.next
        node.prev = self._head
        self._head.next.prev = node
        self._head.next = node

    def _pop_back(self):
        """Remove and return the least-recent node."""
        node = self._tail.prev
        if node is self._head:
            return None
        self._remove(node)
        return node

    def get(self, key, default=-1):
        node = self._map.get(key)
        if node is None:
            return default
        self._remove(node)
        self._push_front(node)
        return node.value

    def put(self, key, value):
        node = self._map.get(key)
        if node is not None:
            node.value = value
            self._remove(node)
            self._push_front(node)
            return

        if self._size >= self._capacity:
            victim = self._pop_back()
            if victim is not None:
                self._map.pop(victim.key)
                self._size -= 1

        node = _Node(key, value)
        self._map[key] = node
        self._push_front(node)
        self._size += 1

    def __len__(self):
        return self._size

    def items_mru(self):
        """Iterate most-recent first."""
        result = []
        cur = self._head.next
        while cur is not self._tail:
            result.append((cur.key, cur.value))
            cur = cur.next
        return result

    def items_lru(self):
        """Iterate least-recent first."""
        result = []
        cur = self._tail.prev
        while cur is not self._head:
            result.append((cur.key, cur.value))
            cur = cur.prev
        return result


# ── Tests ────────────────────────────────────────────────────────

c = LRUCache(3)
c.put("a", 1)
c.put("b", 2)
c.put("c", 3)
assert c.get("a") == 1
assert c.get("b") == 2
assert c.get("c") == 3
assert c.get("z") == -1
assert len(c) == 3
print("basic put/get passed")

c = LRUCache(2)
c.put("a", 1)
c.put("b", 2)
c.put("c", 3)
assert c.get("a") == -1
assert c.get("b") == 2
assert c.get("c") == 3
assert len(c) == 2
print("eviction passed")

c = LRUCache(2)
c.put("a", 1)
c.put("b", 2)
c.get("a")
c.put("c", 3)
assert c.get("b") == -1
assert c.get("a") == 1
assert c.get("c") == 3
print("access promotes passed")

c = LRUCache(2)
c.put("a", 1)
c.put("b", 2)
c.put("a", 10)
c.put("c", 3)
assert c.get("a") == 10
assert c.get("b") == -1
assert c.get("c") == 3
print("update existing passed")

c = LRUCache(4)
c.put("a", 1)
c.put("b", 2)
c.put("c", 3)
c.get("a")
c.put("d", 4)
mru = c.items_mru()
assert mru == [("d", 4), ("a", 1), ("c", 3), ("b", 2)]
lru = c.items_lru()
assert lru == [("b", 2), ("c", 3), ("a", 1), ("d", 4)]
print("ordering passed")

c = LRUCache(1)
c.put("a", 1)
assert c.get("a") == 1
c.put("b", 2)
assert c.get("a") == -1
assert c.get("b") == 2
assert len(c) == 1
print("capacity one passed")

c = LRUCache(5)
for i in range(10):
    c.put(i, i * 10)
assert len(c) == 5
for i in range(5):
    assert c.get(i) == -1
for i in range(5, 10):
    assert c.get(i) == i * 10
print("large workload passed")

c = LRUCache(3)
c.put("hello", "world")
c.put("foo", "bar")
c.put("baz", "qux")
assert c.get("hello") == "world"
assert c.get("foo") == "bar"
c.put("new", "val")
assert c.get("baz") == -1
print("string keys passed")

c = LRUCache(3)
c.put("a", 1)
c.put("b", 2)
c.put("c", 3)
for _ in range(10):
    c.get("a")
    c.put("x", 99)
    c.put("y", 100)
assert c.get("a") == 1
print("repeated access passed")

print(f"\nAll {9} tests passed.")
