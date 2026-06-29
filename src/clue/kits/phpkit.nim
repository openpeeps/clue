# Clue - A cool toolkit for Nim developers
#
# (c) 2026 George Lemon | MIT License
#          Made by Humans from OpenPeeps
#          https://github.com/openpeeps/clue

## This module implements a DSL-like interface for creating
## PHP extensiosn in Nim. It relies on the underlying C API bindings defined at lower levels.
## 
## It defines a `phpModule` macro that allows you to declare Nim-like functions and have them automatically
## exported as PHP functions in a PHP module.
## 
## The low-level API bindings is a ripoff of the PHP C API from the [phper-framework](https://github.com/phper-framework/phper)
## from Rust, which is not a 1:1 mapping of the C API, but provides the necessary C API functions and types
## to implement the higher-level DSL for defining PHP modules and functions in Nim.

import std/[macros, strutils]
import ./php/php_api

export php_api

type
  PhpParamType* = enum
    pptString          # s -> cstring + csize_t
    pptLong            # l -> cint
    pptDouble          # d -> cdouble
    pptBool            # b -> bool/cint (depends on your wrapper ABI)
    pptArray           # a -> ptr zval
    pptObject          # o -> ptr zval
    pptObjectOfClass   # O -> ptr zval + ptr zend_class_entry  

proc toZendFormatChar*(t: PhpParamType): char =
  case t
  of pptString: 's'
  of pptLong: 'l'
  of pptDouble: 'd'
  of pptBool: 'b'
  of pptArray: 'a'
  of pptObject: 'o'
  of pptObjectOfClass: 'O'

proc toZendFormatString*(types: openArray[PhpParamType]): string =
  var res = newStringOfCap(types.len)
  for t in types:
    res.add(toZendFormatChar(t))
  res

proc getType*(t: NimNode): PhpParamType {.compileTime.} =
  ## Map a Nim type node to a PhpParamType, which can then be used
  ## to generate the appropriate format string for phpclue_zend_parse_parameters.
  case t.kind
  of nnkStrLit: pptString
  of nnkIntLit: pptLong
  of nnkFloatLit: pptDouble
  of nnkIdent:
    case $t:
    of "bool": pptBool
    of "string": pptString
    of "int": pptLong
    of "float": pptDouble
    else:
      error("Unsupported parameter type: " & $t, t)
  else:
    error("Unsupported parameter type node: " & $t.kind, t)

template `%`*(x: untyped): untyped =
  phpclue_zval_stringl(retTy, $x.cstring, len($x).csize_t)

