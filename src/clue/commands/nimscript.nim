# Clue - An alternative package manager for Nim development
#
# (c) 2026 George Lemon | MIT License
#          Made by Humans from OpenPeeps
#          https://github.com/openpeeps/clue

## Execute nimscript tasks defined in .nimble files.
##
## Nimble packages can define custom tasks using nimscript:
##
## .. code-block:: nim
##   task test, "Run unit tests":
##     exec "nim c -r tests/test1.nim"
##
## Clue creates a wrapper `.nims` file that imports `nimscriptapi.nim`
## and includes the actual `.nimble` file, then runs `nim e` on it.

import std/[os, osproc, strutils, json, hashes]

import pkg/kapsis/[runtime, interactive/prompts]

import ../pkgmanager/configs
import ../pkgmanager/nimbleparser

const
  # Wrapper template for .nims files — imports nimscriptapi and includes the .nimble
  nimscriptWrapper = """import system except getCommand, setCommand, switch, `--`, thisDir,
  packageName, version, author, description, license, srcDir, binDir, backend,
  skipDirs, skipFiles, skipExt, installDirs, installFiles, installExt, bin, foreignDeps,
  requires, requiresData, task, packageName

import strutils
import "$1"
include "$2"

onExit()
"""

  # The actual nimscriptapi.nim source — defines task, requires, switch, etc.
  nimscriptApiSource = """# Copyright (C) Dominik Picheta. All rights reserved.
# BSD License. Look at license.txt for more info.

## This module is implicitly imported in NimScript .nimble files.

import system except getCommand, setCommand, switch, `--`
import strformat, strutils, tables, sequtils
export tables

when (NimMajor, NimMinor) < (1, 3):
  when not defined(nimscript):
    import os
else:
  import os

var
  packageName* = ""
  version*: string
  author*: string
  description*: string
  license*: string
  srcDir*: string
  binDir*: string
  backend*: string
  testEntryPoint*: string

  skipDirs*, skipFiles*, skipExt*, installDirs*, installFiles*,
    installExt*, bin*, paths*, entryPoints*: seq[string] = @[]
  requiresData*: seq[string] = @[]
  taskRequiresData*: Table[string, seq[string]]
  foreignDeps*: seq[string] = @[]

  nimbleTasks: seq[tuple[name, description: string]] = @[]
  beforeHooks: seq[string] = @[]
  afterHooks: seq[string] = @[]
  flags: Table[string, seq[string]]
  namedBin*: Table[string, string]

  command = "e"
  project = ""
  success = false
  retVal = true
  nimblePathsEnv = "__NIMBLE_PATHS"

proc requires*(deps: varargs[string]) =
  for d in deps: requiresData.add(d)

proc taskRequires*(task: string, deps: varargs[string]) =
  if task notin taskRequiresData:
    taskRequiresData[task] = @[]
  for d in deps:
    taskRequiresData[task] &= d

proc getParams(): tuple[scriptFile, projectFile, outFile, actionName: string,
                        commandLineParams: seq[string]] =
  for i in 2 .. paramCount():
    let param = paramStr(i)
    if param[0] != '-':
      if result.scriptFile.len == 0:
        result.scriptFile = param
      elif result.projectFile.len == 0:
        result.projectFile = param
      elif result.outFile.len == 0:
        result.outFile = param
      elif result.actionName.len == 0:
        result.actionName = param.normalize
      else:
        result.commandLineParams.add param
    else:
      result.commandLineParams.add param

const
  (scriptFile, projectFile, outFile, actionName, commandLineParams*) = getParams()
  NimbleVersion* {.strdefine.} = ""
  NimbleMajor* {.intdefine.} = 0
  NimbleMinor* {.intdefine.} = 0
  NimblePatch* {.intdefine.} = 0

proc getCommand*(): string =
  return command

proc setCommand*(cmd: string, prj = "") =
  command = cmd
  if prj.len != 0:
    project = prj

proc switch*(key: string, value="") =
  if flags.hasKey(key):
    flags[key].add(value)
  else:
    flags[key] = @[value]

template `--`*(key, val: untyped) =
  switch(astToStr(key), strip astToStr(val))

template `--`*(key: untyped) =
  switch(astToStr(key), "")

template printIfLen(varName) =
  if varName.len != 0:
    result &= astToStr(varName) & ": \"\"\"" & varName & "\"\"\"\n"

template printSeqIfLen(name: string, varName: untyped) =
  if varName.len != 0:
    result &= name & ": \"" & varName.join(", ") & "\"\n"

template printSeqIfLen(varName) =
  printSeqIfLen(astToStr(varName), varName)

proc printPkgInfo(): string =
  if backend.len == 0:
    backend = "c"
  for k, v in namedBin:
    let idx = bin.find(k)
    if idx == -1:
      bin.add k & "=" & v
    else:
      bin[idx] = k & "=" & v
  result = "[Package]\n"
  if packageName.len != 0:
    result &= "name: \"" & packageName & "\"\n"
  printIfLen version
  printIfLen author
  printIfLen description
  printIfLen license
  printIfLen srcDir
  printIfLen binDir
  printIfLen backend
  printIfLen testEntryPoint
  printSeqIfLen skipDirs
  printSeqIfLen skipFiles
  printSeqIfLen skipExt
  printSeqIfLen installDirs
  printSeqIfLen installFiles
  printSeqIfLen installExt
  printSeqIfLen paths
  printSeqIfLen entryPoints
  printSeqIfLen bin
  printSeqIfLen "nimbleTasks", nimbleTasks.unzip()[0]
  printSeqIfLen beforeHooks
  printSeqIfLen afterHooks
  if requiresData.len != 0 or taskRequiresData.len != 0:
    result &= "\n[Deps]\n"
    if requiresData.len != 0:
      result &= &"requires: \"{requiresData.join(\", \")}\"\n"
    for task, requiresData in taskRequiresData.pairs:
      result &= &"{task}Requires: \"{requiresData.join(\", \")}\"\n"

proc onExit*() =
  if actionName.len == 0 or actionName == "help":
    var maxNameLen = 8
    for (name, _) in nimbleTasks:
      maxNameLen = max(maxNameLen, name.len)
    for (name, description) in nimbleTasks:
      echo alignLeft(name, maxNameLen + 2), description
  if "printPkgInfo".normalize == actionName:
    if outFile.len != 0:
      writeFile(outFile, printPkgInfo())
  else:
    var output = ""
    output &= "\"success\": " & $success & ", "
    output &= "\"command\": \"" & command & "\", "
    if project.len != 0:
      output &= "\"project\": \"" & project & "\", "
    if flags.len != 0:
      output &= "\"flags\": {"
      for key, val in flags.pairs:
        output &= "\"" & key & "\": ["
        for v in val:
          let v = if v.len > 0 and v[0] == '"': strutils.unescape(v) else: v
          output &= v.escape & ", "
        output = output[0 .. ^3] & "], "
      output = output[0 .. ^3] & "}, "
    output &= "\"retVal\": " & $retVal
    if outFile.len != 0:
      writeFile(outFile, "{" & output & "}")

template task*(name: untyped; description: string; body: untyped): untyped =
  proc `name Task`*() = body
  nimbleTasks.add (astToStr(name), description)
  if actionName.len == 0 or actionName == "help":
    success = true
  elif actionName == astToStr(name).normalize:
    success = true
    `name Task`()

template before*(action: untyped, body: untyped): untyped =
  proc `action Before`*(): bool =
    result = true
    body
  beforeHooks.add astToStr(action)
  if (astToStr(action) & "Before").normalize == actionName:
    success = true
    retVal = `action Before`()

template after*(action: untyped, body: untyped): untyped =
  proc `action After`*(): bool =
    result = true
    body
  afterHooks.add astToStr(action)
  if (astToStr(action) & "After").normalize == actionName:
    success = true
    retVal = `action After`()

const nimbleExe* {.strdefine.} = "nimble"

proc getPkgDir*(): string =
  result = projectFile.rsplit(seps={'/', '\\', ':'}, maxsplit=1)[0]

proc thisDir*(): string = getPkgDir()

proc getPaths*(): seq[string] =
  return getEnv(nimblePathsEnv).split("|")

proc getPathsClause*(): string =
  return getPaths().mapIt("--path:" & it).join(" ")

template feature*(name: string, body: untyped): untyped =
  discard

template dev*(body: untyped): untyped =
  discard
"""

  taskPattern = "task "

