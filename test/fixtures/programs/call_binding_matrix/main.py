"""
Call binding matrix for routed work units.

This exercises positional-only parameters, keyword-only parameters, defaults,
*args, **kwargs, call-site unpacking, and TypeError paths without depending on
exact interpreter wording for the diagnostics.
"""


def route(account, region, /, action="read", *items, urgent=False, retries=1, **labels):
    ordered_labels = []
    for key in sorted(labels.keys()):
        ordered_labels.append((key, labels[key]))
    return (account, region, action, items, urgent, retries, ordered_labels)


def collect_errors(calls):
    rows = []
    for name, call in calls:
        try:
            call()
            rows.append((name, "ok"))
        except TypeError as exc:
            text = str(exc)
            if "positional-only" in text or "positional only" in text:
                kind = "posonly"
            elif "missing" in text:
                kind = "missing"
            elif "multiple" in text:
                kind = "multiple"
            else:
                kind = "type"
            rows.append((name, kind))
    return rows


base_args = ["acct", "eu"]
extra_args = ["x", "y"]
base_kwargs = {"urgent": True, "env": "prod"}
more_kwargs = {"retries": 3, "owner": "ops"}

rows = [
    route("acct", "us"),
    route("acct", "us", "write", "a", "b", urgent=True, retries=2, team="core"),
    route(*base_args, "sync", *extra_args, **base_kwargs, **more_kwargs),
]

assert rows == [
    ("acct", "us", "read", (), False, 1, []),
    ("acct", "us", "write", ("a", "b"), True, 2, [("team", "core")]),
    ("acct", "eu", "sync", ("x", "y"), True, 3, [("env", "prod"), ("owner", "ops")]),
]

errors = collect_errors(
    [
        ("posonly", lambda: route(account="acct", region="us")),
        ("missing", lambda: route("acct")),
        ("multiple", lambda: route("acct", "us", action="read", **{"action": "write"})),
    ]
)
assert errors == [("posonly", "posonly"), ("missing", "missing"), ("multiple", "multiple")]

for row in rows:
    print(row)
print("errors", errors)
