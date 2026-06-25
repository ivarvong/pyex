"""Sweep: unary operators × operand types. Regenerate via python3."""
import json
from pathlib import Path
OPS = {"neg": "-({x})", "pos": "+({x})", "invert": "~({x})", "abs": "abs({x})", "not": "not ({x})"}
VALS = ["5","-5","0","3.14","-3.14","True","False","2j","0j",
        "'ab'","''","[1,2]","[]","{1,2}","b'ab'","None","(1,2)"]
def ev(code):
    try: return {"code": code, "result": repr(eval(code))}
    except Exception as e: return {"code": code, "error": type(e).__name__}
cells = [ev(t.replace("{x}", v)) for t in OPS.values() for v in VALS]
Path(__file__).with_name("unary.json").write_text(
    json.dumps({"python_version": ".".join(map(str,__import__("sys").version_info[:3])), "cells": cells}, indent=2)+"\n")
print(f"unary: {len(cells)} cells")
