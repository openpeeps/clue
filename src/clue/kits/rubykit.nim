# Clue - A cool toolkit for Nim developers
#
# (c) 2026 George Lemon | LGPLv3 License
#          Made by Humans from OpenPeeps
#          https://github.com/openpeeps/clue

## This module implements a DSL-like interface for creating Ruby
## native extensions (`.bundle`) in Nim. It relies on the underlying
## C API bindings defined at lower levels.
##
## It defines a `rubyModule` macro that allows you to declare Nim-like
## functions and have them automatically exported as Ruby module functions.
##
## Usage
## =====
##
## ```nim
## import clue/kits/rubykit
##
## rubyModule do:
##   name: "example"
##   version: "0.1.0"
##
##   proc helloWorld(name: string) =
##     echo "Hello, ", name, " from Ruby!"
## ```

import std/[macros, strutils]
import ./ruby/ruby_api

export ruby_api

type
  RubyParamType* = enum
    rptString
    rptLong
    rptDouble
    rptBool
    rptValue

proc getRubyType*(t: NimNode): RubyParamType {.compileTime.} =
  case t.kind
  of nnkStrLit: rptString
  of nnkIntLit: rptLong
  of nnkFloatLit: rptDouble
  of nnkIdent:
    case $t
    of "bool":   rptBool
    of "string": rptString
    of "int":    rptLong
    of "float":  rptDouble
    else:
      if $t == "VALUE": rptValue
      else: error("Unsupported parameter type: " & $t, t)
  else:
    if $t.kind == "nnkInfix":
      rptValue
    else:
      error("Unsupported parameter type node: " & $t.kind, t)

proc genParamConversion(paramName: NimNode, paramVal: NimNode, typ: RubyParamType): NimNode {.compileTime.} =
  case typ
  of rptString:
    quote do:
      let `paramName` = $rb_string_value_ptr(addr(`paramVal`))
  of rptLong:
    quote do:
      let `paramName` = int(NUM2INT(`paramVal`))
  of rptDouble:
    quote do:
      let `paramName` = rb_num2dbl(`paramVal`)
  of rptBool:
    quote do:
      let `paramName` = RTEST(`paramVal`)
  of rptValue:
    quote do:
      let `paramName` = `paramVal`

macro rubyModule*(stmtNodes: untyped) =
  ## Define a Ruby module with the given name and functions.
  ##
  ## The block supports:
  ## - `name: "string"` — sets the Ruby module and extension name
  ## - `version: "string"` — metadata (not used by Ruby directly)
  ## - `proc myFunc(param: type) = ...` — exported as Ruby module functions
  ##
  ## Parameters with Nim types (`string`, `int`, `float`, `bool`) are
  ## automatically converted from Ruby VALUEs. Parameters without
  ## annotations are passed as `VALUE` directly.
  ##
  ## The generated `Init_<name>` entry point is exported with
  ## `{.exportc, dynlib.}` so Ruby can discover it via `require`.

  result = newStmtList()

  var moduleName: NimNode
  var moduleVersion: NimNode
  var exportedProcs = newStmtList()
  var initRegistrations = newStmtList()
  var closureDefs = newStmtList()
  let moduleVar = genSym(nskVar, "mRuby")

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
      if valNode.isNil:
        error("Expected a string literal value", node)
      if nameNode.eqIdent"name":
        moduleName = valNode
      elif nameNode.eqIdent"version":
        moduleVersion = valNode
    of nnkProcDef, nnkFuncDef:
      let fnName = node[0]
      let fnNameStr = fnName.strVal

      var fnParams: seq[tuple[name: NimNode, typ: RubyParamType, valName: NimNode]]
      var hasTypedParams = false

      if node[3].len > 1:
        for i, param in node[3][1..^1]:
          expectKind(param, nnkIdentDefs)
          let origName = param[0]
          let origType = param[1]
          let rubyType = getRubyType(origType)
          let valName = genSym(nskParam, fnNameStr & "_" & $origName & "_val")
          fnParams.add((origName, rubyType, valName))
          if rubyType != rptValue:
            hasTypedParams = true

      var newFormalParams = newNimNode(nnkFormalParams)
      let tVALUE = newTree(nnkDotExpr, ident("ruby_api"), ident("VALUE"))
      newFormalParams.add(tVALUE)

      newFormalParams.add(nnkIdentDefs.newTree(
        ident("self"),
        tVALUE,
        newEmptyNode()
      ))

      for (_, _, valName) in fnParams:
        newFormalParams.add(nnkIdentDefs.newTree(
          valName,
          tVALUE,
          newEmptyNode()
        ))

      node[3] = newFormalParams

      if node[4].kind == nnkEmpty:
        node[4] = nnkPragma.newTree(ident"cdecl")
      else:
        node[4].add(ident"cdecl")

      let oldBody = node[^1]
      var combined = newStmtList()

      combined.add(
        quote do:
          result = Qnil
      )

      if hasTypedParams:
        for (paramName, rubyType, valName) in fnParams:
          let conv = genParamConversion(paramName, valName, rubyType)
          combined.add(conv)

      if oldBody.kind != nnkEmpty:
        if oldBody.kind == nnkStmtList:
          for j in 0 ..< oldBody.len:
            combined.add(oldBody[j])
        else:
          combined.add(oldBody)

      node[^1] = combined
      exportedProcs.add(node)

      let argc = fnParams.len
      let argcLit = newLit(argc)

      let regCall = newCall(
        ident("rb_define_module_function"),
        moduleVar,
        newLit(fnNameStr),
        fnName,
        argcLit
      )
      initRegistrations.add(regCall)

    of nnkCommentStmt:
      discard
    else:
      error("Unsupported statement in rubyModule: " & $node.kind, node)

  if moduleName.isNil:
    error("rubyModule requires a `name: \"...\"` assignment", stmtNodes)

  let initName = ident("Init_" & moduleName.strVal)

  var wrappedRegistrations = newStmtList()
  for reg in initRegistrations:
    wrappedRegistrations.add(reg)

  result.add(exportedProcs)

  result.add quote do:
    proc `initName`* {.exportc, cdecl, dynlib.} =
      var `moduleVar` = rb_define_module(`moduleName`)
      `wrappedRegistrations`

  when defined(clueDebugExtension):
    echo result.repr
