# Clue - An alternative package manager for Nim development
#
# (c) 2026 George Lemon | MIT License
#          Made by Humans from OpenPeeps
#          https://github.com/openpeeps/clue

import std/[sequtils, options, tables, sets, strformat, strutils,
          times, os, osproc, terminal, strtabs, algorithm]

import pkg/[semver, openparser/json]
import pkg/kapsis/[runtime, interactive/prompts]
import pkg/malebolgia

import ../pkgmanager/resolver
import ../pkgmanager/configs
import ../pkgmanager/versions
import ../pkgmanager/nimbleparser
import ../pkgmanager/builder
import ./nimscript
import datpkgr/operations as datpkgrOps
import datpkgr/config as datpkgrConfig
import datpkgr/types as datpkgrTypes

proc pkgNameFromUrl*(url: string): string =
  ## Derive a package name from a git URL's repository basename.
  var u = url.strip()
  for sep in ['#', '?']:
    let pos = u.find(sep)
    if pos >= 0:
      u = u[0 ..< pos]
  if u.startsWith("git+"):
    u = u[4 .. ^1]
  u = u.replace("://", "/")
  u = u.replace("git@", "")
  u = u.replace(":", "/")
  for part in u.split('/'):
    if part.len > 0:
      result = part
  if result.endsWith(".git"):
    result = result[0 ..< ^4]

proc depName(d: NimbleDependency): string =
  ## The registry name for a dependency. URL deps (no name, only a `url`) are
  ## resolved to their repository basename so the registry can be consulted.
  if d.name.len > 0: d.name
  elif d.url.len > 0: pkgNameFromUrl(d.url)
  else: ""

proc depName(d: PkgDependency): string =
  if d.name.len > 0: d.name
  elif d.url.len > 0: pkgNameFromUrl(d.url)
  else: ""

proc parseFeatureFlags*(s: string): seq[string] =
  for f in s.split(','):
    let ff = f.strip()
    if ff.len > 0:
      result.add(ff)

proc isGitUrl*(s: string): bool =
  s.startsWith("https://") or s.startsWith("http://") or
  s.startsWith("git@") or s.startsWith("git+") or
  s.startsWith("ssh://")

proc pluralize*(n: int, singular: string): string =
  ## `pluralize(1, "version")` → "version"; `pluralize(2, "version")` → "versions".
  singular & (if n == 1: "" else: "s")

proc fetchEventText(name: string, count: int, cached: bool): string =
  ## Live event text for version discovery of `name`: `<name> (cached)` on a
  ## cache hit, `<name> using HEAD` when the repo has no semver tags, otherwise
  ## `<name> (N version(s))`.
  if cached:
    result = name & " (cached)"
  elif count == 0:
    result = "fetched " & name & " using HEAD"
  else:
    result = "fetched " & name & " (" & $count & " " & pluralize(count, "version") & ")"

proc installPackage*(pkgName: string, pkgRef: string = "", refresh = false,
    features: seq[string] = @[], verbose = true, url = "",
    doBuild = false, buildRelease = true, buildDebug = false,
    constraint: VersionConstraint = VersionConstraint(kind: vcAny, version: newVersion(0, 0, 0)),
    backend = "c", sourceFilter: string = "", suppressSummary = false) =
  ## Thin wrapper around datpkgr/operations.installPackage.
  ## Builder (`builder.nim`) stays in clue and is injected via buildHook.
  let cfg = getClueCfg()
  devShadowWarningsEnabled = verbose
  let buildHook =
    if doBuild:
      proc(pkgName2: string, preferRef: string, backend2: string): bool =
        buildInstalled(pkgName2, buildRelease, buildDebug, verbose,
          preferRef = preferRef, nimFlags = extras, backend = backend2)
    else: nil
  let ok = datpkgrOps.installPackage(cfg, pkgName, pkgRef, refresh, features, verbose, url,
    doBuild, buildRelease, buildDebug, constraint, backend, sourceFilter, buildHook, suppressSummary)
  if not ok:
    # datpkgr already logged; keep CLI exit semantics (original called quit(1) on fail)
    quit(1)

