# Clue - A cool toolkit for Nim developers
#
# (c) 2026 George Lemon | MIT License
#          Made by Humans from OpenPeeps
#          https://github.com/openpeeps/clue

## Compile-time C header and Go wrapper generator for Nim libraries.
##
## Import this module and mark exports with `{.exportc.}`:
##
## ```nim
## import clue/clib_export
##
## type MyEnum* {.exportc.} = enum eA, eB, eC
## proc myFunc*(a: cint): cdouble {.exportc, cdecl, dynlib.} = discard
##
## genCHeader(MyEnum, myFunc)
## genGoHeader(MyEnum, myFunc)
## ```
##
## When compiled with `--app:lib -d:clueBuild`, wrapper files are generated
## at `wrappers/c/<modname>.h` and `wrappers/go/<pkg>/<pkg>.go`.

import std/[macros, strformat, strutils, os]

# Shared helpers

proc toCType*(nimType: string): string {.compileTime.} =
  ## Map a Nim type name to its C equivalent.
  case nimType
  of "cint": "int"
  of "cstring": "char*"
  of "cdouble": "double"
  of "cfloat": "float"
  of "cbool": "bool"
  of "cuchar": "unsigned char"
  of "clong": "long"
  of "culong": "unsigned long"
  of "csize_t": "size_t"
  of "pointer": "void*"
  of "int32": "int32_t"
  of "int64": "int64_t"
  of "uint32": "uint32_t"
  of "uint64": "uint64_t"
  of "int8": "int8_t"
  of "uint8": "uint8_t"
  of "void": "void"
  else: nimType

proc cTypeString*(typeNode: NimNode): string {.compileTime.} =
  ## Resolve a Nim type AST node to its C type string.
  ## Handles `ptr T`, `ref T`, `array[T, N]`, and plain identifiers.
  case typeNode.kind
  of nnkIdent:
    result = toCType($typeNode)
  of nnkSym:
    result = toCType($typeNode)
  of nnkBracketExpr:
    if $typeNode[0] == "ptr" or $typeNode[0] == "ref":
      let inner = cTypeString(typeNode[1])
      if inner != "void": result = inner & "*"
      else: result = "void*"
    elif $typeNode[0] == "array":
      result = "struct { " & cTypeString(typeNode[1]) & " data[" & $typeNode[2] & "]; }"
    else:
      result = cTypeString(typeNode[0]) & "*"
  of nnkPtrTy:
    let inner = cTypeString(typeNode[0])
    if inner != "void": result = inner & "*"
    else: result = "void*"
  of nnkVarTy:
    result = cTypeString(typeNode[0])
  of nnkEmpty:
    result = "void"
  else:
    result = "int"

proc symName*(n: NimNode): string {.compileTime.} =
  ## Extract the plain identifier name from a Nim AST node,
  ## stripping `nnkPragmaExpr` and `nnkPostfix` wrappers.
  if n.kind in {nnkIdent, nnkSym}: $n
  elif n.kind == nnkPragmaExpr: symName(n[0])
  elif n.kind == nnkPostfix: symName(n[1])
  else: ""

proc extractDocAST*(n: NimNode): string {.compileTime.} =
  ## Extract the first `##` doc comment from a Nim AST node.
  ## Searches children of `StmtList`, `StmtListExpr`, and `Asgn` nodes.
  for child in n:
    if child.kind == nnkCommentStmt:
      return $child
    if child.kind == nnkStmtListExpr:
      for grandchild in child:
        if grandchild.kind == nnkCommentStmt:
          return $grandchild

proc formatDoc*(doc: string): string =
  ## Wrap a doc string as a Javadoc-style `/** */` C comment block.
  if doc.len == 0: return ""
  result = "/**\n * " & doc.replace("\n", "\n * ") & "\n */\n"

proc needsInclude*(lines: seq[string]): tuple[stdint: bool, stdbool: bool] {.compileTime.} =
  ## Detect whether `<stdint.h>` and/or `<stdbool.h>` includes are needed
  ## based on generated declaration lines.
  for line in lines:
    if line.contains("int32_t") or line.contains("int64_t") or
       line.contains("uint32_t)") or line.contains("uint64_t") or
       line.contains("int8_t") or line.contains("uint8_t") or
       line.contains("size_t"):
      result.stdint = true
    if line.contains("bool"):
      result.stdbool = true

proc goName*(s: string): string =
  ## Capitalize the first letter to produce an exported Go identifier.
  s[0 .. 0].toUpper & s[1 .. ^1]

proc goLocalType*(cType: string): string {.compileTime.} =
  ## Map a C type string to its corresponding Go local type.
  ## Pointer types become `*<Base>`, primitives map directly.
  if cType.endsWith("*"):
    let base = cType[0 .. ^2].strip
    if base in ["int", "double", "float", "bool", "char", "void"]:
      return base
    return "*" & base
  case cType
  of "int": "int"
  of "double": "float64"
  of "float": "float64"
  of "bool": "bool"
  of "char*": "string"
  of "void": ""
  else: cType

