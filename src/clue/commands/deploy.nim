# Clue - A cool toolkit for Nim developers
#
# (c) 2026 George Lemon | LGPLv3 License
#          Made by Humans from OpenPeeps
#          https://github.com/openpeeps/clue

import pkg/kapsis/runtime
import pkg/kapsis/interactive/prompts

import ../deploy/[configs, init, web]

proc deployInitCommand*(v: Values) =
  let deployType =
    if v.has("--type"): v.get("--type").getStr
    else: "cli"
  let writeWorkflow = v.has("--workflow")
  let yes = v.has("--yes")
  let force = v.has("--force")
  initDeploy(deployType, writeWorkflow, yes, force)

proc deployWebCommand*(v: Values) =
  let configPath =
    if v.has("--config"): v.get("--config").getStr
    else: ""
  let profileName =
    if v.has("--profile"): v.get("--profile").getStr
    else: "production"
  let keyOverride =
    if v.has("--key"): v.get("--key").getStr
    else: ""
  let dryRun = v.has("--dry-run")
  let yes = v.has("--yes")
  let verbose = v.has("--verbose")
  let statusOnly = v.has("--status")

  var path = ""
  try:
    path = findDeployConfig(configPath)
  except CatchableError as e:
    displayError(e.msg)
    return
  if path.len == 0:
    displayError("No clue.deploy.yaml / clue.deploy.json found. Run `clue deploy.init` first.")
    return

  var cfg: DeployConfig
  try:
    cfg = parseDeployConfig(path)
  except CatchableError as e:
    displayError("Failed to parse " & path & ": " & e.msg)
    return

  let code = deployWeb(cfg, profileName, keyOverride, dryRun, yes, verbose, statusOnly)
  if code != 0:
    quit(code)