proc getNimblecacheDir(): string =
  ## Cache directory for wrapper .nims files.
  getTempDir() / "clue_nimblecache"

proc nimbleWrapperPath(nimblePath: string): string =
  ## Path to the cached wrapper .nims file for a given .nimble file.
  let nimbleLastModified = nimblePath.getLastModificationTime()
  let shash = $(nimblePath & $nimbleLastModified).hash().abs()
  let cacheDir = getNimblecacheDir() / nimblePath.extractFilename().changeFileExt("") & "_" & $shash
  cacheDir / nimblePath.extractFilename().changeFileExt("nims")

proc createNimscriptApi(cacheDir: string): string =
  ## Create or reuse the cached nimscriptapi.nim.
  let apiFile = cacheDir / "nimscriptapi.nim"
  if not fileExists(apiFile):
    createDir(cacheDir)
    writeFile(apiFile, nimscriptApiSource)
  apiFile

proc getOrCreateWrapper(nimblePath: string): string =
  ## Get or create the cached wrapper .nims file for a .nimble file.
  let nimsFile = nimbleWrapperPath(nimblePath)
  if fileExists(nimsFile):
    return nimsFile

  let cacheDir = nimsFile.parentDir()
  createDir(cacheDir)
  let apiFile = createNimscriptApi(cacheDir)

  writeFile(nimsFile, nimscriptWrapper % [apiFile.replace("\\", "/"), nimblePath.replace("\\", "/")])

  nimsFile

