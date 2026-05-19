"""
Iterator boundary behavior under mutation.

CPython list iterators observe appended elements as iteration advances, while
iteration over a slice uses the copied list.  The fixture also checks that
manual index loops see current container state after removals.
"""


items = [1, 2]
seen = []
for item in items:
    seen.append(item)
    if item == 2:
        items.append(3)
        items.append(4)
    elif item == 3:
        items.append(5)

assert seen == [1, 2, 3, 4, 5]
assert items == [1, 2, 3, 4, 5]

copied_source = ["a", "b"]
copied_seen = []
for value in copied_source[:]:
    copied_seen.append(value)
    copied_source.append(value.upper())

assert copied_seen == ["a", "b"]
assert copied_source == ["a", "b", "A", "B"]

queue = [1, 2, 3, 4, 5]
processed = []
index = 0
while index < len(queue):
    value = queue[index]
    processed.append(value)
    if value % 2 == 0:
        queue.pop(index)
    else:
        index += 1

assert processed == [1, 2, 3, 4, 5]
assert queue == [1, 3, 5]

print("seen", seen)
print("items", items)
print("copied", copied_seen, copied_source)
print("processed", processed, queue)
