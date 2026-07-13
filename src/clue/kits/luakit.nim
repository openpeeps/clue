# Clue - A cool toolkit for Nim developers
#
# (c) 2026 George Lemon | MIT License
#          Made by Humans from OpenPeeps
#          https://github.com/openpeeps/clue

## This module implements a DSL-like interface for creating Lua
## native extensions in Nim. It relies on the underlying C API bindings
## defined at lower levels.
##
## It defines a `luaModule` macro that transforms Nim procs into Lua C
## functions with automatic parameter parsing from the Lua stack.
##
## Usage
## =====
##
## ```nim
## import clue/kits/luakit
##
## luaModule do:
##   name: "mylib"
##
##   proc hello(name: string) =
##     lua_pushstring(L, cstring("Hello " & name & " from Nim!"))
##     return 1
## ```

import std/[macros, strutils]
import ./lua/lua_api

export lua_api

type
  LuaParamType* = enum
    lptString
    lptLong
    lptDouble
    lptBool
    lptValue

proc getLuaType*(t: NimNode): LuaParamType {.compileTime.} =
  case t.kind
  of nnkStrLit: lptString
  of nnkIntLit: lptLong
  of nnkFloatLit: lptDouble
  of nnkIdent:
    case $t
    of "bool":   lptBool
    of "string": lptString
    of "int":    lptLong
    of "float":  lptDouble
    else: lptValue
  else: lptValue

proc genLuaParamConv(pos: cint, paramName: NimNode, typ: LuaParamType): NimNode {.compileTime.} =
  let posLit = newLit(pos)
  case typ
  of lptString:
    quote do:
      let `paramName` = $luaL_checkstring(L, `posLit`)
  of lptLong:
    quote do:
      let `paramName` = int(luaL_checkinteger(L, `posLit`))
  of lptDouble:
    quote do:
      let `paramName` = luaL_checknumber(L, `posLit`)
  of lptBool:
    quote do:
      let `paramName` = lua_toboolean(L, `posLit`) != 0
  of lptValue:
    return nil

macro luaModule*(stmtNodes: untyped) =
  ## Define a Lua module with the given name and functions.
  ##
  ## The block supports:
  ## - `name: "string"` — sets the Lua module name and `luaopen_<name>` entry point
  ## - `proc myFunc(param: type) = ...` — exported as Lua module functions
  ##
  ## Parameters are accessed from the Lua stack by position (1-indexed).
  ## Supported parameter types (`string`, `int`, `float`, `bool`) are
  ## automatically checked and converted from the stack.
  ##
  ## The user is responsible for pushing return values onto the Lua stack
  ## and returning the number of values pushed.
  ##
  ## The generated `luaopen_<name>` entry point is exported with
  ## `{.exportc, dynlib.}` so Lua can discover it via `require`.

  result = newStmtList()

  var moduleName: NimNode
  var exportedProcs = newStmtList()
  var regEntries = newStmtList()
  var regCount = 0

  for node in stmtNodes:
    case node.kind
    of nnkCall, nnkAsgn, nnkExprColonExpr:
      let nameNode = node[0]
      var valNode: NimNode = nil
      if node.len >= 2:
        if node[1].kind == nnkStrLit:
          valNode = node[1]
        elif node[1].kind == nnkStmtList and node[1].len > 0 and node[1][0].kind == nnkStrLit:
          valNode = node[1][0]
      if not valNode.isNil and nameNode.eqIdent"name":
        moduleName = valNode
    of nnkCommentStmt:
      discard
    of nnkProcDef, nnkFuncDef:
      let fnName = node[0]
      let fnNameStr = fnName.strVal

      var fnParams: seq[tuple[name: NimNode, typ: LuaParamType, pos: cint]]

      if node[3].len > 1:
        for i, param in node[3][1..^1]:
          expectKind(param, nnkIdentDefs)
          let origName = param[0]
          let origType = param[1]
          let luaType = getLuaType(origType)
          fnParams.add((origName, luaType, cint(i + 1)))

      var newFormalParams = newNimNode(nnkFormalParams)
      newFormalParams.add(ident("cint"))

      newFormalParams.add(nnkIdentDefs.newTree(
        ident("L"),
        nnkPtrTy.newTree(ident("lua_State")),
        newEmptyNode()
      ))

      node[3] = newFormalParams

      if node[4].kind == nnkEmpty:
        node[4] = nnkPragma.newTree(ident"cdecl")
      else:
        node[4].add(ident"cdecl")

      let oldBody = node[^1]
      var combined = newStmtList()

      combined.add quote do:
        result = 0

      for (paramName, luaType, pos) in fnParams:
        let conv = genLuaParamConv(pos, paramName, luaType)
        if not conv.isNil:
          combined.add(conv)

      if oldBody.kind != nnkEmpty:
        if oldBody.kind == nnkStmtList:
          for j in 0 ..< oldBody.len:
            combined.add(oldBody[j])
        else:
          combined.add(oldBody)

      node[^1] = combined
      exportedProcs.add(node)

      let nameLit = newLit(fnNameStr)
      let idxLit = newLit(regCount)
      regEntries.add(
        newAssignment(
          newDotExpr(
            nnkBracketExpr.newTree(ident("regTable"), idxLit),
            ident("name")
          ),
          nameLit
        ),
        newAssignment(
          newDotExpr(
            nnkBracketExpr.newTree(ident("regTable"), idxLit),
            ident("func")
          ),
          fnName
        )
      )
      regCount.inc

    else:
      error("Unsupported statement in luaModule: " & $node.kind, node)

  if moduleName.isNil:
    error("luaModule requires a `name: \"...\"` assignment", stmtNodes)

  let openName = ident("luaopen_" & moduleName.strVal)
  let regCountLit = newLit(regCount + 1)

  result.add(exportedProcs)

  let bodyStmts = newStmtList()

  bodyStmts.add newNimNode(nnkVarSection).add(
    nnkIdentDefs.newTree(
      ident("regTable"),
      nnkBracketExpr.newTree(ident("array"), regCountLit, ident("luaL_Reg")),
      newEmptyNode()
    )
  )

  bodyStmts.add(regEntries)

  bodyStmts.add newCall(
    ident("luaL_register"),
    ident("L"),
    moduleName,
    nnkAddr.newTree(
      nnkBracketExpr.newTree(ident("regTable"), newLit(0))
    )
  )

  bodyStmts.add newNimNode(nnkReturnStmt).add(newLit(1))

  var openProc = newProc(openName, [
    ident("cint"),
    nnkIdentDefs.newTree(
      ident("L"),
      nnkPtrTy.newTree(ident("lua_State")),
      newEmptyNode()
    )
  ], bodyStmts, nnkProcDef)

  openProc[4] = nnkPragma.newTree(ident"exportc", ident"cdecl", ident"dynlib")
  result.add(openProc)

  when defined(clueDebugExtension):
    echo result.repr