proc installCommand*(v: Values) =
  let raw = if v.has("pkg"): v.get("pkg").getStr else: ""
  let refresh = v.has("--refresh")
  let verbose = v.has("--verbose")
  devShadowWarningsEnabled = verbose
  let doBuild = v.has("--build")
  let buildDebug = v.has("--debug")
  let buildRelease = not buildDebug
  let backend = if v.has("-b"): v.get("-b").getAny else: "c"
  let sourceFilter = if v.has("--source"): v.get("--source").getStr else: ""
  var features: seq[string]
  if v.has("--features"):
    features = parseFeatureFlags(v.get("--features").getStr)

  if raw.len == 0:
    # Local install: copy the current nimble package into the registry
    # (~/.clue/packages/<name>/<version>) with a clean, nimble-style layout.
    # Dependencies are installed too (like `clue install <pkg>`), so a
    # subsequent `clue test`/`clue build` finds the whole closure already
    # present instead of fetching it on the fly.
    let nimblePath = findNimbleFile(getCurrentDir())
    if nimblePath.len == 0:
      displayError("No .nimble file found in " & getCurrentDir(), quitProcess = true)
      return

    # Before install hook
    discard runNimscriptHook(nimblePath, "install", before=true)

    let nimble = parseNimbleFile(nimblePath)
    let pkgName = nimblePath.extractFilename.changeFileExt("")

    checkNimConstraint(nimble)

    let version = if nimble.version.len > 0: nimble.version else: "0.0.0"
    let verDir = cluePkgsPath / pkgName / version
    safeRemoveDir(verDir)
    nimbleparser.installCleanCopy(getCurrentDir(), verDir, nimble)
    var deps: seq[DepEntry]
    for d in nimble.requires:
      if d.isNim: continue
      deps.add((depName(d), ""))
    recordInstall(pkgName, version, deps, root = true,
      features = @[], installPath = verDir)
    displaySuccess("Installed " & pkgName & "@" & version & " to " & verDir)
    var localDepLabels: seq[string]
    var localSeen = initHashSet[string]()
    for d in nimble.requires:
      if d.isNim: continue
      let dep = depName(d)
      if dep.len == 0:
        displayWarning("cannot derive package name from URL: " & d.url & " - skipping")
        continue
      let refStr = if d.branch.len > 0: d.branch elif d.tag.len > 0: d.tag else: ""
      installPackage(dep, refStr, false, d.features, verbose, constraint = d.constraint, url = d.url, suppressSummary = true)
      # collect installed dep for aggregated success (dedup) - use #HEAD when version missing
      proc fmtLbl(name, ver: string): string =
        if ver.len == 0 or ver == "0.0.0" or ver == name:
          return name & "#HEAD"
        try:
          discard parseVersion(ver)
          return name & "@" & ver
        except CatchableError:
          return name & "#HEAD"
      let depPath = resolveInstalledPath(dep, refStr)
      let verLabel = if depPath.len > 0: depPath.lastPathPart else: refStr
      let lbl = fmtLbl(dep, verLabel)
      if lbl notin localSeen:
        localSeen.incl(lbl)
        localDepLabels.add(lbl)
      for tdep in collectInstalledDepNames(@[dep]):
        if tdep notin localSeen:
          let tp = resolveInstalledPath(tdep, "")
          let tv = if tp.len > 0: tp.lastPathPart else: ""
          let tlbl = fmtLbl(tdep, tv)
          if tlbl notin localSeen:
            localSeen.incl(tlbl)
            localDepLabels.add(tlbl)
    if localDepLabels.len > 0:
      # dedup already done; sort for stable output
      localDepLabels.sort()
      displaySuccess("Installed " & $localDepLabels.len & " " & pluralize(localDepLabels.len, "package"))
      for lbl in localDepLabels:
        let msg = "  " & lbl
        let headIdx = msg.find("#HEAD")
        if headIdx >= 0:
          let prefix = msg[0 ..< headIdx]
          let suffix = if headIdx + 5 < msg.len: msg[headIdx + 5 .. ^1] else: ""
          display(@[span(prefix, DefaultTextFg, indentSize = 0),
                    span("#HEAD", fgYellow, indentSize = 0),
                    span(suffix, DefaultTextFg, indentSize = 0)])
        else:
          let atIdx = msg.find("@")
          if atIdx >= 0:
            let prefix = msg[0 .. atIdx]
            let verPart = if atIdx + 1 < msg.len: msg[atIdx+1 .. ^1] else: ""
            display(@[span(prefix, DefaultTextFg, indentSize = 0),
                      span(verPart, indentSize = 0)])
          else:
            display(msg)
    if doBuild:
      if not buildInstalled(pkgName, buildRelease, buildDebug, verbose,
          nimFlags = extras, backend = backend):
        return

    # After install hook
    discard runNimscriptHook(nimblePath, "install", before=false)
    return

  if isGitUrl(raw):
    # `https://host/owner/repo[#ref]` installs straight from git.
    # cloneRepo will try SSH first (for private repos) then fall back to HTTPS.
    var url = raw
    var urlRef = ""
    let hashPos = url.find('#')
    if hashPos >= 0:
      urlRef = url[hashPos + 1 .. ^1]
      url = url[0 ..< hashPos]
    let name = pkgNameFromUrl(url)
    if name.len == 0:
      displayError("Could not derive a package name from: " & raw, quitProcess = true)
      return
    installPackage(name, urlRef, refresh, features, verbose, url = url,
      doBuild = doBuild, buildRelease = buildRelease, buildDebug = buildDebug,
      backend = backend, sourceFilter = sourceFilter)
  else:
    let pkgInput = split(raw, "@")
    let pkgName = pkgInput[0]
    let pkgRef = if pkgInput.len > 1 and pkgInput[1] != "head": pkgInput[1] else: ""
    installPackage(pkgName, pkgRef, refresh, features, verbose,
      doBuild = doBuild, buildRelease = buildRelease, buildDebug = buildDebug,
      backend = backend, sourceFilter = sourceFilter)
  # except CatchableError as e:
  #   echo "EXCEPTION in installCommand: ", e.msg
  #   echo getStackTrace(e)
  #   quit(1)