proc goArgConv*(cType: string, goName: string): string {.compileTime.} =
  ## Generate the cgo argument conversion expression for a Go variable.
  ## Primitives are cast with `C.double(x)`, pointers use `unsafe.Pointer`.
  if cType.endsWith("*"):
    let base = cType[0 .. ^2].strip
    if base in ["int", "double", "float", "bool", "char", "void"]:
      return "C." & base & "(" & goName & ")"
    return "(*C." & base & ")(unsafe.Pointer(" & goName & "))"
  case cType
  of "int": "C.int(" & goName & ")"
  of "double": "C.double(" & goName & ")"
  of "float": "C.float(" & goName & ")"
  of "bool": "C.bool(" & goName & ")"
  of "char*": "C.CString(" & goName & ")"
  of "void": ""
  else: "C." & cType & "(" & goName & ")"

proc goRetConv*(cType: string, expr: string): string {.compileTime.} =
  ## Generate the cgo return value conversion expression.
  ## Pointers pass through, primitives are cast back to Go types,
  ## strings use `C.GoString`.
  if cType.endsWith("*"): return expr
  case cType
  of "int": "int(" & expr & ")"
  of "double": "float64(" & expr & ")"
  of "float": "float64(" & expr & ")"
  of "bool": "bool(" & expr & ")"
  of "char*": "C.GoString(" & expr & ")"
  of "void": ""
  else: ""

#
# C
#

proc genProcDecl*(procNode: NimNode, apiMacro: string): string {.compileTime.} =
  ## Generate a C function declaration from a Nim proc definition.
  let fnName = symName(procNode[0])
  let params = procNode[3]
  var cParams: seq[string] = @[]
  var retType = "void"
  if params.len > 0 and params[0].kind != nnkEmpty:
    retType = cTypeString(params[0])
  for i in 1 ..< params.len:
    if params[i].kind == nnkIdentDefs:
      let pType = cTypeString(params[i][^2])
      for j in 0 ..< params[i].len - 2:
        let pName = symName(params[i][j])
        if pName.len > 0:
          cParams.add(pType & " " & pName)
  let cParamsStr = if cParams.len > 0: cParams.join(", ") else: "void"
  result = apiMacro & " " & retType & " " & fnName & "(" & cParamsStr & ");"

proc genEnumDecl*(enumName: string, bodyNode: NimNode): string {.compileTime.} =
  ## Generate a C `typedef enum` from a Nim enum type body.
  var values: seq[string] = @[]
  for child in bodyNode:
    if child.kind == nnkIdent or child.kind == nnkSym:
      values.add(enumName & "_" & $child)
    elif child.kind == nnkEnumFieldDef:
      let fieldName = $child[0]
      values.add(enumName & "_" & fieldName)
  if values.len == 0:
    return ""
  result = "typedef enum {\n  " & values.join(",\n  ") & "\n} " & enumName & ";"

proc genObjectDecl*(objName: string, bodyNode: NimNode): string {.compileTime.} =
  ## Generate a C `typedef struct` from a Nim object type body.
  var fields: seq[string] = @[]
  var walk = bodyNode
  if walk.kind == nnkRecList:
    discard
  elif walk.kind == nnkObjectTy and walk.len >= 2:
    walk = walk[^1]
  elif walk.kind == nnkBracketExpr:
    walk = walk[^1]
    if walk.kind == nnkObjectTy and walk.len >= 2:
      walk = walk[^1]
  for child in walk:
    if child.kind == nnkIdentDefs:
      for i in 0 ..< child.len - 2:
        if child[i].kind in {nnkIdent, nnkSym, nnkPostfix}:
          let fName = symName(child[i])
          if fName.len > 0:
            let fType = cTypeString(child[^2])
            fields.add("  " & fType & " " & fName & ";")
  if fields.len == 0:
    return ""
  result = "typedef struct {\n" & fields.join("\n") & "\n} " & objName & ";"

