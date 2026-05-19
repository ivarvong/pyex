"""
Activity window rollup.

This fixture keeps the workload small but intentionally mixes interval
normalization, half-open boundary handling, tuple ordering, and dictionary
aggregation.  The output is deterministic CPython ground truth for the same
business-shaped logic Pyex needs to execute correctly.
"""


def merge_windows(windows):
    normalized = []
    for start, end in windows:
        if end > start:
            normalized.append((start, end))

    merged = []
    for start, end in sorted(normalized):
        if len(merged) == 0:
            merged.append((start, end))
            continue

        last_start, last_end = merged[-1]
        if start <= last_end:
            merged[-1] = (last_start, max(last_end, end))
        else:
            merged.append((start, end))
    return merged


def covered_minutes(windows):
    total = 0
    for start, end in merge_windows(windows):
        total += end - start
    return total


def peak_concurrency(events):
    points = []
    for _, start, end in events:
        if end > start:
            points.append((start, 1))
            points.append((end, -1))

    active = 0
    best = 0
    best_time = None
    for timestamp, delta in sorted(points):
        active += delta
        if active > best:
            best = active
            best_time = timestamp
    return best_time, best


def summarize(events):
    by_user = {}
    for user, start, end in events:
        by_user.setdefault(user, [])
        by_user[user].append((start, end))

    rows = []
    for user in sorted(by_user.keys()):
        rows.append((user, covered_minutes(by_user[user]), merge_windows(by_user[user])))
    return rows


events = [
    ("ada", 10, 25),
    ("ada", 20, 40),
    ("bea", 0, 15),
    ("cal", 12, 18),
    ("bea", 15, 20),
    ("ada", 50, 50),
    ("dan", 39, 45),
    ("cal", 18, 21),
]

summary = summarize(events)
assert summary == [
    ("ada", 30, [(10, 40)]),
    ("bea", 20, [(0, 20)]),
    ("cal", 9, [(12, 21)]),
    ("dan", 6, [(39, 45)]),
]
assert peak_concurrency(events) == (12, 3)

for user, minutes, windows in summary:
    print(user, minutes, windows)

peak_time, peak = peak_concurrency(events)
print("peak", peak_time, peak)
