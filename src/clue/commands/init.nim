# Clue - An alternative package manager for Nim development
#
# (c) 2026 George Lemon | MIT License
#          Made by Humans from OpenPeeps
#          https://github.com/openpeeps/clue

## `clue init` — bootstrap a starter nimble project in the current directory,
## mirroring `nimble init` prompts and generated stub files.

import std/[os, osproc, strutils, terminal]
import pkg/semver
import pkg/kapsis/runtime
import pkg/kapsis/interactive/prompts
import pkg/kapsis/interactive/widgets

import ../pkgmanager/configs
import ../pkgmanager/nimbleparser

const LibMainTemplate = """
# This is just an example to get you started. A typical library package
# exports the main API in this file. Note that you cannot rename this file
# but you can remove it if you wish.

proc add*(x, y: int): int =
  ## Adds two numbers together.
  return x + y
"""

const LibSubmoduleTemplate = """
# This is just an example to get you started. Users of your library will
# import this file by writing ``import @@NAME@@/submodule``. Feel free to rename or
# remove this file altogether. You may create additional modules alongside
# this file as required.

type
  Submodule* = object
    name*: string

proc initSubmodule*(): Submodule =
  ## Initialises a new ``Submodule`` object.
  Submodule(name: "Anonymous")
"""

const BinMainTemplate = """
# This is just an example to get you started. A typical binary package
# uses this file as the main entry point of the application.

when isMainModule:
  echo("Hello, World!")
"""

const HybridMainTemplate = """
# This is just an example to get you started. A typical hybrid package
# uses this file as the main entry point of the application.

import @@NAME@@/submodule

when isMainModule:
  echo(getWelcomeMessage())
"""

const HybridSubmoduleTemplate = """
# This is just an example to get you started. Users of your hybrid library will
# import this file by writing ``import @@NAME@@/submodule``. Feel free to rename or
# remove this file altogether. You may create additional modules alongside
# this file as required.

proc getWelcomeMessage*(): string = "Hello, World!"
"""

const TestHeaderTemplate = """# This is just an example to get you started. You may wish to put all of your
# tests into a single file, or separate them into multiple `test1`, `test2`
# etc. files (better names are recommended, just make sure the name starts with
# the letter 't').
#
# To run these tests, simply execute `nimble test`.

import unittest
"""

const LibTestTemplate = TestHeaderTemplate & """

import @@NAME@@
test "can add":
  check add(5, 5) == 10
"""

const HybridTestTemplate = TestHeaderTemplate & """

import @@NAME@@/submodule
test "correct welcome":
  check getWelcomeMessage() == "Hello, World!"
"""

const TestsConfigContent = """switch("path", "$projectDir/../src")
"""

proc writeExampleIfNonExistent(file, content: string) =
  if not fileExists(file):
    writeFile(file, content)
  else:
    displayWarning("File " & file & " already exists, did not write example code")

proc buildNimbleFile(pkgName, version, author, desc, license, nimDep, extras: string): string =
  result = """# Package

version       = "@@VERSION@@"
author        = "@@AUTHOR@@"
description   = "@@DESC@@"
license       = "@@LICENSE@@"
srcDir        = "src"
@@EXTRAS@@

# Dependencies

requires "nim >= @@NIMDEP@@"
"""
  result = result
    .replace("@@VERSION@@", version)
    .replace("@@AUTHOR@@", author.replace("\"", "\\\""))
    .replace("@@DESC@@", desc.replace("\"", "\\\""))
    .replace("@@LICENSE@@", license)
    .replace("@@EXTRAS@@", extras)
    .replace("@@NIMDEP@@", nimDep)

proc validPkgName(name: string): bool =
  ## A Nim identifier: letter or underscore first, then letters/digits/underscores.
  if name.len == 0:
    return false
  let first = name[0]
  if not (first in {'a'..'z'} or first in {'A'..'Z'} or first == '_'):
    return false
  for c in name[1 .. ^1]:
    if not (c in {'a'..'z'} or c in {'A'..'Z'} or c in {'0'..'9'} or c == '_'):
      return false
  true

proc promptVersion(label, default: string): string =
  ## Prompt until the input parses as a semver (empty input takes the default).
  while true:
    let value = prompt(label, default = default).strip()
    try:
      discard parseVersion(value)
      return value
    except CatchableError:
      displayError("Invalid version: " & value)

proc promptPkgType(): string =
  displayInfo("Package type?")
  let choices = ["library", "binary", "hybrid"]
  let idx = promptInteractive("Select Cycle with 'Tab', 'Enter' when done",
                @["library", "binary", "hybrid"], activeIcon = " ►")
  if idx < 0:
    quit(0)
  choices[idx]

