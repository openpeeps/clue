import ../../src/clue/kits/luakit

luaModule do:
  name: "mylib"

  ## Say hello — string param auto-checked from Lua stack
  proc hello(name: string) =
    toLuaString(L, "Hello " & name & " from Nim!")
    return 1

  ## Add two integers — parameters checked with luaL_checkinteger
  proc add(a: int, b: int) =
    toLuaInt(L, a + b)
    return 1

  ## Check if a number is positive — return boolean
  proc is_positive(n: float) =
    toLuaBool(L, n > 0.0)
    return 1

  ## Double a value — demonstrates single-param return
  proc double(n: int) =
    toLuaInt(L, n * 2)
    return 1

  ## Echo back a formatted greeting
  proc greet(name: string) =
    discard lua_pushfstring(L, "Greetings, %s!", cstring(name))
    return 1
