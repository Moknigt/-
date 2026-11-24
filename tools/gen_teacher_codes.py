#!/usr/bin/env python3
"""Makes teacher registration codes (KEEP THIS FILE PRIVATE: whoever has it can make codes).

    python3 tools/gen_teacher_codes.py          # 10 new codes
    python3 tools/gen_teacher_codes.py 25      # 25 new codes
    python3 tools/gen_teacher_codes.py --check ABCDEF-GHJKLM

A code is 6 random letters/digits + 6 signature characters (HMAC-SHA256 of the first 6 with SECRET), shown as XXXXXX-YYYYYY.
The apps check the signature offline, so no server is needed. SECRET must be the same string as in
android TeacherCode.kt, ios TeacherCode.swift and windows TeacherCode.cs. To invalidate every code made so far, change it in all four places.
Each code works once per device (the app remembers the used ones); there is no server, so the same code can still be used once on another device.
"""
import hmac, hashlib, secrets, sys

SECRET = "rw54cHkLy7Gk_H53ezFrTLXwEuivdc7f"
ALPHA = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"   # no 0 O 1 I

def check(serial):
    b = hmac.new(SECRET.encode(), ("teacher:" + serial).encode(), hashlib.sha256).digest()
    n = int.from_bytes(b[:5], "big")
    return "".join(ALPHA[(n >> (35 - 5 * i)) & 31] for i in range(6))

def make():
    s = "".join(secrets.choice(ALPHA) for _ in range(6))
    return f"{s}-{check(s)}"

def valid(code):
    c = "".join(ch for ch in code.upper() if ch in ALPHA)
    return len(c) == 12 and check(c[:6]) == c[6:]

if __name__ == "__main__":
    if len(sys.argv) > 2 and sys.argv[1] == "--check":
        print("valid" if valid(sys.argv[2]) else "NOT valid")
    else:
        for _ in range(int(sys.argv[1]) if len(sys.argv) > 1 else 10):
            print(make())