proc updateCommand*(v: Values) =
  ## Wrapper around datpkgr/operations.updateAllPackages / updatePackage.
  ## Parallelism (malebolgia) lives in datpkgr/operations (kept as subprocess model).
  let verbose = v.has("--verbose")
  let cfg = getClueCfg()
  if v.has("pkg"):
    let ok = datpkgrOps.updatePackage(cfg, v.get("pkg").getStr, verbose)
    if not ok: quit(1)
  else:
    let exe = getAppFilename()
    let ok = datpkgrOps.updateAllPackages(cfg, verbose, exe)
    if not ok: quit(1)

proc developCommand*(v: Values) =
  ## Thin wrapper around datpkgr/operations.developPackage (generic Manifest).
  let cfg = getClueCfg()
  let dir = getCurrentDir()
  let ok = datpkgrOps.developPackage(cfg, dir)
  if not ok:
    quit(1)
  # ops logs via cfg.logInfo (plain); emit styled success for CLI consistency
  # (avoid double-line by not re-logging generic message – only styled)
  discard

proc versionsCommand*(v: Values) =
  ## Wrapper around datpkgr/operations.versionsFor
  let pkgName = v.get("pkg").getStr
  let cfg = getClueCfg()
  let versions = datpkgrOps.versionsFor(cfg, pkgName, v.has("--refresh"))
  if versions.len == 0:
    # versionsFor already logged if not found; check if we need extra message
    let metaOpt = fetchPkgMeta(pkgName)
    if metaOpt.isNone:
      displayError("Package not found in registry: " & pkgName, quitProcess = true)
      return
    displayInfo("No semver tags found for " & pkgName)
    return
  displayInfo("Available versions for " & pkgName & ":")
  for ver in versions:
    echo "  " & $ver.version