proc setupTempNimCfg(): tuple[tempRoot, prevXdg: string] =
  ## Create a temp XDG config dir with a nim.cfg that exposes clue's
  ## resolved deps to every child `nim c` spawned via `exec` in the
  ## nimble task. Uses XDG_CONFIG_HOME so we never touch the project
  ## tree — everything lives under getTempDir().
  let pathsEnv = getEnv("__NIMBLE_PATHS")
  let definesEnv = getEnv("__CLUE_DEFINES")
  if pathsEnv.strip().len == 0 and definesEnv.strip().len == 0:
    return ("", "")
  let tempRoot = getTempDir() / ("clue_xdg_" & $getCurrentProcessId() & "_" & $pathsEnv.hash().abs())
  let nimCfgDir = tempRoot / "nim"
  createDir(nimCfgDir)
  var content = ""
  for p in pathsEnv.split("|"):
    let q = p.strip()
    if q.len > 0:
      content &= "--path:\"" & q & "\"\n"
  for d in definesEnv.split(" "):
    let q = d.strip()
    if q.len > 0:
      if q.startsWith("-d:"):
        content &= "--define:\"" & q[3..^1] & "\"\n"
      elif q.startsWith("--define:"):
        content &= q & "\n"
      else:
        content &= q & "\n"
  writeFile(nimCfgDir / "nim.cfg", content)
  let prev = getEnv("XDG_CONFIG_HOME")
  putEnv("XDG_CONFIG_HOME", tempRoot)
  (tempRoot, prev)

proc cleanupTempNimCfg(tempRoot, prevXdg: string) =
  if tempRoot.len == 0: return
  if prevXdg.len == 0:
    delEnv("XDG_CONFIG_HOME")
  else:
    putEnv("XDG_CONFIG_HOME", prevXdg)
  try:
    removeFile(tempRoot / "nim" / "nim.cfg")
    removeDir(tempRoot / "nim")
    removeDir(tempRoot)
  except CatchableError: discard