macro genCHeader*(exports: varargs[typed]) =
  ## Generate a C header file for exported symbols.
  ##
  ## Writes to `wrappers/c/<modname>.h` next to the source file.
  ##
  ## Only runs when `-d:clueBuild` is defined.
  ##
  ## ```nim
  ## genCHeader(MyEnum, MyObject, myFunc)
  ## ```
  result = newStmtList()

  when not defined(clueBuild):
    return

  var headerLines: seq[string] = @[]
  var modName = ""

  for exp in exports:
    if modName == "":
      modName = exp.lineInfoObj.filename.splitFile.name

  let apiMacro = if modName.len > 0: modName.toUpper & "_API" else: "CLUE_API"

  for exp in exports:
    let impl = exp.getImpl
    var doc = ""

    case impl.kind
    of nnkProcDef, nnkFuncDef:
      for i in 0 ..< impl.len:
        if impl[i].kind in {nnkStmtList, nnkAsgn, nnkStmtListExpr}:
          doc = extractDocAST(impl[i])
      headerLines.add(formatDoc(doc) & genProcDecl(impl, apiMacro))
    of nnkTypeDef:
      let typeName = symName(impl[0])
      var typeBody = impl[2]
      if typeBody.kind in {nnkRefTy, nnkPtrTy}:
        typeBody = typeBody[0]
      elif typeBody.kind == nnkBracketExpr:
        typeBody = typeBody[^1]
      var enumBody: NimNode = nil
      var objBody: NimNode = nil
      if typeBody.kind == nnkEnumTy:
        enumBody = typeBody
        doc = extractDocAST(typeBody)
      elif typeBody.kind == nnkObjectTy:
        objBody = typeBody
        if typeBody.len >= 2 and typeBody[^1].kind == nnkRecList:
          doc = extractDocAST(typeBody[^1])
      if enumBody != nil:
        headerLines.add(formatDoc(doc) & genEnumDecl(typeName, enumBody))
      elif objBody != nil:
        headerLines.add(formatDoc(doc) & genObjectDecl(typeName, objBody))
    else:
      discard

  if headerLines.len == 0:
    return

  let srcPath = exports[0].lineInfoObj.filename
  let guardVal = modName.toUpper & "_H"
  let outDir = srcPath.parentDir / "wrappers" / "c"
  let outPath = outDir / modName & ".h"

  let inc = needsInclude(headerLines)

  var includes: seq[string] = @[]
  if inc.stdbool:
    includes.add("#include <stdbool.h>")
  if inc.stdint:
    includes.add("#include <stdint.h>")

  let includesBlock = if includes.len > 0: includes.join("\n") & "\n" else: ""
  let joined = headerLines.join("\n\n")
  let full = "/* Auto-generated by Clue. Do not edit. */\n\n" &
    "#ifndef " & guardVal & "\n#define " & guardVal & "\n\n" &
    includesBlock &
    "#ifndef " & apiMacro & "\n#  define " & apiMacro & " extern\n#endif\n\n" &
    "#ifdef __cplusplus\nextern \"C\" {\n#endif\n\n" &
    joined & "\n\n#ifdef __cplusplus\n}\n#endif\n\n" &
    "#endif /* " & guardVal & " */\n"

  createDir(outDir)
  writeFile(outPath, full)

  echo &"Generated C header: {outPath}"

#
# Go
#

proc genGoProc*(procNode: NimNode): string {.compileTime.} =
  ## Generate a Go wrapper function from a Nim proc definition.
  ## Converts parameters and return value between Go and C types
  ## using `unsafe.Pointer` for user types and direct casting for primitives.
  let fnName = symName(procNode[0])
  let params = procNode[3]
  var goParams: seq[string] = @[]
  var goArgs: seq[string] = @[]
  var cRetType = "void"
  if params.len > 0 and params[0].kind != nnkEmpty:
    cRetType = cTypeString(params[0])
  for i in 1 ..< params.len:
    if params[i].kind == nnkIdentDefs:
      let pType = cTypeString(params[i][^2])
      for j in 0 ..< params[i].len - 2:
        let pName = symName(params[i][j])
        if pName.len > 0:
          goParams.add(pName & " " & goLocalType(pType))
          goArgs.add(goArgConv(pType, pName))
  let callArgs = if goArgs.len > 0: goArgs.join(", ") else: ""
  let retLocal = goLocalType(cRetType)
  let retPart = if retLocal.len > 0: " " & retLocal else: ""
  let bodyLine = if retLocal.len > 0: "\treturn " & goRetConv(cRetType, "C." & fnName & "(" & callArgs & ")")
                 else: "\tC." & fnName & "(" & callArgs & ")"
  result = "func " & goName(fnName) & "(" & goParams.join(", ") & ")" & retPart & " {\n" &
    bodyLine & "\n}"

proc genGoEnum*(enumName: string, bodyNode: NimNode): string {.compileTime.} =
  ## Generate Go constant declarations from a Nim enum type body.
  ## Each constant is bound to the raw C enum value.
  var lines: seq[string] = @[]
  lines.add("const (")
  for child in bodyNode:
    if child.kind == nnkIdent or child.kind == nnkSym:
      let name = goName($(child))
      lines.add("\t" & name & " = C." & enumName & "_" & $(child))
    elif child.kind == nnkEnumFieldDef:
      let fieldName = goName($child[0])
      lines.add("\t" & fieldName & " = C." & enumName & "_" & $child[0])
  lines.add(")")
  lines.join("\n")

proc genGoObject*(objName: string, bodyNode: NimNode): string {.compileTime.} =
  ## Generate a Go struct type from a Nim object type body.
  ## Fields are exported (capitalized) with their Go equivalent types.
  var fields: seq[string] = @[]
  var walk = bodyNode
  if walk.kind == nnkRecList: discard
  elif walk.kind == nnkObjectTy and walk.len >= 2: walk = walk[^1]
  elif walk.kind == nnkBracketExpr:
    walk = walk[^1]
    if walk.kind == nnkObjectTy and walk.len >= 2: walk = walk[^1]
  for child in walk:
    if child.kind == nnkIdentDefs:
      for i in 0 ..< child.len - 2:
        if child[i].kind in {nnkIdent, nnkSym, nnkPostfix}:
          let fName = symName(child[i])
          if fName.len > 0:
            let fType = cTypeString(child[^2])
            let goType = goLocalType(fType)
            let capName = goName(fName)
            fields.add("\t" & capName & " " & goType)
  if fields.len == 0: return ""
  result = "type " & objName & " struct {\n" & fields.join("\n") & "\n}"