proc promptLicense(): string =
  const licenses = ["MIT", "GPL-2.0", "Apache-2.0", "ISC", "GPL-3.0",
    "BSD-3-Clause", "LGPL-2.1", "LGPL-3.0", "LGPL-3.0-linking-exception",
    "EPL-2.0", "AGPL-3.0", "EUPL-1.2", "Proprietary", "Other"]
  let idx = promptInteractive("License?", licenses)
  if idx < 0:
    quit(0)
  licenses[idx]

proc gitAuthor(): string =
  ## The git-configured user name ("" when unavailable).
  let (outp, code) = execCmdEx("git config --get user.name")
  if code != 0:
    return ""
  outp.strip()

proc initCommand*(v: Values) =
  ## Bootstrap a starter project using the user's input.
  ## `-Y` skips all prompts and initializes a library package with defaults
  ## (git author, v0.1.0, MIT).
  let yesMode = v.has("-Y")
  if not yesMode and not isatty(stdout):
    displayError("`clue init` requires an interactive terminal. Use -Y to initialize non-interactively with default values.", quitProcess = true)
    return

  let dir = getCurrentDir()
  if findNimbleFile(dir).len > 0:
    displayError(dir & " already contains a .nimble file.", quitProcess = true)
    return

  # Package name: positional arg, else the directory name; must be a valid
  # Nim identifier.
  var pkgName =
    if v.has("name"): v.get("name").getStr
    else: dir.lastPathPart()
  if not validPkgName(pkgName):
    if yesMode:
      displayError("'" & pkgName & "' is not a valid Nim package name.", quitProcess = true)
      return
    while not validPkgName(pkgName):
      displayWarning("'" & pkgName & "' is not a valid Nim package name.")
      pkgName = prompt("Package name").strip()

  let author =
    if yesMode: gitAuthor()
    else: prompt("Author", default = gitAuthor()).strip()
  let pkgType =
    if yesMode: "library"
    else: promptPkgType()
  let version =
    if yesMode: "0.1.0"
    else: promptVersion("Initial version", "0.1.0")
  let description =
    if yesMode: "A new awesome nimble package"
    else: prompt("Package description",
      default = "A new awesome nimble package").strip()
  let license =
    if yesMode: "MIT"
    else: promptLicense()
  let nimDep =
    if yesMode: detectNimVersion()
    else: promptVersion("Lowest supported Nim version", detectNimVersion())

  # Per-type stubs and nimble options.
  var extras = ""
  case pkgType
  of "library":
    createDir(dir / "src" / pkgName)
    writeExampleIfNonExistent(dir / "src" / (pkgName.addFileExt("nim")),
      LibMainTemplate)
    writeExampleIfNonExistent(dir / "src" / pkgName / "submodule.nim",
      LibSubmoduleTemplate.replace("@@NAME@@", pkgName))
    createDir(dir / "tests")
    writeFile(dir / "tests" / "config.nims", TestsConfigContent)
    writeExampleIfNonExistent(dir / "tests" / "test1.nim",
      LibTestTemplate.replace("@@NAME@@", pkgName))
  of "binary":
    createDir(dir / "src")
    writeExampleIfNonExistent(dir / "src" / (pkgName.addFileExt("nim")),
      BinMainTemplate)
    extras = "bin           = @[\"" & pkgName & "\"]\n"
  of "hybrid":
    createDir(dir / "src" / pkgName)
    writeExampleIfNonExistent(dir / "src" / (pkgName.addFileExt("nim")),
      HybridMainTemplate.replace("@@NAME@@", pkgName))
    writeExampleIfNonExistent(dir / "src" / pkgName / "submodule.nim",
      HybridSubmoduleTemplate.replace("@@NAME@@", pkgName))
    createDir(dir / "tests")
    writeFile(dir / "tests" / "config.nims", TestsConfigContent)
    writeExampleIfNonExistent(dir / "tests" / "test1.nim",
      HybridTestTemplate.replace("@@NAME@@", pkgName))
    extras = "installExt    = @[\"nim\"]\nbin           = @[\"" & pkgName & "\"]\n"
  else:
    assert false, "unreachable"

  let nimbleFile = dir / pkgName.addFileExt("nimble")
  writeFile(nimbleFile, buildNimbleFile(pkgName, version, author, description,
    license, nimDep, extras))

  displaySuccess("Initialized " & pkgType & " package '" & pkgName &
    "' in " & dir)
