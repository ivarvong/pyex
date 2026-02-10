"""
Agentic tool use: Pyex calls Claude, Claude calls tools, tools call APIs.

The tool fetches live METAR weather data from airport stations.
Claude picks the right ICAO codes, calls the tool, and summarizes.
"""

import os
import requests
import json


def get_weather(station):
    """Fetch live METAR data for an ICAO station (e.g. KJFK, EGLL)."""
    resp = requests.get(f"https://echo.2fsk.com/v1/metars/{station}")
    if not resp.ok:
        return {"error": f"METAR fetch failed: HTTP {resp.status_code}"}
    return resp.json()


TOOLS = [
    {
        "name": "get_weather",
        "description": "Get live airport weather (METAR). Returns temp, wind, visibility, clouds, and raw METAR text.",
        "input_schema": {
            "type": "object",
            "properties": {
                "station": {
                    "type": "string",
                    "description": "ICAO airport code, e.g. KJFK, KORD, KLAX, EGLL",
                },
            },
            "required": ["station"],
        },
    },
]

HANDLERS = {"get_weather": get_weather}


def call_claude(messages):
    """Single call to the Anthropic Messages API."""
    resp = requests.post(
        "https://api.anthropic.com/v1/messages",
        headers={
            "x-api-key": os.environ["ANTHROPIC_API_KEY"],
            "anthropic-version": "2023-06-01",
            "content-type": "application/json",
        },
        json={
            "model": "claude-sonnet-4-20250514",
            "max_tokens": 1024,
            "tools": TOOLS,
            "messages": messages,
        },
    )
    if not resp.ok:
        raise Exception(f"API error: {resp.status_code}")
    return resp.json()


def handle_tool_call(block):
    """Execute one tool_use block, return a tool_result block."""
    name = block["name"]
    args = block["input"]

    if name not in HANDLERS:
        return {
            "type": "tool_result",
            "tool_use_id": block["id"],
            "content": json.dumps({"error": f"unknown tool: {name}"}),
            "is_error": True,
        }

    print(f"  -> {name}({json.dumps(args)})")
    result = HANDLERS[name](**args)

    return {
        "type": "tool_result",
        "tool_use_id": block["id"],
        "content": json.dumps(result),
    }


def agent(prompt, max_turns=10):
    """Tool-use loop: prompt -> [tool calls] -> response."""
    messages = [{"role": "user", "content": prompt}]

    for turn in range(max_turns):
        data = call_claude(messages)

        if data["stop_reason"] == "end_turn":
            return "\n".join(b["text"] for b in data["content"] if b["type"] == "text")

        if data["stop_reason"] != "tool_use":
            raise Exception(f"unexpected: {data['stop_reason']}")

        tool_results = [
            handle_tool_call(b) for b in data["content"] if b["type"] == "tool_use"
        ]

        messages = messages + [
            {"role": "assistant", "content": data["content"]},
            {"role": "user", "content": tool_results},
        ]

    raise Exception(f"exceeded {max_turns} turns")


print(agent("What's the weather in NYC, Chicago, and LA right now? Compare them."))
