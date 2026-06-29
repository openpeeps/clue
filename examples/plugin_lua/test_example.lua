#!/usr/bin/env luajit
-- Clue Lua PluginKit Example
-- Load and test the compiled Nim extension

local mylib = require "mylib"

print("=== Testing mylib module ===")
print()

print(mylib.hello("Lua"))
print(mylib.greet("World"))
print("21 doubled = " .. mylib.double(21))
print("3 + 7 = " .. mylib.add(3, 7))
print("3.14 positive?", mylib.is_positive(3.14))
print("-1.0 positive?", mylib.is_positive(-1.0))
