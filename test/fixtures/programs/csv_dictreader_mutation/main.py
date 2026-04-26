"""
csv.DictReader rows are mutable dicts: mutations in a for-loop persist
when accessing via the original list.
Exercises: csv module, io.StringIO, dict mutation, for-loop semantics.
"""
import csv
import io

data = "name,score,grade\nAlice,92,A\nBob,74,B\nCarol,88,A\n"
rows = list(csv.DictReader(io.StringIO(data)))

# Mutate each row in-place
for r in rows:
    r["score"] = int(r["score"])
    r["label"] = r["name"].upper() + ":" + str(r["score"])

# Mutations should be visible through the original list
print(rows[0]["score"])
print(rows[1]["score"])
print(rows[2]["score"])
print(rows[0]["label"])
print(rows[1]["label"])
print(rows[2]["label"])
print(len(rows))
