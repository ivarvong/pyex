"""
Ledger reconciliation gauntlet.

This is a scaled, deterministic data workload: generated account metadata,
hundreds of ledger events, idempotent duplicates, invalid rows, FX conversion,
audit lineage, sharded processing, shuffled replay, and checkpoint resume.
The fixture is intentionally easy to verify from its invariants and hard for
an interpreter with incorrect Python semantics to pass accidentally.
"""

import json


class LCG:
    def __init__(self, seed):
        self.seed = seed

    def next(self):
        self.seed = (1103515245 * self.seed + 12345) % (2**31)
        return self.seed

    def randint(self, lo, hi):
        return lo + (self.next() % (hi - lo + 1))

    def choice(self, items):
        return items[self.randint(0, len(items) - 1)]


def stable_hash(value):
    text = json.dumps(value, sort_keys=True)
    h = 2166136261
    for ch in text:
        h = h ^ ord(ch)
        h = (h * 16777619) % (2**32)
    return h


def canonical_pairs(mapping):
    rows = []
    for key in sorted(mapping.keys()):
        rows.append((key, mapping[key]))
    return rows


def make_accounts():
    regions = ["na", "eu", "apac", "latam"]
    currencies = ["USD", "EUR", "GBP", "JPY"]
    accounts = {}
    for i in range(36):
        account_id = "acct-%02d" % i
        accounts[account_id] = {
            "region": regions[i % len(regions)],
            "currency": currencies[(i * 3 + 1) % len(currencies)],
            "active": i % 11 != 0,
        }
    return accounts


def make_events(accounts):
    rng = LCG(8675309)
    account_ids = sorted(accounts.keys())
    currencies = ["USD", "EUR", "GBP", "JPY"]
    events = []

    for i in range(720):
        src = account_ids[rng.randint(0, len(account_ids) - 1)]
        dst = account_ids[(account_ids.index(src) + rng.randint(1, len(account_ids) - 1)) % len(account_ids)]
        amount = rng.randint(100, 25000)
        currency = rng.choice(currencies)
        day = 1 + (i % 28)
        event = {
            "id": "evt-%04d" % i,
            "kind": "transfer",
            "src": src,
            "dst": dst,
            "amount": amount,
            "currency": currency,
            "day": day,
        }
        events.append(event)

        if i % 37 == 0:
            duplicate = dict(event)
            duplicate["duplicate"] = True
            events.append(duplicate)

        if i % 53 == 0:
            events.append(
                {
                    "id": "bad-%04d" % i,
                    "kind": "transfer",
                    "src": src,
                    "dst": "missing-%02d" % (i % 7),
                    "amount": amount,
                    "currency": currency,
                    "day": day,
                }
            )

        if i % 61 == 0:
            events.append(
                {
                    "id": "negative-%04d" % i,
                    "kind": "transfer",
                    "src": src,
                    "dst": dst,
                    "amount": -amount,
                    "currency": currency,
                    "day": day,
                }
            )

    return events


def shuffle_events(events):
    rng = LCG(424242)
    items = list(events)
    for i in range(len(items) - 1, 0, -1):
        j = rng.randint(0, i)
        items[i], items[j] = items[j], items[i]
    return items


RATES = {"USD": 10000, "EUR": 10950, "GBP": 12725, "JPY": 67}


class Ledger:
    def __init__(self, accounts):
        self.accounts = accounts
        self.balances = {}
        self.accepted_ids = set()
        self.exceptions = []
        self.audit = []
        self.accepted_count = 0
        self.duplicate_count = 0

    def clone_state(self):
        return {
            "balances": dict(self.balances),
            "accepted_ids": set(self.accepted_ids),
            "exceptions": list(self.exceptions),
            "audit": list(self.audit),
            "accepted_count": self.accepted_count,
            "duplicate_count": self.duplicate_count,
        }

    def restore_state(self, state):
        self.balances = dict(state["balances"])
        self.accepted_ids = set(state["accepted_ids"])
        self.exceptions = list(state["exceptions"])
        self.audit = list(state["audit"])
        self.accepted_count = state["accepted_count"]
        self.duplicate_count = state["duplicate_count"]

    def reject(self, event, reason):
        self.exceptions.append((event["id"], reason))

    def apply(self, event):
        event_id = event["id"]
        if event_id in self.accepted_ids:
            self.duplicate_count += 1
            return

        src = event.get("src")
        dst = event.get("dst")
        amount = event.get("amount", 0)
        currency = event.get("currency")

        if src not in self.accounts or dst not in self.accounts:
            self.reject(event, "missing-account")
            return
        if not self.accounts[src]["active"] or not self.accounts[dst]["active"]:
            self.reject(event, "inactive-account")
            return
        if amount <= 0:
            self.reject(event, "non-positive")
            return
        if currency not in RATES:
            self.reject(event, "bad-currency")
            return

        usd_cents = (amount * RATES[currency]) // 10000
        self.balances[src] = self.balances.get(src, 0) - usd_cents
        self.balances[dst] = self.balances.get(dst, 0) + usd_cents
        self.accepted_ids.add(event_id)
        self.accepted_count += 1
        self.audit.append((event_id, src, dst, usd_cents))

    def process(self, events):
        for event in events:
            self.apply(event)
        return self

    def report(self):
        balances = canonical_pairs(self.balances)
        exceptions = sorted(self.exceptions)
        audit = sorted(self.audit)
        movement = 0
        for _, _, _, amount in audit:
            movement += amount
        balance_total = 0
        for _, amount in balances:
            balance_total += amount
        return {
            "accepted": self.accepted_count,
            "duplicates": self.duplicate_count,
            "exceptions": len(exceptions),
            "balance_total": balance_total,
            "movement": movement,
            "balances": balances,
            "exceptions_list": exceptions,
            "audit_hash": stable_hash(audit),
            "balance_hash": stable_hash(balances),
            "exception_hash": stable_hash(exceptions),
        }