macro genGoHeader*(exports: varargs[typed]) =
  ## Generate a Go wrapper file for exported symbols.
  ##
  ## Writes to `wrappers/go/<pkg>/<pkg>.go` next to the source file.
  ## Each Go function wraps the corresponding C function via cgo,
  ## converting types with `C.something` and `unsafe.Pointer`.
  ##
  ## Only runs when `-d:clueBuild` is defined.
  ##
  ## ```nim
  ## genGoHeader(MyEnum, MyObject, myFunc)
  ## ```
  result = newStmtList()
  when not defined(clueBuild): return

  var pkgName = ""
  var goLines: seq[string] = @[]

  for exp in exports:
    if pkgName == "":
      pkgName = exp.lineInfoObj.filename.splitFile.name
    let impl = exp.getImpl
    var doc = ""
    case impl.kind
    of nnkProcDef, nnkFuncDef:
      for i in 0 ..< impl.len:
        if impl[i].kind in {nnkStmtList, nnkAsgn, nnkStmtListExpr}:
          doc = extractDocAST(impl[i])
      let procDecl = genGoProc(impl)
      if doc.len > 0:
        goLines.add("// " & doc & "\n" & procDecl)
      else:
        goLines.add(procDecl)
    of nnkTypeDef:
      let typeName = symName(impl[0])
      var typeBody = impl[2]
      if typeBody.kind in {nnkRefTy, nnkPtrTy}: typeBody = typeBody[0]
      elif typeBody.kind == nnkBracketExpr: typeBody = typeBody[^1]
      if typeBody.kind == nnkEnumTy:
        doc = extractDocAST(typeBody)
        let enumDecl = genGoEnum(typeName, typeBody)
        if doc.len > 0:
          goLines.add("// " & doc & "\n" & enumDecl)
        else:
          goLines.add(enumDecl)
      elif typeBody.kind == nnkObjectTy:
        if typeBody.len >= 2 and typeBody[^1].kind == nnkRecList:
          doc = extractDocAST(typeBody[^1])
        let objDecl = genGoObject(typeName, typeBody)
        if doc.len > 0:
          goLines.add("// " & doc & "\n" & objDecl)
        else:
          goLines.add(objDecl)
    else: discard

  if goLines.len == 0: return
  let srcPath = exports[0].lineInfoObj.filename
  let outDir = srcPath.parentDir / "wrappers" / "go" / pkgName
  let outPath = outDir / pkgName & ".go"
  let cHeaderRel = "../../c/" & pkgName & ".h"
  let header = "// Auto-generated by Clue. Do not edit.\n\n" &
    "package " & pkgName & "\n\n" &
    "/*\n#include \"" & cHeaderRel & "\"\n*/\n" &
    "import \"C\"\n" &
    "import \"unsafe\"\n\n" &
    goLines.join("\n\n") & "\n"
  createDir(outDir)
  writeFile(outPath, header)
  echo &"Generated Go wrapper: {outPath}"

#
# Rust
#

proc toRustType*(cType: string): string {.compileTime.} =
  ## Map a C type string to its corresponding Rust type.
  result = case cType
  of "int": "i32"
  of "char*": "*const c_char"
  of "double": "f64"
  of "float": "f32"
  of "bool": "bool"
  of "void": "()"
  of "long": "i64"
  of "unsigned long", "culong": "u64"
  of "size_t": "usize"
  else:
    if cType.endsWith("*"):
      "*const " & cType[0 .. ^2].strip
    else:
      cType

proc genRustPtrType*(cType: string, paramName: string): string {.compileTime.} =
  ## Generate the Rust pointer type, using `*mut` for output parameters
  ## (names like `res`, `out`, `result`) and `*const` otherwise.
  let base = cType[0 .. ^2].strip
  let isMut = paramName in ["res", "out", "result"]
  if isMut: "*mut " & base else: "*const " & base

proc genRustParam*(cType: string, paramName: string): string {.compileTime.} =
  let rustType = toRustType(cType)
  if cType.endsWith("*"):
    genRustPtrType(cType, paramName)
  elif rustType == "*const c_char":
    "*const c_char"
  else:
    rustType

proc genRustProc*(procNode: NimNode): string {.compileTime.} =
  ## Generate a Rust `extern "C"` function declaration from a Nim proc.
  let fnName = symName(procNode[0])
  let params = procNode[3]
  var rustParams: seq[string] = @[]
  var retType = "()"
  if params.len > 0 and params[0].kind != nnkEmpty:
    retType = toRustType(cTypeString(params[0]))
  for i in 1 ..< params.len:
    if params[i].kind == nnkIdentDefs:
      let pType = cTypeString(params[i][^2])
      for j in 0 ..< params[i].len - 2:
        let pName = symName(params[i][j])
        if pName.len > 0:
          rustParams.add(pName & ": " & genRustParam(pType, pName))
  let paramsStr = rustParams.join(", ")
  result = "pub fn " & fnName & "(" & paramsStr & ") -> " & retType & ";"

