# Clue - A cool toolkit for Nim developers
#
# (c) 2026 George Lemon | MIT License
#          Made by Humans from OpenPeeps
#          https://github.com/openpeeps/clue

## Low-level Nim bindings to the Lua C API (`lua.h`, `lauxlib.h`).
##
## This module provides direct C-style bindings for creating Lua native
## extensions in Nim. Real C functions are imported via `{.importc, header}`
## pragmas. C macros are provided as Nim templates with identical names.

when defined(macosx):
  {.passC: "-I/opt/local/include/luajit-2.1".}
  {.passL: "-L/opt/local/lib -lluajit-5.1 -Wl,-undefined,dynamic_lookup".}

type
  lua_State* {.importc: "lua_State", header: "lua.h", incompleteStruct.} = object
  lua_CFunction* = proc(L: ptr lua_State): cint {.cdecl.}

type
  lua_Number* = cdouble
  lua_Integer* = clonglong

type
  luaL_Reg* {.importc: "luaL_Reg", header: "lauxlib.h", bycopy.} = object
    name*: cstring
    `func`*: lua_CFunction

const
  LUA_GLOBALSINDEX* = -10002
  LUA_REGISTRYINDEX* = -10000
  LUA_ENVIRONINDEX* = -10001
  LUA_MULTRET* = -1

const
  LUA_OK* = 0
  LUA_YIELD* = 1
  LUA_ERRRUN* = 2
  LUA_ERRSYNTAX* = 3
  LUA_ERRMEM* = 4
  LUA_ERRERR* = 5
  LUA_ERRFILE* = 6

const
  LUA_TNONE* = -1
  LUA_TNIL* = 0
  LUA_TBOOLEAN* = 1
  LUA_TLIGHTUSERDATA* = 2
  LUA_TNUMBER* = 3
  LUA_TSTRING* = 4
  LUA_TTABLE* = 5
  LUA_TFUNCTION* = 6
  LUA_TUSERDATA* = 7
  LUA_TTHREAD* = 8

const
  LUA_MINSTACK* = 20

const
  LUA_GCSTOP* = 0
  LUA_GCRESTART* = 1
  LUA_GCCOLLECT* = 2
  LUA_GCCOUNT* = 3
  LUA_GCSTEP* = 5
  LUA_GCSETPAUSE* = 6
  LUA_GCSETSTEPMUL* = 7

template lua_pop*(L: ptr lua_State, n: cint): void =
  lua_settop(L, -(n) - 1)

template lua_newtable*(L: ptr lua_State): void =
  lua_createtable(L, 0, 0)

template lua_tostring*(L: ptr lua_State, i: cint): cstring =
  lua_tolstring(L, i, nil)

template lua_strlen*(L: ptr lua_State, i: cint): csize_t =
  lua_objlen(L, i)

template lua_setglobal*(L: ptr lua_State, s: cstring): void =
  lua_setfield(L, LUA_GLOBALSINDEX, s)

template lua_getglobal*(L: ptr lua_State, s: cstring): void =
  lua_getfield(L, LUA_GLOBALSINDEX, s)

template lua_pushcfunction*(L: ptr lua_State, f: lua_CFunction): void =
  lua_pushcclosure(L, f, 0)

template lua_register*(L: ptr lua_State, n: cstring, f: lua_CFunction): void =
  lua_pushcfunction(L, f)
  lua_setglobal(L, n)

template luaL_checkstring*(L: ptr lua_State, n: cint): cstring =
  luaL_checklstring(L, n, nil)

template luaL_checkint*(L: ptr lua_State, n: cint): cint =
  cint(luaL_checkinteger(L, n))

template luaL_checklong*(L: ptr lua_State, n: cint): clong =
  clong(luaL_checkinteger(L, n))

template luaL_dostring*(L: ptr lua_State, s: cstring): cint =
  luaL_loadstring(L, s) or lua_pcall(L, 0, LUA_MULTRET, 0)

template luaL_dofile*(L: ptr lua_State, fn: cstring): cint =
  luaL_loadfile(L, fn) or lua_pcall(L, 0, LUA_MULTRET, 0)

template luaL_typename*(L: ptr lua_State, i: cint): cstring =
  lua_typename(L, lua_type(L, i))

{.push importc.}

# lua.h — state manipulation
proc lua_newstate*(f: pointer, ud: pointer): ptr lua_State {.importc, header: "lua.h".}
proc lua_close*(L: ptr lua_State) {.importc, header: "lua.h".}
proc lua_newthread*(L: ptr lua_State): ptr lua_State {.importc, header: "lua.h".}
proc lua_atpanic*(L: ptr lua_State, panicf: lua_CFunction): lua_CFunction {.importc, header: "lua.h".}

