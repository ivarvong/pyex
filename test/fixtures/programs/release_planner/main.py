"""
Release planner with dependency and ownership constraints.

The planner validates task references, computes a stable topological order,
lays work out on single-owner calendars, and derives the critical chain from
the resulting schedule.  This gives the fixture enough state and graph shape
to catch subtle differences in object updates and control flow.
"""


class ReleasePlanner:
    def __init__(self, tasks):
        self.tasks = {}
        for task in tasks:
            self.tasks[task["name"]] = task
        self.children = self._children()

    def _children(self):
        graph = {}
        for name in self.tasks.keys():
            graph[name] = []

        for name, task in self.tasks.items():
            for dep in task["deps"]:
                if dep not in self.tasks:
                    raise ValueError("missing dependency: " + dep)
                graph[dep].append(name)

        for name in graph.keys():
            graph[name] = sorted(graph[name])
        return graph

    def topo_order(self):
        indegree = {}
        for name in self.tasks.keys():
            indegree[name] = len(self.tasks[name]["deps"])

        ready = []
        for name in sorted(indegree.keys()):
            if indegree[name] == 0:
                ready.append(name)

        order = []
        while len(ready) > 0:
            name = ready[0]
            ready = ready[1:]
            order.append(name)

            for child in self.children[name]:
                indegree[child] -= 1
                if indegree[child] == 0:
                    ready.append(child)
                    ready = sorted(ready)

        if len(order) != len(self.tasks):
            raise ValueError("cycle detected")
        return order

    def schedule(self, delays):
        owner_available = {}
        finish_times = {}
        rows = []

        for name in self.topo_order():
            task = self.tasks[name]
            owner = task["owner"]
            start = owner_available.get(owner, 0)

            for dep in task["deps"]:
                start = max(start, finish_times[dep])

            start += delays.get(name, 0)
            finish = start + task["duration"]
            owner_available[owner] = finish
            finish_times[name] = finish
            rows.append((name, owner, start, finish))

        return rows

    def critical_chain(self, schedule):
        by_name = {}
        for name, owner, start, finish in schedule:
            by_name[name] = (owner, start, finish)

        best_score = {}
        previous = {}
        for name in self.topo_order():
            score = self.tasks[name]["duration"]
            previous[name] = None
            for dep in self.tasks[name]["deps"]:
                candidate = best_score[dep] + self.tasks[name]["duration"]
                if candidate > score:
                    score = candidate
                    previous[name] = dep
            best_score[name] = score

        last = None
        for name in sorted(best_score.keys()):
            if last is None or best_score[name] > best_score[last]:
                last = name

        chain = []
        while last is not None:
            chain.append(last)
            last = previous[last]
        return list(reversed(chain))

    def makespan(self, schedule):
        end = 0
        for _, _, _, finish in schedule:
            end = max(end, finish)
        return end


tasks = [
    {"name": "auth", "duration": 3, "deps": [], "owner": "api"},
    {"name": "billing", "duration": 5, "deps": ["auth"], "owner": "api"},
    {"name": "catalog", "duration": 4, "deps": [], "owner": "data"},
    {"name": "search", "duration": 6, "deps": ["catalog"], "owner": "data"},
    {"name": "checkout", "duration": 4, "deps": ["billing", "catalog"], "owner": "api"},
    {"name": "docs", "duration": 2, "deps": ["auth"], "owner": "docs"},
    {"name": "launch", "duration": 1, "deps": ["checkout", "search", "docs"], "owner": "ops"},
]

planner = ReleasePlanner(tasks)
baseline = planner.schedule({})
delayed = planner.schedule({"catalog": 2})

assert planner.topo_order() == ["auth", "catalog", "billing", "docs", "search", "checkout", "launch"]
assert baseline == [
    ("auth", "api", 0, 3),
    ("catalog", "data", 0, 4),
    ("billing", "api", 3, 8),
    ("docs", "docs", 3, 5),
    ("search", "data", 4, 10),
    ("checkout", "api", 8, 12),
    ("launch", "ops", 12, 13),
]
assert planner.critical_chain(baseline) == ["auth", "billing", "checkout", "launch"]
assert planner.makespan(baseline) == 13
assert planner.makespan(delayed) == 14

for row in baseline:
    print(row)
print("critical", planner.critical_chain(baseline))
print("impact", planner.makespan(delayed) - planner.makespan(baseline))
