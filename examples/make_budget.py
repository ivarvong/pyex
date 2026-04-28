import spreadsheet
from spreadsheet import formula

wb = spreadsheet.Workbook()

quarters = [
    ("Q1", ["January", "February", "March"]),
    ("Q2", ["April", "May", "June"]),
    ("Q3", ["July", "August", "September"]),
    ("Q4", ["October", "November", "December"]),
]

revenue_data = {
    "Q1": {"Product Sales": [48000, 51000, 54000], "Services": [18000, 19000, 20000], "Licensing": [9000, 9500, 10000]},
    "Q2": {"Product Sales": [56000, 58000, 62000], "Services": [21000, 22000, 23000], "Licensing": [10500, 11000, 11500]},
    "Q3": {"Product Sales": [60000, 59000, 63000], "Services": [22000, 21000, 23000], "Licensing": [11000, 11000, 12000]},
    "Q4": {"Product Sales": [65000, 70000, 80000], "Services": [24000, 25000, 28000], "Licensing": [12000, 12500, 14000]},
}

expenses_data = {
    "Q1": {"Payroll": [35000, 35000, 36000], "Marketing": [7000, 7500, 8000], "Infrastructure": [4500, 4500, 5000], "R&D": [9000, 9000, 9500], "G&A": [3500, 3500, 4000]},
    "Q2": {"Payroll": [36000, 36000, 37000], "Marketing": [8500, 9000, 9500], "Infrastructure": [5000, 5000, 5500], "R&D": [9500, 10000, 10000], "G&A": [4000, 4000, 4500]},
    "Q3": {"Payroll": [37000, 37000, 38000], "Marketing": [9000, 8500, 10000], "Infrastructure": [5500, 5500, 6000], "R&D": [10000, 10000, 11000], "G&A": [4000, 4000, 4500]},
    "Q4": {"Payroll": [38000, 38000, 40000], "Marketing": [10000, 12000, 15000], "Infrastructure": [6000, 6000, 7000], "R&D": [11000, 11000, 12000], "G&A": [4500, 4500, 5000]},
}

for q_name, months in quarters:
    ws = wb.sheet(q_name)
    ws.freeze(rows=1)
    ws.col_width(1, 20)
    ws.col_width("B:E", 14)

    ws.write_header(["Category", months[0], months[1], months[2], "Quarter Total"])

    # Revenue section
    ws.write("A2", "Revenue", style="bold")
    rev = revenue_data[q_name]
    for row, (cat, vals) in enumerate(rev.items(), start=3):
        r = str(row)
        ws.write("A" + r, cat, style="text")
        ws.write("B" + r, vals[0], style="number")
        ws.write("C" + r, vals[1], style="number")
        ws.write("D" + r, vals[2], style="number")
        ws.write("E" + r, formula("SUM(B" + r + ":D" + r + ")", sum(vals)), style="number")
    ws.write("A6", "Total Revenue", style="bold")
    for col, letter in enumerate("BCDE", start=2):
        ws.write(letter + "6", formula("SUM(" + letter + "3:" + letter + "5)", 0), style="subtotal")

    # Expenses section
    ws.write("A8", "Expenses", style="bold")
    exp = expenses_data[q_name]
    for row, (cat, vals) in enumerate(exp.items(), start=9):
        r = str(row)
        ws.write("A" + r, cat, style="text")
        ws.write("B" + r, vals[0], style="number")
        ws.write("C" + r, vals[1], style="number")
        ws.write("D" + r, vals[2], style="number")
        ws.write("E" + r, formula("SUM(B" + r + ":D" + r + ")", sum(vals)), style="number")
    ws.write("A14", "Total Expenses", style="bold")
    for col, letter in enumerate("BCDE", start=2):
        ws.write(letter + "14", formula("SUM(" + letter + "9:" + letter + "13)", 0), style="subtotal")

    # Net Income
    ws.write("A16", "Net Income", style="bold")
    for col, letter in enumerate("BCDE", start=2):
        ws.write(letter + "16", formula(letter + "6-" + letter + "14", 0), style="subtotal")

# Full Year summary sheet
ws = wb.sheet("Full Year")
ws.freeze(rows=1)
ws.col_width(1, 20)
ws.col_width("B:F", 14)

ws.write_header(["Category", "Q1", "Q2", "Q3", "Q4", "Full Year"])

ws.write("A2", "Revenue",       style="bold")
ws.write("B2", formula("'Q1'!E6",  238500), style="number")
ws.write("C2", formula("'Q2'!E6",  275000), style="number")
ws.write("D2", formula("'Q3'!E6",  282000), style="number")
ws.write("E2", formula("'Q4'!E6",  330500), style="number")
ws.write("F2", formula("SUM(B2:E2)", 1126000), style="subtotal")

ws.write("A3", "Expenses",      style="bold")
ws.write("B3", formula("'Q1'!E14", 181000), style="number")
ws.write("C3", formula("'Q2'!E14", 193500), style="number")
ws.write("D3", formula("'Q3'!E14", 200000), style="number")
ws.write("E3", formula("'Q4'!E14", 220000), style="number")
ws.write("F3", formula("SUM(B3:E3)", 794500), style="subtotal")

ws.write("A5", "Net Income",    style="bold")
ws.write("B5", formula("'Q1'!E16",  57500), style="number")
ws.write("C5", formula("'Q2'!E16",  81500), style="number")
ws.write("D5", formula("'Q3'!E16",  82000), style="number")
ws.write("E5", formula("'Q4'!E16", 110500), style="number")
ws.write("F5", formula("SUM(B5:E5)", 331500), style="subtotal")

# Revenue by Category breakdown
ws.write("A7", "Revenue by Category", style="bold")
ws.write_row(["", "Q1", "Q2", "Q3", "Q4", "Annual"], style="header")
for cat, q1, q2, q3, q4 in [
    ("Product Sales", 153000, 176000, 182000, 215000),
    ("Services",       57000,  66000,  66000,  77000),
    ("Licensing",      28500,  33000,  34000,  38500),
]:
    ws.write_row([cat, q1, q2, q3, q4, formula("SUM(B" + str(ws._cur) + ":E" + str(ws._cur) + ")", q1+q2+q3+q4)], style="number")

ws.skip(1)

# Expenses by Category breakdown
ws.write("A12", "Expenses by Category", style="bold")
ws.write_row(["", "Q1", "Q2", "Q3", "Q4", "Annual"], style="header")
for cat, q1, q2, q3, q4 in [
    ("Payroll",        106000, 109000, 112000, 116000),
    ("Marketing",       22500,  27000,  27500,  37000),
    ("Infrastructure",  14000,  15500,  17000,  19000),
    ("R&D",             27500,  29500,  31000,  34000),
    ("G&A",             11000,  12500,  12500,  14000),
]:
    ws.write_row([cat, q1, q2, q3, q4, formula("SUM(B" + str(ws._cur) + ":E" + str(ws._cur) + ")", q1+q2+q3+q4)], style="number")

wb.save("budget.xlsx")