# lua.h — basic stack manipulation
proc lua_gettop*(L: ptr lua_State): cint {.importc, header: "lua.h".}
proc lua_settop*(L: ptr lua_State, idx: cint) {.importc, header: "lua.h".}
proc lua_pushvalue*(L: ptr lua_State, idx: cint) {.importc, header: "lua.h".}
proc lua_remove*(L: ptr lua_State, idx: cint) {.importc, header: "lua.h".}
proc lua_insert*(L: ptr lua_State, idx: cint) {.importc, header: "lua.h".}
proc lua_replace*(L: ptr lua_State, idx: cint) {.importc, header: "lua.h".}
proc lua_checkstack*(L: ptr lua_State, sz: cint): cint {.importc, header: "lua.h".}
proc lua_xmove*(`from`: ptr lua_State, `to`: ptr lua_State, n: cint) {.importc, header: "lua.h".}

# lua.h — access functions (stack -> C)
proc lua_isnumber*(L: ptr lua_State, idx: cint): cint {.importc, header: "lua.h".}
proc lua_isstring*(L: ptr lua_State, idx: cint): cint {.importc, header: "lua.h".}
proc lua_iscfunction*(L: ptr lua_State, idx: cint): cint {.importc, header: "lua.h".}
proc lua_isuserdata*(L: ptr lua_State, idx: cint): cint {.importc, header: "lua.h".}
proc lua_type*(L: ptr lua_State, idx: cint): cint {.importc, header: "lua.h".}
proc lua_typename*(L: ptr lua_State, tp: cint): cstring {.importc, header: "lua.h".}
proc lua_equal*(L: ptr lua_State, idx1: cint, idx2: cint): cint {.importc, header: "lua.h".}
proc lua_rawequal*(L: ptr lua_State, idx1: cint, idx2: cint): cint {.importc, header: "lua.h".}
proc lua_lessthan*(L: ptr lua_State, idx1: cint, idx2: cint): cint {.importc, header: "lua.h".}

proc lua_tonumber*(L: ptr lua_State, idx: cint): lua_Number {.importc, header: "lua.h".}
proc lua_tointeger*(L: ptr lua_State, idx: cint): lua_Integer {.importc, header: "lua.h".}
proc lua_toboolean*(L: ptr lua_State, idx: cint): cint {.importc, header: "lua.h".}
proc lua_tolstring*(L: ptr lua_State, idx: cint, len: ptr csize_t): cstring {.importc, header: "lua.h".}
proc lua_objlen*(L: ptr lua_State, idx: cint): csize_t {.importc, header: "lua.h".}
proc lua_tocfunction*(L: ptr lua_State, idx: cint): lua_CFunction {.importc, header: "lua.h".}
proc lua_touserdata*(L: ptr lua_State, idx: cint): pointer {.importc, header: "lua.h".}
proc lua_tothread*(L: ptr lua_State, idx: cint): ptr lua_State {.importc, header: "lua.h".}

# lua.h — push functions (C -> stack)
proc lua_pushnil*(L: ptr lua_State) {.importc, header: "lua.h".}
proc lua_pushnumber*(L: ptr lua_State, n: lua_Number) {.importc, header: "lua.h".}
proc lua_pushinteger*(L: ptr lua_State, n: lua_Integer) {.importc, header: "lua.h".}
proc lua_pushlstring*(L: ptr lua_State, s: cstring, l: csize_t) {.importc, header: "lua.h".}
proc lua_pushstring*(L: ptr lua_State, s: cstring) {.importc, header: "lua.h".}
proc lua_pushvfstring*(L: ptr lua_State, fmt: cstring, argp: pointer): cstring {.importc, header: "lua.h".}
proc lua_pushfstring*(L: ptr lua_State, fmt: cstring): cstring {.importc, header: "lua.h", varargs.}
proc lua_pushcclosure*(L: ptr lua_State, fn: lua_CFunction, n: cint) {.importc, header: "lua.h".}
proc lua_pushboolean*(L: ptr lua_State, b: cint) {.importc, header: "lua.h".}
proc lua_pushlightuserdata*(L: ptr lua_State, p: pointer) {.importc, header: "lua.h".}
proc lua_pushthread*(L: ptr lua_State): cint {.importc, header: "lua.h".}

