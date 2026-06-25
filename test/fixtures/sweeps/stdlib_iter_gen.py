"""Sweep: stdlib iterable consumers × iterable types."""
import json
from pathlib import Path
CONS = {"prod":"__import__('math').prod({it})","mean":"__import__('statistics').mean({it})",
        "median":"__import__('statistics').median({it})","fsum":"__import__('math').fsum({it})",
        "reduce":"__import__('functools').reduce(lambda a,b:a+b,{it})",
        "join":"'-'.join(sorted(str(x) for x in {it}))"}
PROD = ["[3,1,2]","(3,1,2)","{3,1,2}","frozenset([3,1,2])","{3:0,1:0,2:0}","range(1,4)",
        "(x for x in [3,1,2])","{3:0,1:0,2:0}.keys()","bytes([3,1,2])","map(lambda x:x,[3,1,2])"]
def ev(code):
    try: return {"code": code, "result": repr(eval(code))}
    except Exception as e: return {"code": code, "error": type(e).__name__}
cells = [ev(t.replace("{it}", p)) for t in CONS.values() for p in PROD]
Path(__file__).with_name("stdlib_iter.json").write_text(
    json.dumps({"python_version": ".".join(map(str,__import__("sys").version_info[:3])), "cells": cells}, indent=2)+"\n")
print(f"stdlib_iter: {len(cells)} cells")
