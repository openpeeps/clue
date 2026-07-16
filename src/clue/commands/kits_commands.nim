# Clue - A cool toolkit for Nim developers
#
# (c) 2026 George Lemon | LGPLv3 License
#          Made by Humans from OpenPeeps
#          https://github.com/openpeeps/clue

import pkg/kapsis/runtime
import pkg/kapsis/interactive/prompts
import std/[os, osproc, strformat]

proc ext(ext: string): string =
  when defined(windows): ".dll"
  elif defined(macosx): ext
  else: ".so"

proc buildModule(v: Values, extName, outputExt: string) =
  let modulePath = v.get("module").getPath.path
  let outputDir = modulePath.parentDir / "build"
  createDir(outputDir)
  let outputFile = outputDir / modulePath.splitFile.name & outputExt
  let cmd = &"nim c --app:lib -d:clueBuild --out:{outputFile} {modulePath}"
  let code = execCmd(cmd)
  if code != 0:
    displayError(&"Build failed for {extName} extension (exit code: {code})")

proc pluginsCommand*(v: Values) =
  let extArg = v.get("--ext").getStr
  let extension =
    if extArg.len == 0: "py"
    else: extArg
  case extension
  of "py":
    buildModule(v, "Python", ext(".so"))
  of "rb":
    buildModule(v, "Ruby", ext(".bundle"))
  of "lua":
    buildModule(v, "Lua", ext(".so"))
  of "php":
    buildModule(v, "PHP", ext(".so"))
  else:
    displayError(&"Unknown extension: {extension}. Supported: py, rb, lua, php")
