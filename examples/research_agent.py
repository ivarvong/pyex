"""
research_agent.py — a small, production-shape research agent.

Exercises Pyex's cooperative async runtime end-to-end: planning,
parallel tool calls via asyncio.gather, retries with cooperative
backoff, async-generator streaming, async list comprehension, and
exception handling across await boundaries.

Tools (plan / search / score / summarize) are injected as the
`agent_tools` module — in production they'd be HTTP, vector, or
LLM calls; in the benchmark they're deterministic Elixir builtins
so the entire output is reproducible across thousands of concurrent
tenant runs.
"""

import asyncio
from agent_tools import plan, search, score, summarize
from task import question


async def _await_value(value):
    """Wrap a sync tool result in an awaitable so the agent's
    coordination code can use `await` uniformly. In production the
    underlying tool would already be async (httpx, asyncpg, etc)."""
    await asyncio.sleep(0)
    return value


async def _with_retry(fn, *args, max_retries=2):
    """Retry an awaitable up to `max_retries` times. The
    `await asyncio.sleep(0)` between attempts is a cooperative
    yield — the trampoline can interleave other coroutines here."""
    last_exc = None
    for _ in range(max_retries + 1):
        try:
            return await fn(*args)
        except Exception as e:
            last_exc = e
            await asyncio.sleep(0)
    raise last_exc


async def _call_plan(q):
    return await _await_value(plan(q))


async def _call_search(query):
    return await _await_value(search(query))


async def _call_score(hit, q):
    return await _await_value(score(hit, q))


async def research(q, *, top_k=3):
    """Decompose → fan out search in parallel → score in parallel →
    rank and summarize."""
    sub_queries = await _with_retry(_call_plan, q)

    # Parallel search across all sub-queries.  gather interleaves
    # them at every `await` inside _call_search so wall-clock
    # collapses to the slowest single search rather than the sum.
    raw_results = await asyncio.gather(
        *[_call_search(sq) for sq in sub_queries],
        return_exceptions=True,
    )

    # Flatten + dedupe; skip sub-queries whose searches failed.
    hits = []
    seen = set()
    for sq, results in zip(sub_queries, raw_results):
        if isinstance(results, Exception):
            continue
        for r in results:
            if r["id"] in seen:
                continue
            seen.add(r["id"])
            hits.append({**r, "from_query": sq})

    # Parallel scoring of every hit
    scored = await asyncio.gather(*[_call_score(h, q) for h in hits])

    ranked = sorted(zip(hits, scored), key=lambda p: -p[1])[:top_k]
    return summarize([h for h, _ in ranked])


async def stream_research(q, *, chunk_size=24):
    """Streaming variant — async generator yielding the answer in
    chunks.  The `await asyncio.sleep(0)` between chunks is a
    cooperative yield (matches FastAPI StreamingResponse shape)."""
    answer = await research(q)
    for i in range(0, len(answer), chunk_size):
        yield answer[i:i + chunk_size]
        await asyncio.sleep(0)


async def main(q):
    """Entry point.  Consumes the streaming generator via an async
    list comprehension into a canonical output dict so the
    benchmark can snapshot-verify across many concurrent tenants."""
    chunks = [chunk async for chunk in stream_research(q)]
    return {
        "question": q,
        "answer": "".join(chunks),
        "n_chunks": len(chunks),
    }


# ── Entry: run via injected `question` from the `task` module ──
result = asyncio.run(main(question))
