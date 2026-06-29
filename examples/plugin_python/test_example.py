#!/usr/bin/env python3
# Clue Python PluginKit Example
# Load and test the compiled Nim extension

import sys
sys.path.insert(0, "build")
import mylib

print("=== Testing mylib module ===")
print()

print(mylib.hello("Python"))
print(mylib.greet("World"))
print(f"21 doubled = {mylib.twice(21)}")
print(f"3 + 7 = {mylib.add(3, 7)}")
print(f"3.14 positive? {mylib.is_positive(3.14)}")
print(f"-1.0 positive? {mylib.is_positive(-1.0)}")
