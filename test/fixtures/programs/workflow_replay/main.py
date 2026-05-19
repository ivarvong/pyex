"""
Workflow event replay with dependency gating.

Events may arrive out of order.  The replay engine accepts completed steps,
unblocks dependent steps when all prerequisites are done, and records stale or
invalid events without mutating the terminal state.
"""


class WorkflowReplay:
    def __init__(self, dependencies):
        self.dependencies = {}
        self.children = {}
        self.completed = set()
        self.ready = set()
        self.invalid = []

        for step, deps in dependencies.items():
            self.dependencies[step] = list(deps)
            self.children[step] = []

        for step, deps in self.dependencies.items():
            for dep in deps:
                self.children.setdefault(dep, [])
                self.children[dep].append(step)

        for step in self.children.keys():
            self.children[step] = sorted(self.children[step])

        for step, deps in self.dependencies.items():
            if len(deps) == 0:
                self.ready.add(step)

    def _deps_done(self, step):
        for dep in self.dependencies.get(step, []):
            if dep not in self.completed:
                return False
        return True

    def _release_children(self, step):
        released = []
        for child in self.children.get(step, []):
            if child not in self.completed and self._deps_done(child):
                self.ready.add(child)
                released.append(child)
        return released

    def apply(self, event):
        seq, kind, step = event
        if step not in self.dependencies:
            self.invalid.append((seq, step, "unknown"))
            return []

        if kind != "complete":
            self.invalid.append((seq, step, "kind"))
            return []

        if step in self.completed:
            self.invalid.append((seq, step, "duplicate"))
            return []

        if step not in self.ready:
            self.invalid.append((seq, step, "blocked"))
            return []

        self.ready.remove(step)
        self.completed.add(step)
        return self._release_children(step)

    def replay(self, events):
        audit = []
        for event in sorted(events):
            released = self.apply(event)
            audit.append((event[0], event[2], sorted(released), self.open_steps()))
        return audit

    def open_steps(self):
        return sorted(self.ready)

    def done_steps(self):
        return sorted(self.completed)


deps = {
    "extract": [],
    "profile": ["extract"],
    "validate": ["extract"],
    "normalize": ["profile", "validate"],
    "publish": ["normalize"],
    "notify": ["publish"],
}

events = [
    (4, "complete", "validate"),
    (1, "complete", "extract"),
    (8, "complete", "notify"),
    (3, "complete", "profile"),
    (2, "complete", "missing"),
    (5, "complete", "normalize"),
    (6, "complete", "publish"),
    (7, "complete", "publish"),
]

replay = WorkflowReplay(deps)
audit = replay.replay(events)

assert audit == [
    (1, "extract", ["profile", "validate"], ["profile", "validate"]),
    (2, "missing", [], ["profile", "validate"]),
    (3, "profile", [], ["validate"]),
    (4, "validate", ["normalize"], ["normalize"]),
    (5, "normalize", ["publish"], ["publish"]),
    (6, "publish", ["notify"], ["notify"]),
    (7, "publish", [], ["notify"]),
    (8, "notify", [], []),
]
assert replay.done_steps() == ["extract", "normalize", "notify", "profile", "publish", "validate"]
assert replay.invalid == [(2, "missing", "unknown"), (7, "publish", "duplicate")]

for row in audit:
    print(row)
print("done", replay.done_steps())
print("invalid", replay.invalid)
