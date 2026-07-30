#!/usr/bin/env python3
"""Check every fixture against the firmware hard limits: max 512 bytes, max 10 physical lines."""
import os
import sys

FIXTURES = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "fixtures")

failed = False
for name in sorted(os.listdir(FIXTURES)):
    if not name.endswith(".txt"):
        continue
    path = os.path.join(FIXTURES, name)
    with open(path, "rb") as f:
        data = f.read()
    lines = data.decode("utf-8").split("\n")
    if lines and lines[-1] == "":  # trailing newline is not an extra physical line
        lines = lines[:-1]
    ok = len(data) <= 512 and len(lines) <= 10
    status = "OK " if ok else "FAIL"
    print(f"{status} {name:22s} {len(data):4d} bytes  {len(lines):2d} lines")
    if not ok:
        failed = True

sys.exit(1 if failed else 0)