# lua.h — get functions (Lua -> stack)
proc lua_gettable*(L: ptr lua_State, idx: cint) {.importc, header: "lua.h".}
proc lua_getfield*(L: ptr lua_State, idx: cint, k: cstring) {.importc, header: "lua.h".}
proc lua_rawget*(L: ptr lua_State, idx: cint) {.importc, header: "lua.h".}
proc lua_rawgeti*(L: ptr lua_State, idx: cint, n: cint) {.importc, header: "lua.h".}
proc lua_createtable*(L: ptr lua_State, narr: cint, nrec: cint) {.importc, header: "lua.h".}
proc lua_newuserdata*(L: ptr lua_State, sz: csize_t): pointer {.importc, header: "lua.h".}
proc lua_getmetatable*(L: ptr lua_State, objindex: cint): cint {.importc, header: "lua.h".}
proc lua_getfenv*(L: ptr lua_State, idx: cint) {.importc, header: "lua.h".}

# lua.h — set functions (stack -> Lua)
proc lua_settable*(L: ptr lua_State, idx: cint) {.importc, header: "lua.h".}
proc lua_setfield*(L: ptr lua_State, idx: cint, k: cstring) {.importc, header: "lua.h".}
proc lua_rawset*(L: ptr lua_State, idx: cint) {.importc, header: "lua.h".}
proc lua_rawseti*(L: ptr lua_State, idx: cint, n: cint) {.importc, header: "lua.h".}
proc lua_setmetatable*(L: ptr lua_State, objindex: cint): cint {.importc, header: "lua.h".}
proc lua_setfenv*(L: ptr lua_State, idx: cint): cint {.importc, header: "lua.h".}

# lua.h — load and call
proc lua_call*(L: ptr lua_State, nargs: cint, nresults: cint) {.importc, header: "lua.h".}
proc lua_pcall*(L: ptr lua_State, nargs: cint, nresults: cint, errfunc: cint): cint {.importc, header: "lua.h".}
proc lua_cpcall*(L: ptr lua_State, `func`: lua_CFunction, ud: pointer): cint {.importc, header: "lua.h".}
proc lua_load*(L: ptr lua_State, reader: pointer, dt: pointer, chunkname: cstring): cint {.importc, header: "lua.h".}
proc lua_dump*(L: ptr lua_State, writer: pointer, data: pointer): cint {.importc, header: "lua.h".}

# lua.h — coroutine
proc lua_yield*(L: ptr lua_State, nresults: cint): cint {.importc, header: "lua.h".}
proc lua_resume*(L: ptr lua_State, narg: cint): cint {.importc, header: "lua.h".}
proc lua_status*(L: ptr lua_State): cint {.importc, header: "lua.h".}

# lua.h — GC
proc lua_gc*(L: ptr lua_State, what: cint, data: cint): cint {.importc, header: "lua.h".}

# lua.h — misc
proc lua_error*(L: ptr lua_State): cint {.importc, header: "lua.h".}
proc lua_next*(L: ptr lua_State, idx: cint): cint {.importc, header: "lua.h".}
proc lua_concat*(L: ptr lua_State, n: cint) {.importc, header: "lua.h".}
proc lua_getallocf*(L: ptr lua_State, ud: ptr pointer): pointer {.importc, header: "lua.h".}
proc lua_setallocf*(L: ptr lua_State, f: pointer, ud: pointer) {.importc, header: "lua.h".}

# lua.h — extra (Lua 5.2+ features in LuaJIT)
proc lua_copy*(L: ptr lua_State, fromidx: cint, toidx: cint) {.importc, header: "lua.h".}
proc lua_tonumberx*(L: ptr lua_State, idx: cint, isnum: ptr cint): lua_Number {.importc, header: "lua.h".}
proc lua_tointegerx*(L: ptr lua_State, idx: cint, isnum: ptr cint): lua_Integer {.importc, header: "lua.h".}
proc lua_isyieldable*(L: ptr lua_State): cint {.importc, header: "lua.h".}

# lauxlib.h — auxiliary library
proc luaL_openlib*(L: ptr lua_State, libname: cstring, l: ptr luaL_Reg, nup: cint) {.importc, header: "lauxlib.h".}
proc luaL_register*(L: ptr lua_State, libname: cstring, l: ptr luaL_Reg) {.importc, header: "lauxlib.h".}
proc luaL_newstate*(): ptr lua_State {.importc, header: "lauxlib.h".}
proc luaL_setfuncs*(L: ptr lua_State, l: ptr luaL_Reg, nup: cint) {.importc, header: "lauxlib.h".}
proc luaL_pushmodule*(L: ptr lua_State, modname: cstring, sizehint: cint) {.importc, header: "lauxlib.h".}

