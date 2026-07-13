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

proc pluginsPhpCommand*(v: Values) =
  buildModule(v, "PHP", ext(".so"))

proc pluginsRubyCommand*(v: Values) =
  buildModule(v, "Ruby", ext(".bundle"))

proc pluginsLuaCommand*(v: Values) =
  buildModule(v, "Lua", ext(".so"))

proc pluginsPyCommand*(v: Values) =
  buildModule(v, "Python", ext(".so"))