proc rustScreamingCase*(s: string): string {.compileTime.} =
  ## Convert camelCase or snake_case to SCREAMING_CASE.
  result = ""
  for c in s:
    if c in {'A'..'Z'} and result.len > 0:
      result.add('_')
    result.add(c.toUpperAscii)

proc genRustEnum*(enumName: string, bodyNode: NimNode): string {.compileTime.} =
  ## Generate Rust `pub const` constants for each enum value.
  var lines: seq[string] = @[]
  for child in bodyNode:
    if child.kind == nnkIdent or child.kind == nnkSym:
      let name = rustScreamingCase($(child))
      lines.add("pub const " & name & ": i32 = " & enumName & "_" & $(child) & " as i32;")
    elif child.kind == nnkEnumFieldDef:
      let name = rustScreamingCase($child[0])
      lines.add("pub const " & name & ": i32 = " & enumName & "_" & $child[0] & " as i32;")
  lines.join("\n")

proc genRustObject*(objName: string, bodyNode: NimNode): string {.compileTime.} =
  ## Generate a Rust `#[repr(C)]` struct from a Nim object.
  var fields: seq[string] = @[]
  var walk = bodyNode
  if walk.kind == nnkRecList: discard
  elif walk.kind == nnkObjectTy and walk.len >= 2: walk = walk[^1]
  elif walk.kind == nnkBracketExpr:
    walk = walk[^1]
    if walk.kind == nnkObjectTy and walk.len >= 2: walk = walk[^1]
  for child in walk:
    if child.kind == nnkIdentDefs:
      for i in 0 ..< child.len - 2:
        if child[i].kind in {nnkIdent, nnkSym, nnkPostfix}:
          let fName = symName(child[i])
          if fName.len > 0:
            let fType = cTypeString(child[^2])
            let rustType = toRustType(fType)
            fields.add("    pub " & fName & ": " & rustType & ",")
  if fields.len == 0: return ""
  result = "#[repr(C)]\npub struct " & objName & " {\n" & fields.join("\n") & "\n}"

proc genEnumValues*(bodyNode: NimNode): seq[string] {.compileTime.} =
  ## Extract raw enum value strings from an enum body, in order.
  for child in bodyNode:
    if child.kind in {nnkIdent, nnkSym}:
      result.add($child)
    elif child.kind == nnkEnumFieldDef:
      result.add($child[0])

macro genRustHeader*(exports: varargs[typed]) =
  ## Generate a Rust binding file for exported symbols.
  ##
  ## Writes to `wrappers/rust/<crate>/src/lib.rs` next to the source file,
  ## along with `Cargo.toml` and `build.rs`.
  ##
  ## Only runs when `-d:clueBuild` is defined.
  ##
  ## ```nim
  ## genRustHeader(MyEnum, MyObject, myFunc)
  ## ```
  result = newStmtList()
  when not defined(clueBuild): return

  var crateName = ""
  var externLines: seq[string] = @[]
  var typeLines: seq[string] = @[]

  for exp in exports:
    if crateName == "":
      crateName = exp.lineInfoObj.filename.splitFile.name
    let impl = exp.getImpl
    var doc = ""
    case impl.kind
    of nnkProcDef, nnkFuncDef:
      for i in 0 ..< impl.len:
        if impl[i].kind in {nnkStmtList, nnkAsgn, nnkStmtListExpr}:
          doc = extractDocAST(impl[i])
      let procDecl = genRustProc(impl)
      if doc.len > 0:
        externLines.add("    /// " & doc & "\n    " & procDecl)
      else:
        externLines.add("    " & procDecl)
    of nnkTypeDef:
      let typeName = symName(impl[0])
      var typeBody = impl[2]
      if typeBody.kind in {nnkRefTy, nnkPtrTy}: typeBody = typeBody[0]
      elif typeBody.kind == nnkBracketExpr: typeBody = typeBody[^1]
      if typeBody.kind == nnkEnumTy:
        doc = extractDocAST(typeBody)
        let values = genEnumValues(typeBody)
        var consts: seq[string] = @[]
        for idx, val in values:
          consts.add("pub const " & rustScreamingCase(val) & ": i32 = " & $idx & ";")
        let docPrefix = if doc.len > 0: "/// " & doc & "\n" else: ""
        typeLines.add(docPrefix & consts.join("\n"))
      elif typeBody.kind == nnkObjectTy:
        if typeBody.len >= 2 and typeBody[^1].kind == nnkRecList:
          doc = extractDocAST(typeBody[^1])
        let objDecl = genRustObject(typeName, typeBody)
        if doc.len > 0:
          typeLines.add("/// " & doc & "\n" & objDecl)
        else:
          typeLines.add(objDecl)
    else: discard

  if externLines.len == 0 and typeLines.len == 0: return
  let srcPath = exports[0].lineInfoObj.filename
  let crateDir = srcPath.parentDir / "wrappers" / "rust" / crateName
  let srcDir = crateDir / "src"
  let libPath = srcDir / "lib.rs"
  let cargoPath = crateDir / "Cargo.toml"
  let buildRsPath = crateDir / "build.rs"

  let all = typeLines.join("\n\n") & "\n\nextern \"C\" {\n" & externLines.join("\n\n") & "\n}\n"

  let libContent = "#![allow(non_camel_case_types, non_snake_case)]\n\n" & all

  let cargoContent = "[package]\n" &
    "name = \"" & crateName & "\"\n" &
    "version = \"0.1.0\"\n" &
    "edition = \"2021\"\n\n" &
    "[lib]\n\n" &
    "[dependencies]\nlibc = \"0.2\"\n"

  let buildRsContent = "fn main() {\n" &
    "    println!(\"cargo:rustc-link-search=../../../build\");\n" &
    "    println!(\"cargo:rustc-link-lib=" & crateName & "\");\n" &
    "}\n"

  createDir(srcDir)
  writeFile(libPath, libContent)
  writeFile(cargoPath, cargoContent)
  writeFile(buildRsPath, buildRsContent)
  echo &"Generated Rust bindings: {libPath}"