def merge_reports(reports):
    balances = {}
    accepted = 0
    exceptions = 0
    duplicates = 0
    movement = 0
    audit_hashes = []
    exception_hashes = []
    for report in reports:
        accepted += report["accepted"]
        exceptions += report["exceptions"]
        duplicates += report["duplicates"]
        movement += report["movement"]
        audit_hashes.append(report["audit_hash"])
        exception_hashes.append(report["exception_hash"])
        for account, amount in report["balances"]:
            balances[account] = balances.get(account, 0) + amount
    return {
        "accepted": accepted,
        "duplicates": duplicates,
        "exceptions": exceptions,
        "balance_total": sum_values(balances),
        "movement": movement,
        "balance_hash": stable_hash(canonical_pairs(balances)),
        "audit_hash": stable_hash(sorted(audit_hashes)),
        "exception_hash": stable_hash(sorted(exception_hashes)),
    }


def sum_values(mapping):
    total = 0
    for value in mapping.values():
        total += value
    return total


def process_by_region(accounts, events):
    reports = []
    for region in ["apac", "eu", "latam", "na"]:
        subset = []
        for event in events:
            src = event.get("src")
            if src in accounts and accounts[src]["region"] == region:
                subset.append(event)
        reports.append(Ledger(accounts).process(subset).report())
    return merge_reports(reports)


accounts = make_accounts()
events = make_events(accounts)
baseline = Ledger(accounts).process(events).report()
shuffled = Ledger(accounts).process(shuffle_events(events)).report()

checkpoint = Ledger(accounts)
checkpoint.process(events[: len(events) // 2])
state = checkpoint.clone_state()
resumed = Ledger(accounts)
resumed.restore_state(state)
resumed.process(events[len(events) // 2 :])
replay = resumed.report()

regional = process_by_region(accounts, events)

assert baseline["balance_total"] == 0
assert baseline["movement"] > 0
assert baseline["accepted"] + baseline["duplicates"] + baseline["exceptions"] == len(events)
assert shuffled == baseline
assert replay == baseline
assert regional["accepted"] == baseline["accepted"]
assert regional["duplicates"] == baseline["duplicates"]
assert regional["exceptions"] == baseline["exceptions"]
assert regional["balance_total"] == 0
assert regional["movement"] == baseline["movement"]
assert regional["balance_hash"] == baseline["balance_hash"]

summary = {
    "events": len(events),
    "accounts": len(accounts),
    "accepted": baseline["accepted"],
    "duplicates": baseline["duplicates"],
    "exceptions": baseline["exceptions"],
    "movement": baseline["movement"],
    "balance_hash": baseline["balance_hash"],
    "audit_hash": baseline["audit_hash"],
    "exception_hash": baseline["exception_hash"],
    "regional_hash": regional["balance_hash"],
}

with open("balances.json", "w") as f:
    f.write(json.dumps(baseline["balances"], sort_keys=True))

with open("exceptions.csv", "w") as f:
    f.write("event_id,reason\n")
    for event_id, reason in baseline["exceptions_list"]:
        f.write(event_id + "," + reason + "\n")

with open("summary.json", "w") as f:
    f.write(json.dumps(summary, sort_keys=True))

print("summary", summary)
print("top_balances", baseline["balances"][:5])
print("exceptions_head", baseline["exceptions_list"][:5])
