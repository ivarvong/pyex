"""
Object protocol dispatch in ordinary collection-shaped code.

The fixture exercises user-defined __len__, __iter__, __eq__, __repr__, and
inheritance dispatch while mixing object identity, equality, and mutation.
"""


class Bag:
    def __init__(self, name, items):
        self.name = name
        self.items = list(items)

    def __len__(self):
        return len(self.items)

    def __iter__(self):
        return iter(self.items)

    def __eq__(self, other):
        if not isinstance(other, Bag):
            return False
        return sorted(self.items) == sorted(other.items)

    def __repr__(self):
        return "Bag(" + self.name + ":" + ",".join(sorted(self.items)) + ")"

    def add(self, item):
        self.items.append(item)


class TaggedBag(Bag):
    def __init__(self, name, items, tag):
        super().__init__(name, items)
        self.tag = tag

    def label(self):
        return self.tag + ":" + self.name


def summarize(bags):
    rows = []
    for bag in bags:
        rows.append((bag.label() if hasattr(bag, "label") else bag.name, len(bag), list(bag)))
    return rows


left = Bag("left", ["pear", "apple"])
same = Bag("same", ["apple", "pear"])
other = Bag("other", ["apple"])
tagged = TaggedBag("ship", ["box"], "fast")

assert left == same
assert left != other
assert left is not same
assert bool(left)
assert not bool(Bag("empty", []))

tagged.add("label")
rows = summarize([left, other, tagged])
assert rows == [
    ("left", 2, ["pear", "apple"]),
    ("other", 1, ["apple"]),
    ("fast:ship", 2, ["box", "label"]),
]
assert repr(left) == "Bag(left:apple,pear)"

print("eq", left == same, left != other, left is same)
print("truth", bool(left), bool(Bag("empty", [])))
print("rows", rows)
print("repr", repr(left))