#
# Crystal
#

proc crystalType*(cType: string): string {.compileTime.} =
  ## Map a C type string to its Crystal equivalent.
  ## Pointer types become `T*`, primitives map to Crystal's `Int32`/`Float64` etc.
  result = case cType
  of "int": "Int32"
  of "char*": "UInt8*"
  of "double": "Float64"
  of "float": "Float32"
  of "bool": "Bool"
  of "void": "Void"
  of "long", "clong": "Int64"
  of "unsigned long", "culong": "UInt64"
  of "cuchar": "UInt8"
  of "size_t": "UInt64"
  of "int32_t": "Int32"
  of "int64_t": "Int64"
  of "uint32_t": "UInt32"
  of "uint64_t": "UInt64"
  of "int8_t": "Int8"
  of "uint8_t": "UInt8"
  of "void*": "Void*"
  else:
    if cType.endsWith("*"):
      cType[0 .. ^2].strip & "*"
    else:
      cType

proc genCrystalProc*(procNode: NimNode): string {.compileTime.} =
  ## Generate a Crystal `fun` declaration inside a `lib` block.
  let fnName = symName(procNode[0])
  let params = procNode[3]
  var crystalParams: seq[string] = @[]
  var retType = "Void"
  if params.len > 0 and params[0].kind != nnkEmpty:
    retType = crystalType(cTypeString(params[0]))
  for i in 1 ..< params.len:
    if params[i].kind == nnkIdentDefs:
      let pType = cTypeString(params[i][^2])
      for j in 0 ..< params[i].len - 2:
        let pName = symName(params[i][j])
        if pName.len > 0:
          crystalParams.add(pName & " : " & crystalType(pType))
  let paramsStr = crystalParams.join(", ")
  result = "  fun " & fnName & "(" & paramsStr & ") : " & retType

proc genCrystalEnum*(enumName: string, bodyNode: NimNode): string {.compileTime.} =
  ## Generate a Crystal `enum` block inside a `lib` block.
  ## Enum values are PascalCased via `goName`.
  var values: seq[string] = @[]
  for child in bodyNode:
    if child.kind in {nnkIdent, nnkSym}:
      values.add("    " & goName($child))
    elif child.kind == nnkEnumFieldDef:
      values.add("    " & goName($child[0]))
  if values.len == 0: return ""
  result = "  enum " & enumName & "\n" & values.join("\n") & "\n  end"

proc genCrystalObject*(objName: string, bodyNode: NimNode): string {.compileTime.} =
  ## Generate a Crystal `@[Extern] struct` from a Nim object type body.
  ## Fields are typed with their Crystal equivalents.
  var fields: seq[string] = @[]
  var walk = bodyNode
  if walk.kind == nnkRecList: discard
  elif walk.kind == nnkObjectTy and walk.len >= 2: walk = walk[^1]
  elif walk.kind == nnkBracketExpr:
    walk = walk[^1]
    if walk.kind == nnkObjectTy and walk.len >= 2: walk = walk[^1]
  for child in walk:
    if child.kind == nnkIdentDefs:
      for i in 0 ..< child.len - 2:
        if child[i].kind in {nnkIdent, nnkSym, nnkPostfix}:
          let fName = symName(child[i])
          if fName.len > 0:
            let fType = cTypeString(child[^2])
            fields.add("    " & fName & " : " & crystalType(fType))
  if fields.len == 0: return ""
  result = "  @[Extern]\n  struct " & objName & "\n" & fields.join("\n") & "\n  end"

