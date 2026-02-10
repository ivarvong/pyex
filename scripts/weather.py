import os
import requests
import json


def ask_claude(prompt, model="claude-sonnet-4-20250514", max_tokens=4096, tools=None):
    api_key = os.environ["ANTHROPIC_API_KEY"]

    headers = {
        "x-api-key": api_key,
        "anthropic-version": "2023-06-01",
        "content-type": "application/json",
    }

    body = {
        "model": model,
        "max_tokens": max_tokens,
        "messages": [
            {"role": "user", "content": prompt},
        ],
    }

    if tools is not None:
        body["tools"] = tools

    response = requests.post(
        "https://api.anthropic.com/v1/messages",
        headers=headers,
        json=body,
    )

    data = response.json()

    if not response.ok:
        return "Error: " + str(data)

    result = ""
    for block in data["content"]:
        if block["type"] == "text":
            result = result + block["text"]

    return result


answer = ask_claude(
    "What's the weather like in NYC right now? Be brief, 2-3 sentences.",
    tools=[{"type": "web_search_20250305", "name": "web_search", "max_uses": 3}],
)
print(answer)
