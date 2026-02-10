import sql

tables = sql.query("""
    SELECT table_name
    FROM information_schema.tables
    WHERE table_schema = 'public'
    ORDER BY table_name
""")

for t in tables:
    name = t["table_name"]
    cols = sql.query(
        """
        SELECT column_name, data_type, is_nullable
        FROM information_schema.columns
        WHERE table_schema = 'public' AND table_name = $1
        ORDER BY ordinal_position
    """,
        [name],
    )

    count = sql.query("SELECT count(*) AS n FROM " + name)
    n = count[0]["n"]

    print("--- " + name + " (" + str(n) + " rows) ---")
    for c in cols:
        nullable = " (nullable)" if c["is_nullable"] == "YES" else ""
        print("  " + c["column_name"] + ": " + c["data_type"] + nullable)
    print("")