#
# API for defining a PHP Class
#
proc registerClass*(className: string,
                    names: openArray[string],
                    handlers: openArray[phpclue_zif_handler],
                    arginfos: openArray[ptr zend_internal_arg_info]): ptr zend_class_entry =
  let cnt = names.len.csize_t
  var ftab = phpclue_fe_alloc(cnt)
  for i in 0 ..< names.len:
    phpclue_fe_set(ftab, csize_t(i), names[i], handlers[i], arginfos[i], if arginfos[i] == nil: 0'u32 else: 1'u32, 0'u32)
  phpclue_fe_end(ftab, cnt)
  phpclue_init_class_entry_ex(className.cstring, csize_t(len(className.cstring)), cast[pointer](ftab), nil, nil)

#
# Macro for defining a PHP module
#
macro phpModule*(stmtNodes: untyped) =
  ## Define a PHP module with the given name and functions.
  ## 
  ## This macro generates the necessary boilerplate to create a PHP extension,
  ## including the module entry point and function registration.
  result = newStmtList()
  
  var moduleName: NimNode
  var moduleVersion: NimNode
  var exportedProcs = newStmtList()
  var injectFnEntries = newStmtList()
  var injectFnArgInfos = newStmtList()
  
  for node in stmtNodes:
    case node.kind
    of nnkAsgn:
      expectKind(node[1], nnkStrLit)
      if node[0].eqIdent"name":
        moduleName = node[1]
      elif node[0].eqIdent"version":
        moduleVersion = node[1]
    of nnkProcDef, nnkFuncDef:
      var fnParams: seq[NimNode]
      let fnIdentLit = newLit(node[0].strVal)
      var fnParamCheckArg = genSym(nskVar, "paramCheckArg")
      if node[3].len > 1:
        var fnParamChecks = newStmtList()

        ## collect types / names for both arginfo and parsing
        var paramTypes: seq[PhpParamType] = @[]
        var paramNames: seq[string] = @[]
        for i, param in node[3][1..^1]:
          expectKind(param, nnkIdentDefs)
          let phpType = getType(param[1])
          let paramNameLit = newLit($param[0])
          paramTypes.add(phpType)
          paramNames.add($param[0])

          let zendTypeExpr =
            case phpType
            of pptString: newCall(ident("phpclue_get_IS_STRING"))
            of pptLong:   newCall(ident("phpclue_get_IS_LONG"))
            of pptDouble: newCall(ident("phpclue_get_IS_DOUBLE"))
            of pptBool:   newCall(ident("phpclue_get_IS_TRUE")) # adjust if you expose bool type helper
            else:         newCall(ident("phpclue_get_IS_MIXED"))

          var pos = newLit(i)
          fnParamChecks.add quote do:
            phpclue_arginfo_set_typed(`fnParamCheckArg`, `pos`, false, `paramNameLit`, `zendTypeExpr`, false)

        # Build the parse-block that will be injected at the start of the proc body
        var parseBlock = newStmtList()
        # declare locals for parsed values (use genSym to avoid collisions)
        var paramVarSyms: seq[seq[NimNode]] = @[]
        for i, nm in paramNames:
          case paramTypes[i]
          of pptString:
            let cSym = ident(nm)
            let lSym = ident(nm & "Len")
            parseBlock.add quote do:
              var `cSym`: cstring = nil
              var `lSym`: csize_t = 0
            paramVarSyms.add(@[cSym, lSym])
          of pptLong:
            let iSym = ident(nm)
            parseBlock.add quote do:
              var `iSym`: zend_long = 0
            paramVarSyms.add(@[iSym])
          of pptDouble:
            let dSym = ident(nm)
            parseBlock.add quote do:
              var `dSym`: cdouble = 0.0
            paramVarSyms.add(@[dSym])
          of pptBool:
            let bSym = ident(nm)
            parseBlock.add quote do:
              var `bSym`: cint = 0
            paramVarSyms.add(@[bSym])
          else:
            let zSym = ident(nm)
            parseBlock.add quote do:
              var `zSym`: ptr zval = nil
            paramVarSyms.add(@[zSym])

        # build format string literal
        let fmtLiteral = newLit(toZendFormatString(paramTypes))

        # build phpclue_zend_parse_parameters call args (ctx, fmt, &vars...)
        var zendArgs: seq[NimNode] = @[]
        zendArgs.add(ident("ctx"))
        zendArgs.add(fmtLiteral)
        for syms in paramVarSyms:
          for s in syms:
            # pass address of each var (phpclue_zend_parse_parameters needs pointers)
            zendArgs.add(nnkAddr.newTree(s))

        # create the phpclue_zend_parse_parameters call node
        let parseCall = newCall(ident("phpclue_zend_parse_parameters"), zendArgs)

        # inject phpclue_zend_parse_parameters call; failure -> return (no value)
        parseBlock.add quote do:
          if `parseCall` != phpclue_zend_result_success():
            phpclue_throw_type_error(("$1: Argument 1 passed must be of type string" % [`fnIdentLit`]))
            return

        # finally, inject parseBlock at the start of the proc body
        # append it to the proc's body (node[5] is the body in Nim proc AST)
        # inject parseBlock at the start of the proc body (preserve existing body)
        let oldBody = node[^1]
        var combined = newStmtList()
        combined.add(parseBlock)
        if oldBody.kind != nnkEmpty:
          if oldBody.kind == nnkStmtList:
            for j in 0 ..< oldBody.len:
              combined.add(oldBody[j])
          else:
            combined.add(oldBody)
        node[^1] = combined

        var fnParamsCheck = newStmtList()
        let paramTypesLen = newLit(paramTypes.len)
        fnParamsCheck.add quote do:
          var `fnParamCheckArg` {.inject.} = phpclue_arginfo_alloc(`paramTypesLen`.csize_t)
          `fnParamChecks`
          `fnParamCheckArg` = phpclue_arginfo_finalize(`fnParamCheckArg`, `paramTypesLen`.csize_t)

        injectFnArgInfos.add(fnParamsCheck)
      else:
        injectFnArgInfos.add quote do:
          var `fnParamCheckArg` {.inject.}: ptr zend_internal_arg_info = phpclue_arginfo_alloc(0)
          `fnParamCheckArg` = phpclue_arginfo_finalize(`fnParamCheckArg`, 0)
      
      node[3] = newNimNode(nnkFormalParams)
      node[3].add(ident("void")) # no return type
      node[3].add(nnkIdentDefs.newTree(
        ident("ctx"),
        nnkPtrTy.newTree(ident("zend_execute_data")),
        newEmptyNode()
      ))
      
      node[3].add(nnkIdentDefs.newTree(
        ident("retTy"),
        nnkPtrTy.newTree(ident("zval")),
        newEmptyNode()
      ))
      
      if node[4].kind == nnkEmpty:
        node[4] = nnkPragma.newTree(ident"cdecl")
      else: node[4].add(ident"cdecl")

      exportedProcs.add(node)
      injectFnEntries.add(
        newCall(
          ident("phpclue_fe_set"),
          ident("functionEntry"),
          newCall(
            ident("csize_t"),
            newLit(injectFnEntries.len) # index of the function in the entry array
          ),
          newLit(node[0].strVal),
          node[0],
          fnParamCheckArg,
          newLit(0'u32),
          newLit(0'u32)
        )
      )
    else: 
      error("Unsupported statement in phpModule: " & $node.kind)

  let fnLen = newCall(ident("csize_t"), newLit(exportedProcs.len + 1))
  result.add quote do:
    var moduleEntry {.inject.}: ptr zend_module_entry
      # Global variable to hold the module entry
    var functionEntry {.inject.}: ptr zend_function_entry
      # Global variables to hold the module entry and function entries

    proc nim_module_init(typ {.inject.}: cint, module_number {.inject.}: cint): cint {.cdecl.} =
      # Module initialization function, called when the module is loaded.
      phpclue_zend_result_success()
    `exportedProcs`

    proc phpclue_nim_module_entry*: ptr zend_module_entry {.cdecl, exportc, dynlib.} =
      ## The main entry point for the PHP extension, which will be called by PHP
      ## when the extension is loaded.

      `injectFnArgInfos`

      # Allocate and set up the function entries for the module
      functionEntry = phpclue_fe_alloc(`fnLen`)
      `injectFnEntries`

      # Finalize the function entries array
      phpclue_fe_end(functionEntry, `fnLen`)

      # Allocate memory for the function entries and set up
      # the functions provided by this module.
      moduleEntry = phpclue_module_alloc()
      
      # Initialize the module entry with the module name,
      # version, functions, and lifecycle hooks.
      phpclue_module_init(
        m = moduleEntry,
        name = cstring(`moduleName`),
        version = cstring(`moduleVersion`),
        functionEntry,
        nim_module_init,
        mshutdown = nil,
        rinit = nil,
        rshutdown = nil,
        minfo = nil
      )

      # Return the module entry pointer to PHP, which will use
      # it to register the extension
      moduleEntry
  
  when defined(clueDebugExtension):
    echo result.repr