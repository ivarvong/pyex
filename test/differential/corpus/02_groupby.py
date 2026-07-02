items = [("fruit","apple"),("veg","carrot"),("fruit","pear"),("veg","pea"),("fruit","fig")]
groups = {}
for cat, name in items:
    groups.setdefault(cat, []).append(name)
for cat in sorted(groups):
    print(cat, sorted(groups[cat]))
