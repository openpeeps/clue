import std/[os, osproc, json, times]
import pkg/kapsis/runtime
import pkg/kapsis/interactive/prompts

import ../capi/[clang_lexer, c2nim]

template withBench(body: untyped) =
  let start = cpuTime()
  body
  let duration = cpuTime() - start
  displayInfo("Completed in " & $(duration) & " seconds")

proc capiHeaderCommand*(v: Values) =
  ## Generate Nim bindings from a C header file
  let headerFile = $(v.get("header").getPath)
  withBench do:
    var ntrans: NimTranspiler = initNimTranspiler(headerFile)
    echo ntrans.transpile()

import ../linter/nim/[nim_parser, idents, options]

proc capiPackageCommand*(v: Values) =
  ## Generate a full Nim package containing low-level bindings
  ## for a C library, along with documentation, prepare
  let src = """
proc add(a, b: int): int =
  a + b

let x = add(2, 3)
"""

  let cache = newIdentCache()
  let config = newConfigRef()

  let ast = parseString(
    s = readFile("example.nim"),
    cache = cache,
    config = config,
    filename = "example.nim",
    line = 1
  )

  echo "Parsed successfully."
  echo "Top-level node kind: ", ast.kind
  