proc luaL_checklstring*(L: ptr lua_State, numArg: cint, l: ptr csize_t): cstring {.importc, header: "lauxlib.h".}
proc luaL_optlstring*(L: ptr lua_State, numArg: cint, def: cstring, l: ptr csize_t): cstring {.importc, header: "lauxlib.h".}
proc luaL_checknumber*(L: ptr lua_State, numArg: cint): lua_Number {.importc, header: "lauxlib.h".}
proc luaL_optnumber*(L: ptr lua_State, nArg: cint, def: lua_Number): lua_Number {.importc, header: "lauxlib.h".}
proc luaL_checkinteger*(L: ptr lua_State, numArg: cint): lua_Integer {.importc, header: "lauxlib.h".}
proc luaL_optinteger*(L: ptr lua_State, nArg: cint, def: lua_Integer): lua_Integer {.importc, header: "lauxlib.h".}
proc luaL_checkstack*(L: ptr lua_State, sz: cint, msg: cstring) {.importc, header: "lauxlib.h".}
proc luaL_checktype*(L: ptr lua_State, narg: cint, t: cint) {.importc, header: "lauxlib.h".}
proc luaL_checkany*(L: ptr lua_State, narg: cint) {.importc, header: "lauxlib.h".}

proc luaL_newmetatable*(L: ptr lua_State, tname: cstring): cint {.importc, header: "lauxlib.h".}
proc luaL_checkudata*(L: ptr lua_State, ud: cint, tname: cstring): pointer {.importc, header: "lauxlib.h".}
proc luaL_testudata*(L: ptr lua_State, ud: cint, tname: cstring): pointer {.importc, header: "lauxlib.h".}
proc luaL_setmetatable*(L: ptr lua_State, tname: cstring) {.importc, header: "lauxlib.h".}

proc luaL_where*(L: ptr lua_State, lvl: cint) {.importc, header: "lauxlib.h".}
proc luaL_error*(L: ptr lua_State, fmt: cstring): cint {.importc, header: "lauxlib.h", varargs.}

proc luaL_checkoption*(L: ptr lua_State, narg: cint, def: cstring, lst: cstringArray): cint {.importc, header: "lauxlib.h".}

proc luaL_ref*(L: ptr lua_State, t: cint): cint {.importc, header: "lauxlib.h".}
proc luaL_unref*(L: ptr lua_State, t: cint, `ref`: cint) {.importc, header: "lauxlib.h".}

proc luaL_loadfile*(L: ptr lua_State, filename: cstring): cint {.importc, header: "lauxlib.h".}
proc luaL_loadbuffer*(L: ptr lua_State, buff: cstring, sz: csize_t, name: cstring): cint {.importc, header: "lauxlib.h".}
proc luaL_loadstring*(L: ptr lua_State, s: cstring): cint {.importc, header: "lauxlib.h".}

proc luaL_gsub*(L: ptr lua_State, s: cstring, p: cstring, r: cstring): cstring {.importc, header: "lauxlib.h".}
proc luaL_findtable*(L: ptr lua_State, idx: cint, fname: cstring, szhint: cint): cstring {.importc, header: "lauxlib.h".}
proc luaL_fileresult*(L: ptr lua_State, stat: cint, fname: cstring): cint {.importc, header: "lauxlib.h".}
proc luaL_execresult*(L: ptr lua_State, stat: cint): cint {.importc, header: "lauxlib.h".}
proc luaL_traceback*(L: ptr lua_State, L1: ptr lua_State, msg: cstring, level: cint) {.importc, header: "lauxlib.h".}

# lualib.h — standard library open functions
proc luaL_openlibs*(L: ptr lua_State) {.importc, header: "lualib.h".}

{.pop.}

proc toLuaString*(L: ptr lua_State, s: string) =
  lua_pushstring(L, cstring(s))

proc toLuaInt*(L: ptr lua_State, n: int) =
  lua_pushinteger(L, lua_Integer(n))

proc toLuaFloat*(L: ptr lua_State, n: float) =
  lua_pushnumber(L, lua_Number(n))

proc toLuaBool*(L: ptr lua_State, b: bool) =
  lua_pushboolean(L, cint(b))

proc toLuaTable*(L: ptr lua_State) =
  lua_newtable(L)
