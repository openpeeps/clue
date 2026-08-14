# Clue - A cool toolkit for Nim developers
#
# (c) 2026 George Lemon | LGPLv3 License
#          Made by Humans from OpenPeeps
#          https://github.com/openpeeps/clue

## `clue.deploy.yaml` / `clue.deploy.json` configuration for the clue deploy
## system. Parsed into Nim objects via openparser's typed deserializers
## (`fromJson` / `parseYAML`), so both formats share one object graph.

import std/[os, strutils, options, tables]
import pkg/openparser/json
import pkg/openparser/yaml

type
  ReleaseTarget* = object
    os*: string
    arch*: string

  ReleaseConfig* = object
    repo*: string
    tagPrefix*: string
    notes*: string
    notesFile*: string
    draft*: bool
    prerelease*: bool
    assets*: seq[string]
    workflow*: string
    targets*: seq[ReleaseTarget]
    artifactName*: string

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

  GithubConfig* = object
    repo*: string

  DeployConfig* = object
    path*: string
    project*: string
    `type`*: string
    version*: string
    github*: GithubConfig
    release*: ReleaseConfig
    web*: WebConfig

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
  if result.release.artifactName.len == 0:
    result.release.artifactName = "{{project}}_{{os}}-{{arch}}"
  if result.web.profiles != nil:
    for name in keys(result.web.profiles):
      var p = result.web.profiles[name]
      p.name = name
      if p.port <= 0:
        p.port = 22
      if p.timeout <= 0:
        p.timeout = 60
      result.web.profiles[name] = p