proc pruneCommand*(v: Values) =
  ## Wrapper around datpkgr/operations.prunePackages
  datpkgrOps.prunePackages(getClueCfg())

proc fetchCommand*(v: Values) =
  ## Wrapper around datpkgr/operations.fetchRegistry
  if not datpkgrOps.fetchRegistry(getClueCfg()):
    quit(1)

template whenPackageExists(pkgName: string, body: untyped): untyped =
  let pkgBase = cluePkgsPath / pkgName
  var hasInstalled = false
  if dirExists(pkgBase):
    for entry in walkDir(pkgBase):
      if entry.kind == pcDir:
        hasInstalled = true
        break
  if not hasInstalled:
    hasInstalled = resolveInstalledPath(pkgName, "").len > 0
  let hasRegistry = clueDB.getTable("packages")
                        .get()
                        .where("name", newTextValue(pkgName))
                        .toSeq()
                        .len > 0
  if hasInstalled or hasRegistry:
    block:
      `body`
  else:
    displayError("Package not found: " & cyan(pkgName), quitProcess = true)

proc uninstallCommand*(v: Values) =
  let pkgInput = split(v.get("pkg").getStr, "@")
  let pkgName = pkgInput[0]
  let pkgVersion = if pkgInput.len > 1: pkgInput[1] else: ""
  let cfg = getClueCfg()
  proc confirm(msg: string): bool =
    promptConfirm(msg)
  let ok = datpkgrOps.uninstallPackage(cfg, pkgName, pkgVersion, confirm)
  if not ok:
    quit(1)

proc renderDepSpec(d: NimbleDependency): string =
  ## `"name >= 1.2.3"` — or just the name when the constraint is any (`*`).
  let c = $d.constraint
  if c == "*": d.name else: d.name & " " & c

proc buildLocalNimbleInfo(nimblePath: string): JsonNode =
  ## JSON details parsed from a .nimble file (used by both dump modes).
  let nimble = parseNimbleFile(nimblePath)
  result = %*{
    "name": nimblePath.extractFilename.changeFileExt(""),
    "version": nimble.version,
    "author": nimble.author,
    "description": nimble.description,
    "license": nimble.license,
    "srcDir": nimble.srcDir,
    "binDir": nimble.binDir,
    "bin": %nimble.bin,
    "installDirs": %nimble.installDirs,
    "installFiles": %nimble.installFiles,
    "installExt": %nimble.installExt,
    "skipDirs": %nimble.skipDirs,
    "skipFiles": %nimble.skipFiles,
    "skipExt": %nimble.skipExt,
  }
  var reqArr = newJArray()
  for dep in nimble.requires:
    reqArr.add(%renderDepSpec(dep))
  result["requires"] = reqArr
  var tasksArr = newJArray()
  for (tname, tdesc) in nimble.tasks:
    tasksArr.add(%{"name": %tname, "description": %tdesc})
  result["tasks"] = tasksArr

