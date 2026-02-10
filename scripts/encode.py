n = 5412072012
binary_str = bin(n)
print("Integer:", n)
print("Binary:", binary_str)

bits = binary_str[2:]
print("Bits:", bits)

byte_length = (len(bits) + 7) // 8
padded = bits.rjust(byte_length * 8, "0")
print("Padded:", padded)

byte_list = []
for i in range(0, len(padded), 8):
    chunk = padded[i : i + 8]
    val = 0
    for b in chunk:
        val = val * 2 + int(b)
    byte_list.append(val)

print("Bytes:", byte_list)

hex_chars = "0123456789ABCDEF"
b16 = ""
for byte in byte_list:
    b16 = b16 + hex_chars[byte // 16] + hex_chars[byte % 16]
print("Base16:", b16)

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
print("Base32:", b32)

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
print("Base64:", b64)