macro genCrystalHeader*(exports: varargs[typed]) =
  ## Generate a Crystal binding file for exported symbols.
  ##
  ## Writes to `wrappers/crystal/<crate>/src/<crate>.cr` next to the source file,
  ## along with `shard.yml`.
  ##
  ## Only runs when `-d:clueBuild` is defined.
  ##
  ## ```nim
  ## genCrystalHeader(MyEnum, MyObject, myFunc)
  ## ```
  result = newStmtList()
  when not defined(clueBuild): return

  var crateName = ""
  var funLines: seq[string] = @[]
  var typeLines: seq[string] = @[]

  for exp in exports:
    if crateName == "":
      crateName = exp.lineInfoObj.filename.splitFile.name
    let impl = exp.getImpl
    var doc = ""
    case impl.kind
    of nnkProcDef, nnkFuncDef:
      for i in 0 ..< impl.len:
        if impl[i].kind in {nnkStmtList, nnkAsgn, nnkStmtListExpr}:
          doc = extractDocAST(impl[i])
      let procDecl = genCrystalProc(impl)
      if doc.len > 0:
        funLines.add("  # " & doc & "\n" & procDecl)
      else:
        funLines.add(procDecl)
    of nnkTypeDef:
      let typeName = symName(impl[0])
      var typeBody = impl[2]
      if typeBody.kind in {nnkRefTy, nnkPtrTy}: typeBody = typeBody[0]
      elif typeBody.kind == nnkBracketExpr: typeBody = typeBody[^1]
      if typeBody.kind == nnkEnumTy:
        doc = extractDocAST(typeBody)
        let enumDecl = genCrystalEnum(typeName, typeBody)
        if doc.len > 0:
          typeLines.add("  # " & doc & "\n" & enumDecl)
        else:
          typeLines.add(enumDecl)
      elif typeBody.kind == nnkObjectTy:
        if typeBody.len >= 2 and typeBody[^1].kind == nnkRecList:
          doc = extractDocAST(typeBody[^1])
        let objDecl = genCrystalObject(typeName, typeBody)
        if doc.len > 0:
          typeLines.add("  # " & doc & "\n" & objDecl)
        else:
          typeLines.add(objDecl)
    else: discard

  if funLines.len == 0 and typeLines.len == 0: return

  let srcPath = exports[0].lineInfoObj.filename
  let crateDir = srcPath.parentDir / "wrappers" / "crystal" / crateName
  let srcDir = crateDir / "src"
  let crPath = srcDir / crateName & ".cr"
  let shardPath = crateDir / "shard.yml"

  let all = typeLines.join("\n\n") & "\n\n" & funLines.join("\n\n") & "\nend\n"

  let crContent = "# Auto-generated by Clue. Do not edit.\n\n" &
    "@[Link(ldflags: \"-L #{__DIR__}/../../../../build -l" & crateName & "\")]\n" &
    "lib Lib" & goName(crateName) & "\n" & all

  let shardContent = "name: " & crateName & "\n" &
    "version: 0.1.0\n\n" &
    "authors:\n  - Generated by Clue\n\n" &
    "crystal: \">= 1.0.0\"\n\nlicense: MIT\n"

  createDir(srcDir)
  writeFile(crPath, crContent)
  writeFile(shardPath, shardContent)
  echo &"Generated Crystal bindings: {crPath}"

#
# Nim (low-level C-style import bindings)
#

proc nimTypeString*(typeNode: NimNode): string {.compileTime.} =
  ## Convert a Nim AST type node to its Nim source representation,
  ## preserving `ptr T`, `ref T`, `array[T, N]` and plain identifiers.
  case typeNode.kind
  of nnkIdent, nnkSym:
    result = $typeNode
  of nnkBracketExpr:
    if $typeNode[0] in ["ptr", "ref"]:
      result = $typeNode[0] & " " & nimTypeString(typeNode[^1])
    elif $typeNode[0] == "array":
      result = "array[" & nimTypeString(typeNode[1]) & ", " & $typeNode[2] & "]"
    else:
      result = nimTypeString(typeNode[0])
  of nnkPtrTy:
    result = "ptr " & nimTypeString(typeNode[0])
  of nnkVarTy:
    result = "var " & nimTypeString(typeNode[0])
  of nnkEmpty:
    result = "void"
  else:
    result = $typeNode

proc genNimProc*(procNode: NimNode, headerVar: string): string {.compileTime.} =
  ## Generate a Nim `{.importc, header, cdecl.}` proc declaration.
  let fnName = symName(procNode[0])
  let params = procNode[3]
  var nimParams: seq[string] = @[]
  var retType = "void"
  if params.len > 0 and params[0].kind != nnkEmpty:
    retType = nimTypeString(params[0])
  for i in 1 ..< params.len:
    if params[i].kind == nnkIdentDefs:
      let pType = nimTypeString(params[i][^2])
      for j in 0 ..< params[i].len - 2:
        let pName = symName(params[i][j])
        if pName.len > 0:
          nimParams.add(pName & ": " & pType)
  let paramsStr = nimParams.join(", ")
  result = "proc " & fnName & "*(" & paramsStr & "): " & retType &
    " {.importc: \"" & fnName & "\", header: " & headerVar & ", cdecl.}"