proc detectNimBin(): string =
  ## Detect the nim compiler binary.
  resolveNimBin()

proc execNimscript*(nimblePath, actionName: string,
    args: seq[string] = @[], passNim: seq[string] = @[]): int =
  ## Execute a nimscript task from a .nimble file.
  ##
  ## Returns the exit code. Live output is shown (not captured).
  let nimsFile = getOrCreateWrapper(nimblePath)
  let outFile = getTempDir() / "clue_nimscript_" & $getCurrentProcessId() & ".out"
  let nimBin = detectNimBin()
  let (tmpXdg, prevXdg) = setupTempNimCfg()
  defer: cleanupTempNimCfg(tmpXdg, prevXdg)

  var cmd = nimBin & " e --hints:off --verbosity:0" &
    " --define:nimbleExe=clue" &
    " --define:NimbleVersion=0.1.9" &
    " --define:NimbleMajor=0" &
    " --define:NimbleMinor=1" &
    " --define:NimblePatch=9"

  for flag in passNim:
    cmd.add(" " & flag)

  cmd.add(" " & nimsFile.quoteShell)
  cmd.add(" " & nimblePath.quoteShell)
  cmd.add(" " & outFile.quoteShell)
  cmd.add(" " & actionName)

  for arg in args:
    cmd.add(" " & arg.quoteShell)

  result = execCmd(cmd)

  # Clean up output file
  if fileExists(outFile):
    try: removeFile(outFile)
    except CatchableError: discard

proc execNimscriptWithOutput*(nimblePath, actionName: string,
    args: seq[string] = @[], passNim: seq[string] = @[]): tuple[exitCode: int, output: string] =
  ## Execute a nimscript task and capture its output.
  let nimsFile = getOrCreateWrapper(nimblePath)
  let outFile = getTempDir() / "clue_nimscript_" & $getCurrentProcessId() & ".out"
  let nimBin = detectNimBin()
  let (tmpXdg, prevXdg) = setupTempNimCfg()
  defer: cleanupTempNimCfg(tmpXdg, prevXdg)

  var cmd = nimBin & " e --hints:off --verbosity:0" &
    " --define:nimbleExe=clue" &
    " --define:NimbleVersion=0.1.9" &
    " --define:NimbleMajor=0" &
    " --define:NimbleMinor=1" &
    " --define:NimblePatch=9"

  for flag in passNim:
    cmd.add(" " & flag)

  cmd.add(" " & nimsFile.quoteShell)
  cmd.add(" " & nimblePath.quoteShell)
  cmd.add(" " & outFile.quoteShell)
  cmd.add(" " & actionName)

  for arg in args:
    cmd.add(" " & arg.quoteShell)

  let (output, exitCode) = execCmdEx(cmd)

  # Read the output file for JSON results
  var fileOutput = ""
  if fileExists(outFile):
    try:
      fileOutput = readFile(outFile)
      removeFile(outFile)
    except CatchableError:
      discard

  (exitCode, output & fileOutput)

proc listTasks*(nimblePath: string): seq[tuple[name, description: string]] =
  ## Extract task names and descriptions from a .nimble file.
  ## Parses lines matching: task <name>, "<description>"
  try:
    let content = readFile(nimblePath)
    for line in content.splitLines():
      let trimmed = line.strip()
      if trimmed.startsWith(taskPattern):
        # Parse: task <name>, "<description>":
        let afterTask = trimmed[taskPattern.len .. ^1]
        let commaPos = afterTask.find(',')
        if commaPos >= 0:
          let name = afterTask[0 ..< commaPos].strip()
          let descPart = afterTask[commaPos + 1 .. ^1].strip()
          # Remove trailing : if present
          let descClean = descPart.strip(chars = {':', ' '})
          # Extract description from quotes
          if descClean.len >= 2 and descClean[0] == '"':
            let endQuote = descClean.rfind('"')
            if endQuote > 0:
              result.add((name, descClean[1 ..< endQuote]))
          else:
            result.add((name, descClean))
  except CatchableError:
    discard