proc dumpCommand*(v: Values) =
  ## Dump package info from the registry, its available versions and recent
  ## git activity (latest commit hash/date/author) — `--refresh` re-reads
  ## versions from the remote instead of the local cache.
  ## With no argument, dumps the current directory's .nimble file.
  let pkgName =
    if v.has("pkg"): v.get("pkg").getStr
    else: ""
  if pkgName.len == 0:
    # Local dump: parse the .nimble file in the current directory.
    let nimblePath = findNimbleFile(getCurrentDir())
    if nimblePath.len == 0:
      displayError("No .nimble file found in " & getCurrentDir(), quitProcess = true)
      return
    echo pretty(buildLocalNimbleInfo(nimblePath))
    return

  # Registry dump.
  withClueDB do:
    whenPackageExists pkgName:
      let res = clueDB.getTable("packages")
                        .get()
                        .where("name", newTextValue(pkgName))
                        .toSeq()
      if res.len > 0:
        var pkgData = res[0]
        var pkgInfo = %*{
          "method": pkgData[1]["method"].strVal,
          "name": pkgData[1]["name"].strVal,
          "url": pkgData[1]["url"].strVal,
          "description": pkgData[1]["description"].strVal,
          "web": pkgData[1]["web"].strVal,
          "license": pkgData[1]["license"].strVal,
          "tags": fromJson(pkgData[1]["tags"].jsonVal)
        }
        # available versions (newest first)
        let versions = discoverVersions(pkgName, pkgData[1]["url"].strVal,
          v.has("--refresh"), cloneOnMiss = false)
        var verArr = newJArray()
        for dv in versions:
          verArr.add(%($dv.version))
        pkgInfo["versions"] = verArr
        # Embed the dumped package's own .nimble details (from its installed
        # registry copy) when available.
        let pkgDir = resolveInstalledPath(pkgName, "")
        if pkgDir.len > 0:
          let pkgNimble = findNimbleFile(pkgDir)
          if pkgNimble.len > 0:
            pkgInfo["nimble"] = buildLocalNimbleInfo(pkgNimble)
        echo pretty(pkgInfo)
      else:
        # installed-only (e.g. direct URL before packages row existed) — dump from installed
        let pkgDir = resolveInstalledPath(pkgName, "")
        if pkgDir.len > 0:
          let pkgNimble = findNimbleFile(pkgDir)
          var pkgInfo: JsonNode
          if pkgNimble.len > 0:
            pkgInfo = buildLocalNimbleInfo(pkgNimble)
            pkgInfo["installedAt"] = %pkgDir
          else:
            pkgInfo = %*{"name": pkgName, "installedAt": pkgDir}
          echo pretty(pkgInfo)
        else:
          displayError("Package not found: " & cyan(pkgName), quitProcess = true)


type
  ChoosenimInfo = object
    selected: string
    channel: string
    path: string
    versions: seq[string]

proc stripAnsi(s: string): string =
  ## Remove common ANSI escape sequences (SGR / CSI sequences like "\x1b[...m")
  result = ""
  var i = 0
  while i < s.len:
    let c = s[i]
    if c == '\x1b': # escape char
      inc(i)
      if i < s.len and s[i] == '[':
        inc(i)
        # skip until final byte (usually a letter like 'm')
        while i < s.len and not (s[i].isAlphaAscii):
          inc(i)
        if i < s.len:
          inc(i)
      else:
        # skip single-char escape if present
        if i < s.len: inc(i)
      continue
    else:
      result = result & $c
      inc(i)

proc parseChoosenimShow(output: string): ChoosenimInfo =
  # Parse the output of `choosenim show`
  result = ChoosenimInfo()
  for line in output.splitLines():
    let trimmed = stripAnsi(line).strip()
    if trimmed.startsWith("Selected:"):
      result.selected = trimmed.replace("Selected:", "").strip()
    elif trimmed.startsWith("Channel:"):
      result.channel = trimmed.replace("Channel:", "").strip()
    elif trimmed.startsWith("Path:"):
      result.path = trimmed.replace("Path:", "").strip()
    elif trimmed.len > 0 and not trimmed.startsWith("Versions:"):
      # Version lines may start with `*` (active) or spaces
      let v = trimmed.replace("*", "").strip()
      if v.len > 0:
        result.versions.add(v)

proc getChoosenimInfo(): Option[ChoosenimInfo] =
  # Run `choosenim show` and parse the output
  let (output, exitCode) = execCmdEx("choosenim show")
  if exitCode != 0:
    return none(ChoosenimInfo)
  some(parseChoosenimShow(output))

proc getNimVersionPath(choosenimHome: string, version: string): string =
  ## Resolve the absolute path to a specific Nim version toolchain
  choosenimHome / "toolchains" / ("nim-" & version)