proc genNimEnum*(enumName: string, bodyNode: NimNode, headerVar: string): string {.compileTime.} =
  ## Generate a Nim `{.importc, header, size.}` enum type declaration.
  var values: seq[string] = @[]
  for child in bodyNode:
    if child.kind in {nnkIdent, nnkSym}:
      values.add("  " & $child)
    elif child.kind == nnkEnumFieldDef:
      values.add("  " & $child[0])
  if values.len == 0: return ""
  result = "type " & enumName & "* {.importc: \"" & enumName &
    "\", header: " & headerVar & ", size: sizeof(cint).} = enum\n" & values.join("\n")

proc genNimObject*(objName: string, bodyNode: NimNode, headerVar: string): string {.compileTime.} =
  ## Generate a Nim `{.importc, header, bycopy.}` object type declaration.
  var fields: seq[string] = @[]
  var walk = bodyNode
  if walk.kind == nnkRecList: discard
  elif walk.kind == nnkObjectTy and walk.len >= 2: walk = walk[^1]
  elif walk.kind == nnkBracketExpr:
    walk = walk[^1]
    if walk.kind == nnkObjectTy and walk.len >= 2: walk = walk[^1]
  for child in walk:
    if child.kind == nnkIdentDefs:
      var fieldNames: seq[string] = @[]
      for i in 0 ..< child.len - 2:
        let fName = symName(child[i])
        if fName.len > 0:
          fieldNames.add(fName)
      if fieldNames.len > 0:
        let fType = nimTypeString(child[^2])
        fields.add("  " & fieldNames.join("*, ") & "*: " & fType)
  if fields.len == 0: return ""
  result = "type " & objName & "* {.importc: \"" & objName &
    "\", header: " & headerVar & ", bycopy.} = object\n" & fields.join("\n")

macro genNimHeader*(exports: varargs[typed]) =
  ## Generate a low-level C-style Nim binding module for exported symbols.
  ##
  ## Writes to `wrappers/nim/<modname>.nim` next to the source file.
  ## Each declaration is re-exported with `{.importc, header.}` pragmas,
  ## allowing other Nim projects to link against the compiled shared library.
  ##
  ## Only runs when `-d:clueBuild` is defined.
  ##
  ## ```nim
  ## genNimHeader(MyEnum, MyObject, myFunc)
  ## ```
  result = newStmtList()
  when not defined(clueBuild): return

  var modName = ""
  var nimLines: seq[string] = @[]

  for exp in exports:
    if modName == "":
      modName = exp.lineInfoObj.filename.splitFile.name

  if modName == "": return
  let headerVar = modName & "_h"

  for exp in exports:
    let impl = exp.getImpl
    var doc = ""
    case impl.kind
    of nnkProcDef, nnkFuncDef:
      for i in 0 ..< impl.len:
        if impl[i].kind in {nnkStmtList, nnkAsgn, nnkStmtListExpr}:
          doc = extractDocAST(impl[i])
      let procDecl = genNimProc(impl, headerVar)
      if doc.len > 0:
        nimLines.add("## " & doc & "\n" & procDecl)
      else:
        nimLines.add(procDecl)
    of nnkTypeDef:
      let typeName = symName(impl[0])
      var typeBody = impl[2]
      if typeBody.kind in {nnkRefTy, nnkPtrTy}: typeBody = typeBody[0]
      elif typeBody.kind == nnkBracketExpr: typeBody = typeBody[^1]
      if typeBody.kind == nnkEnumTy:
        doc = extractDocAST(typeBody)
        let enumDecl = genNimEnum(typeName, typeBody, headerVar)
        if doc.len > 0:
          nimLines.add("## " & doc & "\n" & enumDecl)
        else:
          nimLines.add(enumDecl)
      elif typeBody.kind == nnkObjectTy:
        if typeBody.len >= 2 and typeBody[^1].kind == nnkRecList:
          doc = extractDocAST(typeBody[^1])
        let objDecl = genNimObject(typeName, typeBody, headerVar)
        if doc.len > 0:
          nimLines.add("## " & doc & "\n" & objDecl)
        else:
          nimLines.add(objDecl)
    else: discard

  if nimLines.len == 0: return

  let srcPath = exports[0].lineInfoObj.filename
  let outDir = srcPath.parentDir / "wrappers" / "nim"
  let outPath = outDir / modName & ".nim"

  let constDecl = "import std/os\n\nconst " & modName & "_h = currentSourcePath().parentDir / \"../c/" & modName & ".h\"\n\n"
  let joined = nimLines.join("\n\n")
  let hdr = "## Low-level C-style Nim bindings for " & modName & ".\n" &
    "##\n" &
    "## Auto-generated by Clue. Do not edit.\n\n"
  let full = hdr & constDecl & joined & "\n"

  createDir(outDir)
  writeFile(outPath, full)
  echo &"Generated Nim bindings: {outPath}"
