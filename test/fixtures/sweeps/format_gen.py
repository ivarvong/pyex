"""Sweep: %-formatting and format() spec mini-language × values.

Excludes '%%' % arg (degenerate: enforcing 'not all arguments
converted' through the ctx loop needs mapping-mode tracking) and '%c'
(its result for non-printable code points exercises repr-escaping, a
separate concern), both deferred.
"""
import json
from pathlib import Path
PERCENT = ["'%d' % ({x})","'%i' % ({x})","'%s' % ({x})","'%r' % ({x})","'%f' % ({x})",
           "'%.2f' % ({x})","'%5.2f' % ({x})","'%05d' % ({x})","'%+d' % ({x})","'%-6s|' % ({x})",
           "'%x' % ({x})","'%o' % ({x})","'%e' % ({x})","'%g' % ({x})",]
FORMAT = ["format({x})","format({x}, '')","format({x}, '5')","format({x}, '<5')","format({x}, '>5')",
          "format({x}, '^5')","format({x}, '05')","format({x}, '+')","format({x}, '.2f')","format({x}, 'b')",
          "format({x}, 'x')","format({x}, 'o')","format({x}, 'e')","format({x}, '%')","format({x}, ',')"]
VALS = ["42","-7","0","3.14159","-2.5","255","True","1000000","'hi'","65"]
def ev(code):
    try: return {"code": code, "result": repr(eval(code))}
    except Exception as e: return {"code": code, "error": type(e).__name__}
cells = [ev(t.replace("{x}", v)) for t in PERCENT+FORMAT for v in VALS]
Path(__file__).with_name("format.json").write_text(
    json.dumps({"python_version": ".".join(map(str,__import__("sys").version_info[:3])), "cells": cells}, indent=2)+"\n")
print(f"format: {len(cells)} cells")
