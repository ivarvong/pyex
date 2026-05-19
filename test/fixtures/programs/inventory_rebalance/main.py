"""
Inventory rebalance across regional pools.

The allocator satisfies demand from preferred warehouses first, falls back to
same-region capacity, then uses cross-region stock.  All mutations are staged
so failed orders do not partially consume inventory.
"""


class Inventory:
    def __init__(self, stock, regions):
        self.stock = {}
        for warehouse, items in stock.items():
            self.stock[warehouse] = dict(items)
        self.regions = dict(regions)

    def available(self, warehouse, sku):
        return self.stock.get(warehouse, {}).get(sku, 0)

    def plan_order(self, order):
        sku = order["sku"]
        remaining = order["qty"]
        plan = []

        candidates = []
        preferred = order["preferred"]
        for warehouse in preferred:
            candidates.append(warehouse)

        target_region = self.regions[preferred[0]]
        for warehouse in sorted(self.stock.keys()):
            if warehouse not in candidates and self.regions[warehouse] == target_region:
                candidates.append(warehouse)

        for warehouse in sorted(self.stock.keys()):
            if warehouse not in candidates:
                candidates.append(warehouse)

        for warehouse in candidates:
            take = min(remaining, self.available(warehouse, sku))
            if take > 0:
                plan.append((warehouse, sku, take))
                remaining -= take
            if remaining == 0:
                break

        if remaining != 0:
            return None
        return plan

    def commit(self, plan):
        for warehouse, sku, qty in plan:
            self.stock[warehouse][sku] -= qty

    def fulfill(self, orders):
        shipped = []
        rejected = []
        for order in orders:
            plan = self.plan_order(order)
            if plan is None:
                rejected.append(order["id"])
            else:
                self.commit(plan)
                shipped.append((order["id"], plan))
        return shipped, rejected

    def snapshot(self):
        rows = []
        for warehouse in sorted(self.stock.keys()):
            for sku in sorted(self.stock[warehouse].keys()):
                qty = self.stock[warehouse][sku]
                if qty != 0:
                    rows.append((warehouse, sku, qty))
        return rows


stock = {
    "east-1": {"book": 4, "pen": 3},
    "east-2": {"book": 2, "pen": 5},
    "west-1": {"book": 6, "pen": 1},
}
regions = {"east-1": "east", "east-2": "east", "west-1": "west"}
orders = [
    {"id": "o1", "sku": "book", "qty": 5, "preferred": ["east-1"]},
    {"id": "o2", "sku": "pen", "qty": 7, "preferred": ["east-2"]},
    {"id": "o3", "sku": "book", "qty": 5, "preferred": ["west-1"]},
    {"id": "o4", "sku": "pen", "qty": 3, "preferred": ["west-1"]},
]

inventory = Inventory(stock, regions)
shipped, rejected = inventory.fulfill(orders)

assert shipped == [
    ("o1", [("east-1", "book", 4), ("east-2", "book", 1)]),
    ("o2", [("east-2", "pen", 5), ("east-1", "pen", 2)]),
    ("o3", [("west-1", "book", 5)]),
    ("o4", [("west-1", "pen", 1), ("east-1", "pen", 1), ("east-2", "pen", 1)]),
]
assert rejected == []
assert inventory.snapshot() == [("east-2", "book", 1), ("west-1", "book", 1)]

for row in shipped:
    print(row)
print("rejected", rejected)
print("stock", inventory.snapshot())
