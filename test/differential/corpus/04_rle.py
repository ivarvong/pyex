s = "aaabbbcccd"
out, i = [], 0
while i < len(s):
    j = i
    while j < len(s) and s[j] == s[i]:
        j += 1
    out.append(f"{s[i]}{j-i}")
    i = j
print("".join(out))
