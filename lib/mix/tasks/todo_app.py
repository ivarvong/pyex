import sql
import os

cmd = os.environ.get("TODO_CMD", "list")
arg = os.environ.get("TODO_ARG", "")

if cmd == "init":
    sql.query("""
        CREATE TABLE IF NOT EXISTS pyex_todos (
            id serial PRIMARY KEY,
            task text NOT NULL,
            done boolean DEFAULT false,
            created_at timestamp DEFAULT now()
        )
    """)
    print("Table pyex_todos created.")

elif cmd == "add":
    if arg == "":
        print("Usage: mix todo add <task>")
    else:
        sql.query("INSERT INTO pyex_todos (task) VALUES ($1)", [arg])
        print("Added: " + arg)

elif cmd == "done":
    rows = sql.query(
        "UPDATE pyex_todos SET done = true WHERE id = $1 RETURNING task", [int(arg)]
    )
    if len(rows) > 0:
        print("Done: " + rows[0]["task"])
    else:
        print("No todo with id " + arg)

elif cmd == "delete":
    rows = sql.query("DELETE FROM pyex_todos WHERE id = $1 RETURNING task", [int(arg)])
    if len(rows) > 0:
        print("Deleted: " + rows[0]["task"])
    else:
        print("No todo with id " + arg)

elif cmd == "list":
    rows = sql.query("SELECT id, task, done FROM pyex_todos ORDER BY id")
    if len(rows) == 0:
        print("No todos yet. Add one with: mix todo add <task>")
    else:
        for row in rows:
            check = "x" if row["done"] else " "
            print("[" + check + "] " + str(row["id"]) + ". " + row["task"])

else:
    print("Usage:")
    print("  mix todo init")
    print("  mix todo add <task>")
    print("  mix todo list")
    print("  mix todo done <id>")
    print("  mix todo delete <id>")
