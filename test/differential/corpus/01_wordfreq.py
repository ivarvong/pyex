text = "the quick brown fox the lazy dog the fox jumps"
freq = {}
for w in text.split():
    freq[w] = freq.get(w, 0) + 1
for w, n in sorted(freq.items(), key=lambda kv: (-kv[1], kv[0])):
    print(f"{w}: {n}")
