source = ~S"""
n = 5412072012
binary_str = bin(n)
bits = binary_str[2:]
byte_length = (len(bits) + 7) // 8
padded = bits.rjust(byte_length * 8, "0")
byte_list = []
for i in range(0, len(padded), 8):
    chunk = padded[i : i + 8]
    val = 0
    for b in chunk:
        val = val * 2 + int(b)
    byte_list.append(val)
hex_chars = "0123456789ABCDEF"
b16 = ""
for byte in byte_list:
    b16 = b16 + hex_chars[byte // 16] + hex_chars[byte % 16]
b32_alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567"
all_bits = padded
while len(all_bits) % 5 != 0:
    all_bits = all_bits + "0"
b32 = ""
for i in range(0, len(all_bits), 5):
    chunk = all_bits[i : i + 5]
    val = 0
    for b in chunk:
        val = val * 2 + int(b)
    b32 = b32 + b32_alphabet[val]
while len(b32) % 8 != 0:
    b32 = b32 + "="
b64_alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
all_bits2 = padded
while len(all_bits2) % 6 != 0:
    all_bits2 = all_bits2 + "0"
b64 = ""
for i in range(0, len(all_bits2), 6):
    chunk = all_bits2[i : i + 6]
    val = 0
    for b in chunk:
        val = val * 2 + int(b)
    b64 = b64 + b64_alphabet[val]
while len(b64) % 4 != 0:
    b64 = b64 + "="
[b16, b32, b64]
"""

{:ok, ast} = Pyex.compile(source)

n = 500

run_us = elem(:timer.tc(fn -> for _ <- 1..n, do: Pyex.run!(source) end), 0) |> div(n)
eval_us = elem(:timer.tc(fn -> for _ <- 1..n, do: Pyex.run!(ast) end), 0) |> div(n)
compile_us = elem(:timer.tc(fn -> for _ <- 1..n, do: Pyex.compile(source) end), 0) |> div(n)

IO.puts("encode (avg of #{n} runs):")
IO.puts("  Pyex.run!(source):  #{run_us}μs")
IO.puts("  Pyex.compile(src):  #{compile_us}μs")
IO.puts("  Pyex.run!(ast):     #{eval_us}μs")
IO.puts("  compile+eval:       #{compile_us + eval_us}μs")

IO.puts(
  "  savings:            #{run_us - eval_us}μs (#{round((run_us - eval_us) / run_us * 100)}%)"
)
