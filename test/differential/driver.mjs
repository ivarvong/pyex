// Wasm executor for the differential harness. Loads the pyex.wasm interpreter ONCE and runs a batch
// of programs through `pyrun`, emitting `[{id, ok, stdout|error}]` as JSON on stdout.
//   node driver.mjs <programs.json> <pyex.wasm>
// A wasm trap leaves the instance in an undefined state, so we re-instantiate after any trap — each
// program still sees a clean interpreter.
import fs from "node:fs";

const [, , progsPath, wasmPath] = process.argv;
const { makeBig, makeMath, makeStr, makeFs, makeIo, makeCrypto, makeProcStubs, makeSys, memFsBacking, termToJs } =
  await import(new URL("../../../elixir_wasm/runtime/imports.mjs", import.meta.url));

const cs = { createHash: () => { throw new Error("no hash in harness"); } };
const mod = await WebAssembly.compile(fs.readFileSync(wasmPath));

async function newInstance() {
  let e;
  const { proc, sched } = makeProcStubs();
  e = (await WebAssembly.instantiate(mod, {
    big: makeBig(), math: makeMath(), str: makeStr(() => e),
    crypto: makeCrypto(() => e, cs), sys: makeSys(),
    fs: makeFs(() => e, memFsBacking()), io: makeIo(() => e, []), proc, sched,
  })).exports;
  return e;
}

let e = await newInstance();
const enc = new TextEncoder();
const bin = (s) => { const u = enc.encode(s), x = e.bin_alloc(u.length); for (let i = 0; i < u.length; i++) e.bin_put(x, i, u[i]); return x; };

const progs = JSON.parse(fs.readFileSync(progsPath, "utf8"));
const out = [];
for (const { id, code } of progs) {
  try {
    const t = termToJs(e, e.pyrun(bin(code), bin("{}"), 0));
    if (Array.isArray(t) && t[0] === ":ok") out.push({ id, ok: true, stdout: t[1] || "" });
    else out.push({ id, ok: false, error: Array.isArray(t) ? String(t[1]) : String(t) });
  } catch (ex) {
    out.push({ id, ok: false, error: "trap: " + String(ex).split("\n")[0] });
    e = await newInstance();   // the trap corrupted this instance — rebuild for the next program
  }
}
process.stdout.write(JSON.stringify(out));