proc execNimscriptCode*(code: string, actionName: string): int =
  ## Execute a raw nimscript string via a temp .nims file.
  ## Creates a temporary .nims file with the code, runs `nim e` on it,
  ## then cleans up.
  let nimsFile = getTempDir() / "clue_nimscript_code_" & $getCurrentProcessId() & ".nims"
  let outFile = getTempDir() / "clue_nimscript_code_" & $getCurrentProcessId() & ".out"
  let nimBin = detectNimBin()
  let (tmpXdg, prevXdg) = setupTempNimCfg()
  defer: cleanupTempNimCfg(tmpXdg, prevXdg)

  writeFile(nimsFile, code)

  var cmd = nimBin & " e --hints:off --verbosity:0" &
    " --define:nimbleExe=clue" &
    " --define:NimbleVersion=0.1.9" &
    " --define:NimbleMajor=0" &
    " --define:NimbleMinor=1" &
    " --define:NimblePatch=9" &
    " " & nimsFile.quoteShell &
    " " & nimsFile.quoteShell &
    " " & outFile.quoteShell &
    " " & actionName

  result = execCmd(cmd)

  # Clean up temp files
  if fileExists(nimsFile):
    try: removeFile(nimsFile)
    except CatchableError: discard
  if fileExists(outFile):
    try: removeFile(outFile)
    except CatchableError: discard

proc runNimscriptHook*(nimblePath, action: string, before: bool): bool =
  ## Run a before/after hook for the given action.
  ## Returns true if the hook ran successfully (or no hook defined).
  let hookName = if before: action & "Before" else: action & "After"
  let exitCode = execNimscript(nimblePath, hookName)
  if exitCode != 0:
    displayWarning("hook '" & hookName & "' failed (exit " & $exitCode & ")")
    return false
  true

proc taskCommand*(v: Values) =
  ## List or execute nimscript tasks from the current project's .nimble file.
  let pkgDir = getCurrentDir()
  let nimblePath = findNimbleFile(pkgDir)
  if nimblePath.len == 0:
    displayError("No .nimble file found in " & pkgDir, quitProcess = true)
    return

  let tasks = listTasks(nimblePath)

  if v.has("taskName"):
    let taskName = v.get("taskName").getStr
    # Find matching task (case-insensitive)
    var found = false
    for (name, desc) in tasks:
      if name.toLowerAscii == taskName.toLowerAscii:
        displayInfo("Running task '" & name & "'...")
        # Execute before hooks
        let beforeCode = execNimscript(nimblePath, name & "Before", passNim = extras)
        if beforeCode != 0:
          displayWarning("before hook for '" & name & "' failed (exit " & $beforeCode & ")")
        # Execute the task
        let exitCode = execNimscript(nimblePath, name, passNim = extras)
        # Execute after hooks
        let afterCode = execNimscript(nimblePath, name & "After", passNim = extras)
        if afterCode != 0:
          displayWarning("after hook for '" & name & "' failed (exit " & $afterCode & ")")
        if exitCode != 0:
          displayError("Task '" & name & "' failed (exit " & $exitCode & ")",
            quitProcess = true)
        found = true
        break
    if not found:
      displayError("Task '" & taskName & "' not found. Available tasks:", quitProcess = true)
      for (name, desc) in tasks:
        display("  " & name & " — " & desc)
  else:
    # List available tasks
    if tasks.len == 0:
      displayInfo("No tasks defined in " & nimblePath)
    else:
      displayInfo("Available tasks in " & nimblePath.extractFilename() & ":")
      for (name, desc) in tasks:
        display("  " & cyan(name) & " — " & desc)