proc venvCommand*(v: Values) =
  ## Create a virtual environment for a Nim package
  let requestedVersion = v.get("--nim").getStr
  if requestedVersion.len == 0:
    displayError("Please specify a Nim version: --nim:<version>", quitProcess = true)
    return

  # Check choosenim availability and installed versions
  let choosenimInfoOpt = getChoosenimInfo()
  if choosenimInfoOpt.isNone:
    displayError("`choosenim` is not installed or not available in PATH.", quitProcess = true)
    return

  let choosenimInfo = choosenimInfoOpt.get()

  # Validate requested version is installed
  if requestedVersion notin choosenimInfo.versions:
    displayError("Nim version " & cyan(requestedVersion) & " is not installed.", quitProcess = true)
    displayInfo("Installed versions: " & choosenimInfo.versions.join(", "))
    displayInfo("Install it with: choosenim " & requestedVersion)
    return

  # Resolve the choosenim home directory
  let choosenimHome =
    if choosenimInfo.path.len > 0:
      # e.g. /Users/user/.choosenim/toolchains/nim-2.2.0 -> /Users/user/.choosenim
      choosenimInfo.path.parentDir().parentDir()
    else:
      getHomeDir() / ".choosenim"

  let nimVersionPath = getNimVersionPath(choosenimHome, requestedVersion)
  if not dirExists(nimVersionPath):
    displayError("Toolchain path not found: " & nimVersionPath, quitProcess = true)
    displayInfo("Try reinstalling with: choosenim " & requestedVersion)
    return

  let nimBinPath = nimVersionPath / "bin"
  let currentDir = getCurrentDir()
  let venvDir = currentDir / ".env"
  let configFile = venvDir / "venv.json"

  # Create venv directory
  if dirExists(venvDir):
    displayInfo("Virtual environment already exists at: " & cyan(venvDir))
    let overwrite = promptConfirm("Overwrite existing virtual environment?")
    if not overwrite:
      return
  else:
    createDir(venvDir)

  # Build venv config
  let pkgName = currentDir.lastPathPart()
  let nimblePkgsPath = venvDir / "pkgs"
  discard existsOrCreateDir(nimblePkgsPath)

  let config = %*{
    "nim_version": requestedVersion,
    "nim_path": nimVersionPath,
    "nim_bin": nimBinPath,
    "package": pkgName,
    "created_at": $now(),
    "paths": {
      "venv": venvDir,
      "pkgs": nimblePkgsPath
    },
    "env": {
      "PATH": nimBinPath & ":" & getEnv("PATH"),
      "NIMBLE_DIR": nimblePkgsPath
    }
  }

  writeFile(configFile, pretty(config))

  # Write the activation and deactivation scripts
  let activateScript = venvDir / "activate"
  let deactivateScript = venvDir / "deactivate"
  let activateContents = """
#!/bin/sh
# Nimbox virtual environment activation script
# Generated by clue venv

TARGET_VENV="__VENVDIR__"

# If this venv is already active in this shell, do nothing.
if [ "$CLUE_VENV" = "$TARGET_VENV" ]; then
  echo "Nimbox venv already activated: $TARGET_VENV"
  return 0
fi

CLUE_VENV="$TARGET_VENV"
export CLUE_VENV

# Save previous environment only if not already saved (prevents double-save)
if [ -z "$_CLUE_OLD_PATH" ]; then
  export _CLUE_OLD_PATH="$PATH"
fi
if [ -z "$_CLUE_OLD_NIMBLE_DIR" ]; then
  export _CLUE_OLD_NIMBLE_DIR="$NIMBLE_DIR"
fi

# Prompt customization: prefer env var, then .clue_prompt file, then default
if [ -z "$CLUE_PROMPT" ]; then
  if [ -f "$CLUE_VENV/.clue_prompt" ]; then
    CLUE_PROMPT="$(cat "$CLUE_VENV/.clue_prompt")"
  else
    CLUE_PROMPT="➜ __PKG__"
  fi
fi
export CLUE_PROMPT

# Save and set shell prompt for zsh/bash (falls back to PS1); only save once
if [ -n "$ZSH_VERSION" ]; then
  if [ -z "$_CLUE_OLD_PROMPT" ]; then
    export _CLUE_OLD_PROMPT="$PROMPT"
    PROMPT="$CLUE_PROMPT $PROMPT"
  fi
elif [ -n "$BASH_VERSION" ]; then
  if [ -z "$_CLUE_OLD_PS1" ]; then
    export _CLUE_OLD_PS1="$PS1"
    PS1="$CLUE_PROMPT $PS1"
  fi
else
  if [ -z "$_CLUE_OLD_PS1" ]; then
    export _CLUE_OLD_PS1="$PS1"
    PS1="$CLUE_PROMPT $PS1"
  fi
fi

# Set venv-specific vars
export CLUE_dir="$CLUE_VENV/pkgs"
export NIMBLE_DIR="$CLUE_VENV/pkgs"
export PATH="__NIMBIN__:$PATH"

echo "Nimbox venv activated (Nim __VERSION__)"
echo "  Nim bin : __NIMBIN__"
echo "  Pkgs dir: $NIMBLE_DIR"
echo ""
echo "To switch back, run:"
echo "  source .env/deactivate"
"""

  let deactivateContents = """
#!/bin/sh
# Nimbox virtual environment deactivation script
# Generated by clue venv

TARGET_VENV="__VENVDIR__"

# If this venv is not active in this shell, do nothing.
if [ -z "$CLUE_VENV" ] || [ "$CLUE_VENV" != "$TARGET_VENV" ]; then
  echo "Nimbox venv not active for this directory: $TARGET_VENV"
  return 0
fi

# Restore previous PATH if present
if [ -n "$_CLUE_OLD_PATH" ]; then
  export PATH="$_CLUE_OLD_PATH"
  unset _CLUE_OLD_PATH
fi

# Restore previous NIMBLE_DIR or unset
if [ -n "$_CLUE_OLD_NIMBLE_DIR" ]; then
  export NIMBLE_DIR="$_CLUE_OLD_NIMBLE_DIR"
  unset _CLUE_OLD_NIMBLE_DIR
else
  unset NIMBLE_DIR
fi

# Restore prompt
if [ -n "$ZSH_VERSION" ]; then
  if [ -n "$_CLUE_OLD_PROMPT" ]; then
    PROMPT="$_CLUE_OLD_PROMPT"
    unset _CLUE_OLD_PROMPT
  fi
elif [ -n "$BASH_VERSION" ]; then
  if [ -n "$_CLUE_OLD_PS1" ]; then
    PS1="$_CLUE_OLD_PS1"
    unset _CLUE_OLD_PS1
  fi
else
  if [ -n "$_CLUE_OLD_PS1" ]; then
    PS1="$_CLUE_OLD_PS1"
    unset _CLUE_OLD_PS1
  fi
fi

unset CLUE_VENV
unset CLUE_PROMPT

echo "Nimbox venv deactivated"
"""

  # write activation/deactivation with embedded absolute venv path
  writeFile(activateScript,
    activateContents.replace("__NIMBIN__", nimBinPath)
                    .replace("__VERSION__", requestedVersion)
                    .replace("__PKG__", pkgName)
                    .replace("__VENVDIR__", venvDir))
  writeFile(deactivateScript, deactivateContents.replace("__VENVDIR__", venvDir))


  # write default per-venv prompt file (user can edit or set CLUE_PROMPT env var)
  let promptFile = venvDir / ".clue_prompt"
  if not fileExists(promptFile):
    writeFile(promptFile, "🜲 v" & requestedVersion)

  discard execCmdEx("chmod +x " & activateScript & " && chmod +x " & deactivateScript)

  displaySuccess("Virtual environment created at: " & cyan(venvDir))
  let outputMessage = fmt"""

To activate:
  `source .env/activate`

To deactivate (in the same shell), run:
  `source .env/deactivate`

Customize the prompt:
  - Edit .env/.clue_prompt to change the prefix (or set CLUE_PROMPT).
  - Activation will prepend that prefix to your current zsh/bash prompt.
"""
  displayInfo(outputMessage)
