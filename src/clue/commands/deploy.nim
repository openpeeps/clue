# Clue - An alternative package manager for Nim development
#
# (c) 2026 George Lemon | MIT License
#          Made by Humans from OpenPeeps
#          https://github.com/openpeeps/clue

import pkg/kapsis/runtime
import pkg/kapsis/interactive/prompts

import ../deploy/[configs, dir, init, web]

proc loadDeployConfig(configPath: string): tuple[cfg: DeployConfig, ok: bool] =
  ## Locate and parse the deploy config. Quits the process on any failure.
  var path = ""
  try:
    path = findDeployConfig(configPath)
  except CatchableError as e:
    displayError(e.msg, quitProcess = true)
    return (DeployConfig(), false)
  if path.len == 0:
    displayError("No clue.deploy.yaml / clue.deploy.json found. Run `clue deploy.init` first.", quitProcess = true)
    return (DeployConfig(), false)
  try:
    (parseDeployConfig(path), true)
  except CatchableError as e:
    displayError("Failed to parse " & path & ": " & e.msg, quitProcess = true)
    (DeployConfig(), false)

proc deployFlags(v: Values): tuple[configPath, profileName, keyOverride: string,
    dryRun, yes, verbose: bool] =
  let configPath =
    if v.has("--config"): v.get("--config").getStr
    else: ""
  let profileName =
    if v.has("--profile"): v.get("--profile").getStr
    else: "production"
  let keyOverride =
    if v.has("--key"): v.get("--key").getStr
    else: ""
  (configPath, profileName, keyOverride,
    v.has("--dry-run"), v.has("--yes"), v.has("--verbose"))

proc deployInitCommand*(v: Values) =
  let deployType =
    if v.has("--type"): v.get("--type").getStr
    else: "cli"
  let writeWorkflow = v.has("--workflow")
  let yes = v.has("--yes")
  let force = v.has("--force")
  initDeploy(deployType, writeWorkflow, yes, force)

proc deployDirCommand*(v: Values) =
  let (configPath, profileName, keyOverride, dryRun, yes, verbose) = deployFlags(v)
  let (cfg, ok) = loadDeployConfig(configPath)
  if not ok:
    return
  let code = deployDir(cfg, profileName, keyOverride, dryRun, yes, verbose)
  if code != 0:
    quit(code)

proc deployWebCommand*(v: Values) =
  let (configPath, profileName, keyOverride, dryRun, yes, verbose) = deployFlags(v)
  let statusOnly = v.has("--status")
  let (cfg, ok) = loadDeployConfig(configPath)
  if not ok:
    return
  let code = deployWeb(cfg, profileName, keyOverride, dryRun, yes, verbose, statusOnly)
  if code != 0:
    quit(code)
