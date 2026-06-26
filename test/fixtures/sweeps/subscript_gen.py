"""Sweep: subscript & slice reads × container types."""
import json
from pathlib import Path
ACCESS = ["({c})[0]","({c})[1]","({c})[-1]","({c})[5]","({c})[1:3]","({c})[:2]","({c})[2:]",
          "({c})[:]","({c})[::-1]","({c})[::2]","({c})[1:4:2]","({c})[-2:]","({c})[10:20]"]
CONTAINERS = ["[10,20,30,40]","(10,20,30,40)","'abcd'","b'abcd'","range(10,50,10)","bytearray(b'abcd')"]
def ev(code):
    try: return {"code": code, "result": repr(eval(code))}
    except Exception as e: return {"code": code, "error": type(e).__name__}
cells = [ev(t.replace("{c}", c)) for t in ACCESS for c in CONTAINERS]
cells += [ev(c) for c in ["{'a':1,'b':2}['a']","{'a':1}['z']","{1:2}[1]","{1:2}[9]"]]
Path(__file__).with_name("subscript.json").write_text(
    json.dumps({"python_version": ".".join(map(str,__import__("sys").version_info[:3])), "cells": cells}, indent=2)+"\n")
print(f"subscript: {len(cells)} cells")
