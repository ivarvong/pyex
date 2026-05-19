"""
Session rollup for ordered activity streams.

The fixture covers stable sorting, gap-based grouping, duplicate suppression,
and deterministic aggregation over nested dictionaries.
"""


def compact_events(events):
    seen = set()
    rows = []
    for user, timestamp, action in events:
        key = (user, timestamp, action)
        if key not in seen:
            seen.add(key)
            rows.append(key)
    return sorted(rows)


def build_sessions(events, max_gap):
    sessions = {}
    for user, timestamp, action in compact_events(events):
        sessions.setdefault(user, [])
        user_sessions = sessions[user]

        if len(user_sessions) == 0 or timestamp - user_sessions[-1]["end"] > max_gap:
            user_sessions.append({"start": timestamp, "end": timestamp, "actions": [action]})
        else:
            user_sessions[-1]["end"] = timestamp
            user_sessions[-1]["actions"].append(action)

    return sessions


def transitions(sessions):
    counts = {}
    for user in sorted(sessions.keys()):
        for session in sessions[user]:
            actions = session["actions"]
            for i in range(len(actions) - 1):
                edge = (actions[i], actions[i + 1])
                counts[edge] = counts.get(edge, 0) + 1

    rows = []
    for edge in sorted(counts.keys()):
        rows.append((edge[0], edge[1], counts[edge]))
    return rows


def summary_rows(sessions):
    rows = []
    for user in sorted(sessions.keys()):
        total_duration = 0
        action_count = 0
        for session in sessions[user]:
            total_duration += session["end"] - session["start"]
            action_count += len(session["actions"])
        rows.append((user, len(sessions[user]), total_duration, action_count))
    return rows


events = [
    ("u2", 8, "view"),
    ("u1", 0, "open"),
    ("u1", 3, "view"),
    ("u1", 3, "view"),
    ("u1", 9, "click"),
    ("u1", 25, "open"),
    ("u2", 1, "open"),
    ("u2", 18, "buy"),
    ("u2", 19, "receipt"),
    ("u3", 4, "open"),
]

sessions = build_sessions(events, 6)
rows = summary_rows(sessions)
edges = transitions(sessions)

assert rows == [("u1", 2, 9, 4), ("u2", 2, 8, 4), ("u3", 1, 0, 1)]
assert edges == [("buy", "receipt", 1), ("open", "view", 2), ("view", "click", 1)]

for row in rows:
    print(row)
for edge in edges:
    print(edge)
