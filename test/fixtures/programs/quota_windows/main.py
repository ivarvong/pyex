"""
Sliding quota window reconciliation.

The ledger combines per-organization and per-user rolling windows with
idempotency keys.  It is deliberately written without external services or
stdlib helpers so the fixture exercises plain Python control flow, object
mutation, and nested dictionaries.
"""


class SlidingCounter:
    def __init__(self, window):
        self.window = window
        self.entries = []
        self.total = 0

    def prune(self, now):
        cutoff = now - self.window
        kept = []
        total = 0
        for timestamp, amount in self.entries:
            if timestamp > cutoff:
                kept.append((timestamp, amount))
                total += amount
        self.entries = kept
        self.total = total

    def can_add(self, now, amount, limit):
        self.prune(now)
        return self.total + amount <= limit

    def add(self, now, amount):
        self.prune(now)
        self.entries.append((now, amount))
        self.total += amount


class QuotaLedger:
    def __init__(self, org_limit, user_limit, window):
        self.org_limit = org_limit
        self.user_limit = user_limit
        self.window = window
        self.orgs = {}
        self.users = {}
        self.decisions = {}

    def _org_counter(self, org):
        if org not in self.orgs:
            self.orgs[org] = SlidingCounter(self.window)
        return self.orgs[org]

    def _user_counter(self, org, user):
        key = (org, user)
        if key not in self.users:
            self.users[key] = SlidingCounter(self.window)
        return self.users[key]

    def admit(self, org, user, now, amount, request_id):
        if request_id in self.decisions:
            return self.decisions[request_id]

        org_counter = self._org_counter(org)
        user_counter = self._user_counter(org, user)

        if not org_counter.can_add(now, amount, self.org_limit):
            decision = (False, "org", org_counter.total)
        elif not user_counter.can_add(now, amount, self.user_limit):
            decision = (False, "user", user_counter.total)
        else:
            org_counter.add(now, amount)
            user_counter.add(now, amount)
            decision = (True, "ok", org_counter.total)

        self.decisions[request_id] = decision
        return decision

    def snapshot(self, now):
        rows = []
        for org in sorted(self.orgs.keys()):
            counter = self.orgs[org]
            counter.prune(now)
            rows.append((org, counter.total))
        return rows


ledger = QuotaLedger(10, 6, 60)
requests = [
    ("acme", "u1", 0, 3, "r1"),
    ("acme", "u1", 10, 2, "r2"),
    ("acme", "u2", 20, 4, "r3"),
    ("acme", "u1", 30, 2, "r4"),
    ("acme", "u3", 40, 3, "r5"),
    ("acme", "u2", 70, 5, "r6"),
    ("beta", "u9", 72, 6, "r7"),
    ("beta", "u9", 73, 1, "r8"),
    ("acme", "u1", 30, 2, "r4"),
]

results = []
for request in requests:
    results.append(ledger.admit(request[0], request[1], request[2], request[3], request[4]))

assert results == [
    (True, "ok", 3),
    (True, "ok", 5),
    (True, "ok", 9),
    (False, "user", 5),
    (False, "org", 9),
    (True, "ok", 9),
    (True, "ok", 6),
    (False, "user", 6),
    (False, "user", 5),
]
assert ledger.snapshot(75) == [("acme", 5), ("beta", 6)]

for accepted, reason, total in results:
    print(accepted, reason, total)
print("snapshot", ledger.snapshot(75))
