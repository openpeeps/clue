# Clue - A cool toolkit for Nim developers
#
# (c) 2026 George Lemon | LGPLv3 License
#          Made by Humans from OpenPeeps
#          https://github.com/openpeeps/clue

import std/[os, osproc, json]
import pkg/kapsis/runtime
import pkg/kapsis/interactive/prompts

proc docsGenCommand*(v: Values) =
  ## Kapsis command for deploying a project to a hosting platform
  let pkgName = v.get("pkgname").getIdent
  # we'll execute nimble dump to get the path of the package
  let nimbleOutput = execCmdEx("nimble dump " & pkgName & " --json")
  if nimbleOutput.exitCode != 0:
    displayError("Nimble dump failed with\n" & nimbleOutput.output, quitProcess = true)
  let nimbleJson: JsonNode = parseJson(nimbleOutput.output)
  echo nimbleJson

proc docsOpenCommand*(v: Values) =
  ## Kapsis command for deploying a project to a hosting platform
  discard