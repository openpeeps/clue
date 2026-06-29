## PluginKit for Lua (LuaJIT)

This showcases the Clue PluginKit interface for Lua, which allows you to create
native Lua extensions (`.so`) in Nim using LuaJIT's C API.

### Prerequisites

- LuaJIT 2.1 or higher
- Nim 2.0 or higher
- Clue installed (`nimble install clue`)

### Simple example

```nim
import clue/kits/luakit

luaModule do:
  name: "mylib"

  proc hello(name: string) =
    lua_pushstring(L, cstring("Hello " & name & " from Nim!"))
    return 1

  proc add(a: int, b: int) =
    lua_pushinteger(L, a + b)
    return 1

  proc is_positive(n: float) =
    lua_pushboolean(L, cint(n > 0.0))
    return 1
```

### Build the extension

```
nim c --app:lib --out:"build/mylib.so" plugin_example.nim
```

Or with the included `.nims`:

```
nim c plugin_example.nims
```

### Test the extension

```lua
local mylib = require "mylib"

print(mylib.hello("Lua"))
print(mylib.greet("World"))
print("21 doubled = " .. mylib.double(21))
print("3 + 7 = " .. mylib.add(3, 7))
print("3.14 positive?", mylib.is_positive(3.14))
```

Run with:

```
LUA_CPATH="./build/?.so;;" luajit test_example.lua
```

### Debugging

Use `-d:clueDebugExtension` when compiling to see the generated Nim code.

```
nim c -d:clueDebugExtension --app:lib --out:"build/mylib.so" plugin_example.nim
```
