"""
Read a CSV file, compute statistics, and write a summary report.
Exercises: csv module, file I/O, string formatting, sorted/lambda,
list comprehensions, f-strings, dict operations.
"""

import csv
import json

# Read the input CSV
with open("data.csv", "r") as f:
    reader = csv.DictReader(f)
    rows = [row for row in reader]

# Parse scores as integers
for row in rows:
    row["score"] = int(row["score"])

# Compute statistics
scores = [row["score"] for row in rows]
total = sum(scores)
count = len(scores)
average = total / count
highest = max(scores)
lowest = min(scores)

# Sort by score descending
ranked = sorted(rows, key=lambda r: r["score"], reverse=True)

# Build summary
lines = []
lines.append(f"Student Report ({count} students)")
lines.append(f"Average: {average:.1f}")
lines.append(f"Highest: {highest}")
lines.append(f"Lowest: {lowest}")
lines.append("")
lines.append("Rankings:")
for i, row in enumerate(ranked, 1):
    lines.append(f"  {i}. {row['name']}: {row['score']}")

summary = "\n".join(lines)
print(summary)

# Write JSON report
report = {
    "count": count,
    "average": average,
    "highest": highest,
    "lowest": lowest,
    "rankings": [{"name": r["name"], "score": r["score"]} for r in ranked],
}

with open("report.json", "w") as f:
    f.write(json.dumps(report, indent=2))
