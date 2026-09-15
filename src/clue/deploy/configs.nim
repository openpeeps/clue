# Clue - An alternative package manager for Nim development
#
# (c) 2026 George Lemon | MIT License
#          Made by Humans from OpenPeeps
#          https://github.com/openpeeps/clue

## `clue.deploy.yaml` / `clue.deploy.json` configuration for the clue deploy
## system. Parsed into Nim objects via openparser's typed deserializers
## (`fromJson` / `parseYAML`), so both formats share one object graph.

import std/[os, strutils, options, tables]
import pkg/openparser/json
import pkg/openparser/yaml

type
  SystemdConfig* = object
    service*: string
    unitFile*: string
    unitRemotePath*: string
    daemonReload*: Option[bool]
    enable*: bool
    restart*: Option[bool]
    sudo*: Option[bool]
    status*: Option[bool]

  WebProfile* = object
    name*: string
    host*: string
    user*: string
    port*: int
    sshKey*: string
    remoteDir*: string
    exclude*: seq[string]
    delete*: bool
    checksum*: bool
    compress*: Option[bool]
    partial*: Option[bool]
    timeout*: int
    preBuild*: seq[string]
    postDeploy*: seq[string]
    systemd*: SystemdConfig

  WebConfig* = object
    localDir*: string
    profiles*: OrderedTableRef[string, WebProfile]

  DirProfile* = object
    ## A directory placement profile: sync `from` to `to`.
    ## `to` is a local path, unless `host` is set — then it is a remote
    ## path on `user@host` reached over ssh. There is intentionally no
    ## `password` field: when no `sshKey` is configured, clue prompts for
    ## the password at deploy time and keeps it only in process memory.
    name*: string
    `from`*: string
    to*: string
    host*: string
    user*: string
    port*: int
    sshKey*: string
    exclude*: seq[string]
    delete*: bool
    checksum*: bool
    compress*: Option[bool]
    timeout*: int

  DirConfig* = object
    profiles*: OrderedTableRef[string, DirProfile]

  DeployConfig* = object
    path*: string
    project*: string
    `type`*: string
    version*: string
    web*: WebConfig
    dir*: DirConfig

func compressOn*(p: WebProfile): bool = p.compress.get(true)
func partialOn*(p: WebProfile): bool = p.partial.get(true)
func sdDaemonReload*(s: SystemdConfig): bool = s.daemonReload.get(true)
func sdRestart*(s: SystemdConfig): bool = s.restart.get(true)
func sdSudo*(s: SystemdConfig): bool = s.sudo.get(true)
func sdStatus*(s: SystemdConfig): bool = s.status.get(true)

proc expandPath*(s: string): string =
  ## Expand `~` and `$VAR` / `${VAR}` in a config value (e.g. an ssh key path).
  if s.startsWith("~/"):
    result = getHomeDir() & s[2 .. ^1]
  else:
    result = s
  for k, v in envPairs():
    result = result.replace("$" & k, v).replace("${" & k & "}", v)
  return result

proc findDeployConfig*(customPath = ""): string =
  ## Locate the deploy config in the current directory (or `customPath`).
  if customPath.len > 0:
    if not fileExists(customPath):
      raise newException(IOError, "Config file not found: " & customPath)
    return customPath
  for f in ["clue.deploy.yaml", "clue.deploy.yml", "clue.deploy.json"]:
    let p = getCurrentDir() / f
    if fileExists(p):
      return p
  ""

proc parseDeployConfig*(path: string): DeployConfig =
  ## Parse a `clue.deploy.yaml` / `clue.deploy.json` file into a DeployConfig.
  if not fileExists(path):
    raise newException(IOError, "Config file not found: " & path)
  let input = readFile(path)
  case path.splitFile.ext.toLowerAscii
  of ".json":
    result = fromJson(input, DeployConfig)
  of ".yaml", ".yml":
    result = parseYAML(input, DeployConfig)
  else:
    raise newException(IOError,
      "Unsupported config format '" & path.splitFile.ext & "' (use .yaml or .json)")
  result.path = path

  # defaults + profile names
  if result.web.localDir.len == 0:
    result.web.localDir = "dist/web"
  if result.web.profiles != nil:
    for name in keys(result.web.profiles):
      var p = result.web.profiles[name]
      p.name = name
      if p.port <= 0:
        p.port = 22
      if p.timeout <= 0:
        p.timeout = 60
      result.web.profiles[name] = p
  if result.dir.profiles != nil:
    for name in keys(result.dir.profiles):
      var p = result.dir.profiles[name]
      p.name = name
      if p.port <= 0:
        p.port = 22
      if p.timeout <= 0:
        p.timeout = 60
      result.dir.profiles[name] = p
