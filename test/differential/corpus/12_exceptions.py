class MyErr(Exception):
    pass
def risky(x):
    if x < 0:
        raise MyErr(f"negative: {x}")
    return x * 2
for v in [1, -2, 3]:
    try:
        print(risky(v))
    except MyErr as e:
        print("error:", e)
