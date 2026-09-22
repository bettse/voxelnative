#!/opt/homebrew/bin/python3.13
"""
Generate an SRP-6a test vector with fixed secrets, following csrp (Luanti's
util/srp.cpp) byte for byte: SHA-256, RFC 5054 2048-bit group, csrp padding.
Both the client proof M and a server-side B are produced so the GDScript
SRP class can be checked offline. Output: client/tests/srp_vector.json
"""
import hashlib, json, os

N = int(
    "AC6BDB41324A9A9BF166DE5E1389582FAF72B6651987EE07FC3192943DB56050A37329CBB4A099ED8193E0757767A13DD52312AB4B03310DCD7F48A9DA04FD50E8083969EDB767B0CF6095179A163AB3661A05FBD5FAAAE82918A9962F0B93B855F97993EC975EEAA80D740ADBF4FF747359D041D5C33EA71D281E446B14773BCA97B43A23FB801676BD207A436C6481F1D2B9078717461A5B9D32E688F87748544523B524B0D57D5EA77A2775D2ECFA032CFBDBF52FB3786160279004E57AE6AF874E7303CE53299CCC041C7BC308D82A5698F3A8D0C38271AE35F8E9DBFBB694B5C803D89F7AE435DE236D525F54759B65E372FCD68EF20FA7111F9E4AFF73", 16)
g = 2
NLEN = (N.bit_length() + 7) // 8
H = lambda *parts: hashlib.sha256(b"".join(parts)).digest()
tobin = lambda x: x.to_bytes((x.bit_length() + 7) // 8, "big") if x else b""
pad = lambda x: x.to_bytes(NLEN, "big")

def calc_x(salt, user_v, pw):
    return int.from_bytes(H(salt, H(user_v.encode() + b":" + pw)), "big")

def H_nn(n1, n2):
    return int.from_bytes(H(pad(n1), pad(n2)), "big")

def calc_M(I, s, A, B, K):
    hxor = bytes(a ^ b for a, b in zip(H(tobin(N)), H(tobin(g))))
    return H(hxor, H(I.encode()), s, tobin(A), tobin(B), K)

username = "VrDev"           # mixed case: I keeps it, x uses lowercase
password = b"secret pw"
salt = bytes(range(16))
a = int.from_bytes(bytes([0x11] * 32), "big")
b = int.from_bytes(bytes([0x22] * 32), "big")

x = calc_x(salt, username.lower(), password)
v = pow(g, x, N)
A = pow(g, a, N)
k = H_nn(N, g)
B = (k * v + pow(g, b, N)) % N
u = H_nn(A, B)
S_client = pow((B - k * pow(g, x, N)) % N, a + u * x, N)
S_server = pow(A * pow(v, u, N), b, N)
assert S_client == S_server
K = H(tobin(S_client))
M = calc_M(username, salt, A, B, K)

out = {
    "username": username, "password": password.decode(),
    "salt": salt.hex(), "a": tobin(a).hex(),
    "A": tobin(A).hex(), "B": tobin(B).hex(), "verifier": tobin(v).hex(),
    "K": K.hex(), "M": M.hex(),
}
path = os.path.join(os.path.dirname(__file__), "..", "client", "tests", "srp_vector.json")
json.dump(out, open(path, "w"), indent=1)
print("wrote", os.path.normpath(path))
