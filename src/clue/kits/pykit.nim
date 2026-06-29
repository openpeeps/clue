# Clue - A cool toolkit for Nim developers
#
# (c) 2026 George Lemon | MIT License
#          Made by Humans from OpenPeeps
#          https://github.com/openpeeps/clue

## This module implements a DSL-like interface for creating Python
## native extensions in Nim. It relies on the underlying C API bindings
## defined at lower levels.
##
## It defines a `pythonModule` macro that transforms Nim procs into Python
## C functions with automatic argument parsing via `PyArg_ParseTuple`.

import std/macros
import ./python/python_api

export python_api

type
  PyParamType* = enum
    pptString
    pptLong
    pptDouble
    pptBool

proc getPyType*(t: NimNode): PyParamType {.compileTime.} =
  case t.kind
  of nnkStrLit: pptString
  of nnkIntLit: pptLong
  of nnkFloatLit: pptDouble
  of nnkIdent:
    case $t
    of "bool":   pptBool
    of "string": pptString
    of "int":    pptLong
    of "float":  pptDouble
    else:
      error("Unsupported parameter type: " & $t, t)
  else:
    error("Unsupported parameter type node: " & $t.kind, t)

proc toFormatChar*(t: PyParamType): char =
  case t
  of pptString: 's'
  of pptLong: 'i'
  of pptDouble: 'd'
  of pptBool: 'p'

proc toFormatString*(types: openArray[PyParamType]): string =
  result = newStringOfCap(types.len)
  for t in types:
    result.add(toFormatChar(t))

