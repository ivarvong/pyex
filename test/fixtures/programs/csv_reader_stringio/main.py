"""
csv.reader and csv.DictReader both accept io.StringIO as input.
Exercises: csv module with in-memory string buffers.
"""
import csv
import io

# csv.reader with StringIO
data = "name,age,city\nAlice,30,NYC\nBob,25,LA\n"
rows = list(csv.reader(io.StringIO(data)))
print(rows[0])
print(rows[1])
print(rows[2])
print(len(rows))

# csv.DictReader with StringIO + mutation
sales_data = "product,qty,price\nWidget,10,5.99\nGadget,3,12.50\n"
items = list(csv.DictReader(io.StringIO(sales_data)))
for item in items:
    item["qty"] = int(item["qty"])
    item["total"] = round(item["qty"] * float(item["price"]), 2)

print(items[0]["total"])
print(items[1]["total"])
print(items[0]["product"])

# csv.reader with custom delimiter
tsv_data = "a\tb\tc\n1\t2\t3\n"
tsv_rows = list(csv.reader(io.StringIO(tsv_data), delimiter="\t"))
print(tsv_rows[0])
print(tsv_rows[1])
