import json
data = {"name":"pyex","tags":["wasm","elixir"],"meta":{"n":3,"ok":True}}
s = json.dumps(data, sort_keys=True)
print(s)
print(json.loads(s)["meta"]["n"])