macro pythonModule*(stmtNodes: untyped) =
  ## Define a Python module with the given name and functions.
  ##
  ## The block supports:
  ## - `name: "string"` — sets the Python module name and `PyInit_<name>` entry point
  ## - `doc: "string"` — module docstring
  ## - `proc myFunc(param: type) = ...` — exported as Python module functions
  ##
  ## Parameters are parsed via `PyArg_ParseTuple` automatically.
  ## Supported types: `string`, `int`, `float`, `bool`.
  ##
  ## The user must return a `ptr PyObject` explicitly:
  ## - `result = PyLong_FromLong(42)`
  ## - `Py_RETURN_NONE`
  ## - `Py_RETURN_TRUE` / `Py_RETURN_FALSE`

  result = newStmtList()

  var moduleName: NimNode
  var moduleDoc: NimNode
  var exportedProcs = newStmtList()
  var methodEntries = newStmtList()
  var methodCount = 0

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
      if not valNode.isNil:
        if nameNode.eqIdent"name":
          moduleName = valNode
        elif nameNode.eqIdent"doc":
          moduleDoc = valNode
    of nnkCommentStmt:
      discard
    of nnkProcDef, nnkFuncDef:
      let fnName = node[0]
      let fnNameStr = fnName.strVal

      var fnParams: seq[tuple[name: NimNode, typ: PyParamType]]
      var paramTypes: seq[PyParamType] = @[]

      if node[3].len > 1:
        for i, param in node[3][1..^1]:
          expectKind(param, nnkIdentDefs)
          let origName = param[0]
          let origType = param[1]
          let pyType = getPyType(origType)
          fnParams.add((origName, pyType))
          paramTypes.add(pyType)

      var newFormalParams = newNimNode(nnkFormalParams)
      newFormalParams.add(nnkPtrTy.newTree(ident("PyObject")))

      newFormalParams.add(nnkIdentDefs.newTree(
        ident("self"),
        nnkPtrTy.newTree(ident("PyObject")),
        newEmptyNode()
      ))

      newFormalParams.add(nnkIdentDefs.newTree(
        ident("args"),
        nnkPtrTy.newTree(ident("PyObject")),
        newEmptyNode()
      ))

      node[3] = newFormalParams

      node[4] = nnkPragma.newTree(ident"exportc", ident"cdecl")

      let oldBody = node[^1]
      var combined = newStmtList()

      if fnParams.len > 0:
        var rawNames: seq[NimNode] = @[]
        for (paramName, pyType) in fnParams:
          let rawName = genSym(nskVar, $(paramName) & "_raw")
          rawNames.add(rawName)
          case pyType
          of pptString:
            combined.add quote do:
              var `rawName`: cstring
          of pptLong:
            combined.add quote do:
              var `rawName`: cint
          of pptDouble:
            combined.add quote do:
              var `rawName`: cdouble
          of pptBool:
            combined.add quote do:
              var `rawName`: cint

        let fmtStrLit = newLit(toFormatString(paramTypes))
        var parseCall = newCall(
          ident("PyArg_ParseTuple"),
          ident("args"),
          fmtStrLit
        )
        for rawName in rawNames:
          parseCall.add(nnkAddr.newTree(rawName))

        combined.add(
          nnkIfStmt.newTree(
            nnkElifBranch.newTree(
              nnkInfix.newTree(ident("=="), parseCall, newLit(0)),
              newStmtList(
                nnkReturnStmt.newTree(newNilLit())
              )
            )
          )
        )

        for i, (paramName, pyType) in fnParams:
          let rawName = rawNames[i]
          case pyType
          of pptString:
            combined.add quote do:
              let `paramName` = $(`rawName`)
          of pptLong:
            combined.add quote do:
              let `paramName` = `rawName`
          of pptDouble:
            combined.add quote do:
              let `paramName` = `rawName`
          of pptBool:
            combined.add quote do:
              let `paramName` = `rawName` != 0

        combined.add(
          nnkIfStmt.newTree(
            nnkElifBranch.newTree(
              nnkInfix.newTree(ident("=="), parseCall, newLit(0)),
              newStmtList(
                nnkReturnStmt.newTree(newNilLit())
              )
            )
          )
        )

      if oldBody.kind != nnkEmpty:
        if oldBody.kind == nnkStmtList:
          for j in 0 ..< oldBody.len:
            combined.add(oldBody[j])
        else:
          combined.add(oldBody)

      node[^1] = combined
      exportedProcs.add(node)

      let idxLit = newLit(methodCount)
      let fnNameLit = newLit(fnNameStr)
      let fnDocLit = newLit("")
      methodEntries.add(
        newAssignment(
          newDotExpr(
            nnkBracketExpr.newTree(ident("pyMethods"), idxLit),
            ident("ml_name")
          ),
          fnNameLit
        ),
        newAssignment(
          newDotExpr(
            nnkBracketExpr.newTree(ident("pyMethods"), idxLit),
            ident("ml_meth")
          ),
          fnName
        ),
        newAssignment(
          newDotExpr(
            nnkBracketExpr.newTree(ident("pyMethods"), idxLit),
            ident("ml_flags")
          ),
          newLit(METH_VARARGS)
        ),
        newAssignment(
          newDotExpr(
            nnkBracketExpr.newTree(ident("pyMethods"), idxLit),
            ident("ml_doc")
          ),
          fnDocLit
        )
      )
      methodCount.inc

    else:
      error("Unsupported statement in pythonModule: " & $node.kind, node)

  if moduleName.isNil:
    error("pythonModule requires a `name: \"...\"` assignment", stmtNodes)

  let initName = ident("PyInit_" & moduleName.strVal)
  let modNameStr = moduleName.strVal

  # Forward declarations for Nim-generated functions
  var globalEmit = ""
  for i, node in exportedProcs:
    let fnNameStr = node[0].strVal
    globalEmit &= "extern PyObject* " & fnNameStr & "(PyObject*, PyObject*);\n"
  globalEmit &= "static PyMethodDef nim_meth[] = {\n"
  for i, node in exportedProcs:
    let fnNameStr = node[0].strVal
    globalEmit &= "    {\"" & fnNameStr & "\", (PyCFunction)" & fnNameStr & ", METH_VARARGS, \"\"},\n"
  globalEmit &= "    {NULL, NULL, 0, NULL}\n};\n"
  globalEmit &= "static struct PyModuleDef nim_mod = {\n"
  globalEmit &= "    PyModuleDef_HEAD_INIT,\n"
  globalEmit &= "    \"" & modNameStr & "\",\n"
  if not moduleDoc.isNil:
    globalEmit &= "    \"" & moduleDoc.strVal & "\",\n"
  else:
    globalEmit &= "    NULL,\n"
  globalEmit &= "    -1,\n"
  globalEmit &= "    nim_meth,\n"
  globalEmit &= "    NULL, NULL, NULL, NULL\n};\n"

  result.add(exportedProcs)
  result.add nnkPragma.newTree(
    nnkExprColonExpr.newTree(ident("emit"), newLit(globalEmit))
  )

  var initBody = newStmtList()
  initBody.add nnkPragma.newTree(
    nnkExprColonExpr.newTree(
      ident("emit"),
      newLit("`result` = PyModule_Create2(&nim_mod, PYTHON_API_VERSION);\n")
    )
  )

  var initProc = newProc(initName, [
    nnkPtrTy.newTree(ident("PyObject"))
  ], initBody, nnkProcDef)
  initProc[4] = nnkPragma.newTree(ident"exportc", ident"cdecl", ident"dynlib")

  result.add(initProc)

  when defined(clueDebugExtension):
    echo result.repr
