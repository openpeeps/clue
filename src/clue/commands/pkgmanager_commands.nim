# Clue - A cool toolkit for Nim developers
#
# (c) 2026 George Lemon | LGPLv3 License
#          Made by Humans from OpenPeeps
#          https://github.com/openpeeps/clue

import std/[sequtils, options, tables, strformat, sets,
          streams, times, strutils, os, osproc, threadpool]

import pkg/[semver, openparser/json]
import pkg/kapsis/[runtime, interactive/prompts]

import ../features/pkgmanager/resolver
import ../features/pkgmanager/configs
import ../features/pkgmanager/nimbleparser

type
  PkgDepInfo = tuple[name: string, constraint: VersionConstraint, refStr: string]
  PkgRef = object
    name: string
    refStr: string  # explicit branch/tag only — "" = default branch
    url: string

proc fetchPkgMeta(pkgName: string): Option[PkgRef] =
  withClueDB do:
    let res = clueDB.getTable("packages")
                      .get()
                      .where("name", newTextValue(pkgName))
                      .toSeq()
    if res.len == 0:
      return none(PkgRef)
    return some(PkgRef(name: pkgName, url: $(res[0][1]["url"]), refStr: ""))
  none(PkgRef)

proc clonePackage*(url, dest: string): bool =
  if dirExists(dest):
    return true
  let cmd = "git clone " & url & " " & dest
  let (output, exitCode) = execCmdEx(cmd)
  if exitCode != 0:
    displayWarning("Failed to clone " & url & ": " & output)
    return false
  discard execCmdEx("git -C " & dest & " fetch --tags --quiet")
  true

proc checkoutTag*(dest, version: string): bool =
  let tags = ["v" & version, version]
  for tag in tags:
    let (output, code) = execCmdEx("git -C " & dest & " checkout " & tag & " --quiet 2>/dev/null")
    if code == 0: return true
  false

proc findLatestTag*(dest: string): string =
  let (output, exitCode) = execCmdEx("git -C " & dest & " tag --list")
  if exitCode != 0: return ""
  var latest: Version
  for line in output.splitLines():
    let tag = line.strip()
    if tag.len == 0: continue
    let verStr = if tag.startsWith("v"): tag[1..^1] else: tag
    try:
      let ver = parseVersion(verStr)
      if latest.major == 0 and latest.minor == 0 and latest.patch == 0 or ver > latest:
        latest = ver
    except:
      discard
  if latest.major == 0 and latest.minor == 0 and latest.patch == 0:
    ""
  else:
    $latest

proc checkGitTag(dest, version: string): bool =
  let p = startProcess("git",
    args = ["-C", dest, "tag", "--list"],
    options = {poUsePath, poStdErrToStdOut})
  let tags = p.outputStream.readAll()
  let exitCode = p.waitForExit()
  p.close()
  if exitCode != 0: return false
  let tagList = tags.splitLines().mapIt(it.strip()).filterIt(it.len > 0)
  result = ("v" & version) in tagList or version in tagList

proc parseDepsFromNimble(pkgName: string, pkgRefs: var Table[string, PkgRef]): tuple[version: string, deps: seq[PkgDepInfo]] =
  let nimbleFilePath = cluePkgsCachePath / pkgName / pkgName.changeFileExt("nimble")
  if not fileExists(nimbleFilePath):
    return ("0.0.0", @[])

  let pkgNimble = parseNimbleFile(nimbleFilePath)
  let pkgVersion = pkgNimble.version

  var deps: seq[PkgDepInfo] = @[]

  for dep in pkgNimble.requires:
    if dep.isNim: continue

    let depName = dep.name
    let depUrl = dep.url
    var constraint = dep.constraint
    var depRef =
      if dep.branch.len > 0: dep.branch
      elif dep.tag.len > 0: dep.tag
      else: ""

    let lookupName =
      if depName.len > 0: depName
      else: depUrl

    if depRef == "head": depRef = ""

    if lookupName notin pkgRefs:
      let metaOpt = fetchPkgMeta(lookupName)
      if metaOpt.isSome:
        var meta = metaOpt.get()
        meta.refStr = depRef
        pkgRefs[lookupName] = meta
      else:
        displayWarning("Unknown package in registry: " & lookupName)

    deps.add((name: lookupName, constraint: constraint, refStr: depRef))

  (pkgVersion, deps)

proc printDepTree(name: string, version: string, deps: seq[PkgDepInfo],
  indent: int = 0,
  isLast: bool = true
) =
  ## Print a single node + its direct deps with tree-style indentation.
  let prefix =
    if indent == 0: ""
    else:
      repeat("│  ", indent - 1) & (if isLast: "└─ " else: "├─ ")
  let versionStr =
    if version != "0.0.0": " v" & version
    else: ""
  echo prefix & name & versionStr

  for i, dep in deps:
    let depIsLast = i == deps.high
    let childPrefix =
      if indent == 0: repeat("│  ", indent) & (if depIsLast: "└─ " else: "├─ ")
      else: repeat("│  ", indent) & (if depIsLast: "└─ " else: "├─ ")
    let constraintStr =
      if dep.refStr.len > 0: " @" & dep.refStr
      else: " " & $dep.constraint
    echo childPrefix & dep.name & constraintStr

proc installPackage*(pkgName: string, pkgRef: string = "") =
  withClueDB do:
    let rootMetaOpt = fetchPkgMeta(pkgName)
    if rootMetaOpt.isNone:
      displayError("Package not found in registry: " & pkgName)
      return

    var pkgRefs: Table[string, PkgRef]
    var rootMeta = rootMetaOpt.get()
    rootMeta.refStr = pkgRef
    pkgRefs[pkgName] = rootMeta

    # Clone root to cache (full repo with all tags)
    let rootDest = cluePkgsCachePath / pkgName
    if not dirExists(rootDest):
      echo "Fetching " & pkgName & "..."
      if not clonePackage(rootMeta.url, rootDest):
        return
    else:
      echo "Using cached " & pkgName

    # Determine target version: specified ref or latest git tag
    let targetRef =
      if pkgRef.len > 0: pkgRef
      else:
        let latest = findLatestTag(rootDest)
        if latest.len > 0: latest
        else: ""
    if targetRef.len > 0:
      if not checkoutTag(rootDest, targetRef):
        displayWarning("Could not checkout " & targetRef & " in " & pkgName)
      else:
        display("  " & cyan(pkgName & "@" & targetRef))

    # bfs wave by wave concurrent cloning
    var registry: PackageRegistry
    var visited: HashSet[string]
    var depTree: Table[string, tuple[version: string, deps: seq[PkgDepInfo]]]
    visited.incl(pkgName)

    let (rootVersion, rootDeps) = parseDepsFromNimble(pkgName, pkgRefs)
    depTree[pkgName] = (rootVersion, rootDeps)
    registry.addPackage(UnresolvedPackage(
      name: pkgName,
      version: parseVersion(rootVersion),
      dependencies: rootDeps.mapIt(Dependency(name: it.name, constraint: it.constraint))
    ))

    var wave: seq[tuple[name: string, refStr: string]] = @[]
    for d in rootDeps:
      if d.name notin visited:
        visited.incl(d.name)
        wave.add((d.name, d.refStr))

    while wave.len > 0:
      displayInfo("Cloning " & $wave.len & " package(s)...")
      var futs: seq[FlowVar[bool]] = @[]
      for w in wave:
        let meta = pkgRefs.getOrDefault(w.name, PkgRef())
        if meta.url.len == 0:
          displayWarning("No URL for " & w.name & ", skipping.")
          futs.add(spawn (proc(): bool = false)())
          continue
        let dest = cluePkgsCachePath / w.name
        if dirExists(dest):
          display("  " & cyan(w.name) & " (cached)")
          futs.add(spawn (proc(): bool = true)())
        else:
          futs.add(spawn clonePackage(meta.url, dest))
          display("  " & cyan(meta.url))
      sync()

      var nextWave: seq[tuple[name: string, refStr: string]] = @[]
      for i, w in wave:
        if not (^futs[i]):
          echo "  skipping deps of " & w.name & " (clone failed)"
          continue

        let dest = cluePkgsCachePath / w.name
        let meta = pkgRefs.getOrDefault(w.name, PkgRef())
        if meta.refStr.len > 0:
          discard checkoutTag(dest, meta.refStr)

        let (ver, deps) = parseDepsFromNimble(w.name, pkgRefs)
        depTree[w.name] = (ver, deps)
        # Register HEAD version
        registry.addPackage(UnresolvedPackage(
          name: w.name,
          version: parseVersion(ver),
          dependencies: deps.mapIt(Dependency(name: it.name, constraint: it.constraint))
        ))
        # Also register all tagged semver versions so the resolver can match constraints
        let (tagOutput, tagCode) = execCmdEx("git -C " & dest & " tag --list")
        if tagCode == 0:
          for tagLine in tagOutput.splitLines():
            let tag = tagLine.strip()
            if tag.len == 0: continue
            let verStr = if tag.startsWith("v"): tag[1..^1] else: tag
            try:
              let tagVer = parseVersion(verStr)
              registry.addPackage(UnresolvedPackage(
                name: w.name,
                version: tagVer,
                dependencies: deps.mapIt(Dependency(name: it.name, constraint: it.constraint))
              ))
            except:
              discard

        for d in deps:
          if d.name notin visited:
            visited.incl(d.name)
            nextWave.add((d.name, d.refStr))

      wave = nextWave

    echo ""
    displayInfo("Dependency tree:")
    proc printTree(name: string, indent: int, isLast: bool) =
      let (ver, deps) = depTree.getOrDefault(name, ("0.0.0", @[]))
      let branch =
        if indent == 0: ""
        else: repeat("│  ", indent - 1) & (if isLast: "└─ " else: "├─ ")
      let vStr = if ver != "0.0.0": " v" & ver else: ""
      echo branch & name & vStr

      for i, dep in deps:
        let childIsLast = i == deps.high
        let constraintStr =
          if dep.refStr.len > 0: " @" & dep.refStr
          else: " " & $dep.constraint
        if dep.name in depTree:
          printTree(dep.name, indent + 1, childIsLast)
        else:
          let childBranch = repeat("│  ", indent) & (if childIsLast: "└─ " else: "├─ ")
          echo childBranch & dep.name & constraintStr

    printTree(pkgName, 0, true)
    echo ""

    # Resolve versions
    let roots = @[Dependency(name: pkgName,
                             constraint: VersionConstraint(kind: vcAny,
                                         version: newVersion(0, 0, 0)))]
    var resolved: seq[ResolvedPackage]
    try:
      resolved = registry.resolve(roots)
    except CircularDependencyError as e:
      displayError("Circular dependency: " & e.msg); return
    except VersionConflictError as e:
      displayError("Version conflict: " & e.msg); return
    except PackageNotFoundError as e:
      displayError("Package not found during resolution: " & e.msg); return

    displayInfo("Resolved " & $resolved.len & " package(s). Verifying git tags...")

    # Concurrently verify git tags
    type TagCheck = tuple[name: string, version: string, dest: string]
    var tagChecks: seq[TagCheck] = @[]
    var tagFuts: seq[FlowVar[bool]] = @[]

    for rp in resolved:
      let meta = pkgRefs.getOrDefault(rp.name, PkgRef())
      if meta.refStr.len == 0 and $rp.version != "0.0.0":
        let dest = cluePkgsCachePath / rp.name
        let ver = $rp.version
        tagChecks.add((rp.name, ver, dest))
        tagFuts.add(spawn checkGitTag(dest, ver))

    sync()
    var tagErrors = false
    for i, tc in tagChecks:
      if not (^tagFuts[i]):
        echo "  no git tag for " & tc.name & " matching v" & tc.version & " or " & tc.version
        tagErrors = true

    if tagErrors:
      displayWarning("Some packages have no matching git tag (cloned at HEAD)")

    # Finalize: checkout version tag in cache, then copy to ~/.clue/packages/<name>/<version>/
    var installedCount = 0
    for rp in resolved:
      let ver = $rp.version
      if ver == "0.0.0": continue
      let cacheDir = cluePkgsCachePath / rp.name
      if not dirExists(cacheDir):
        displayWarning("Cache missing for " & rp.name & ", skipping install")
        continue
      let verDir = cluePkgsPath / rp.name / ver
      if dirExists(verDir):
        display("  " & cyan(rp.name) & " v" & ver & " (already installed)")
        installedCount.inc
        continue
      # Checkout the resolved version tag
      let meta = pkgRefs.getOrDefault(rp.name, PkgRef())
      if meta.refStr.len == 0 and ver != "0.0.0":
        if not checkoutTag(cacheDir, ver):
          displayWarning("Could not checkout v" & ver & " for " & rp.name & ", installing from HEAD")
      try:
        createDir(verDir)
        copyDir(cacheDir, verDir)
        removeDir(verDir / ".git")
        installedCount.inc
        displaySuccess("Installed " & rp.name & " v" & ver)
      except:
        displayWarning("Failed to install " & rp.name & " v" & ver)

    if installedCount > 0:
      displaySuccess("Installed " & $installedCount & " package(s) to " & cluePkgsPath)

proc installCommand*(v: Values) =
  let pkgInput = split(v.get("pkg").getStr, "@")
  let pkgName = pkgInput[0]
  let pkgRef = if pkgInput.len > 1 and pkgInput[1] != "head": pkgInput[1] else: ""
  installPackage(pkgName, pkgRef)

template whenPackageExists(pkgName: string, body: untyped): untyped =
  let pkgBase = cluePkgsPath / pkgName
  var found = false
  if dirExists(pkgBase):
    for entry in walkDir(pkgBase):
      if entry.kind == pcDir:
        found = true
        break
  if found:
    let res = clueDB.getTable("packages")
                      .get()
                      .where("name", newTextValue(pkgName))
                      .toSeq()
    if res.len == 0:
      displayError("Package not found: " & pkgName)
      return
    block:
      `body`
  else:
    displayError("Package not found: " & cyan(pkgName))

proc uninstallCommand*(v: Values) =
  withClueDB do:
    let pkgInput = split(v.get("pkg").getStr, "@")
    let pkgName = pkgInput[0]
    let pkgVersion = if pkgInput.len > 1: pkgInput[1] else: ""
    if pkgVersion.len > 0:
      let verDir = cluePkgsPath / pkgName / pkgVersion
      if dirExists(verDir):
        if promptConfirm("Remove " & pkgName & "@" & pkgVersion & "?"):
          removeDir(verDir)
          displaySuccess("Removed " & pkgName & "@" & pkgVersion)
        else:
          displayInfo("Removal cancelled.")
      else:
        displayError("Version not installed: " & pkgName & "@" & pkgVersion)
    else:
      whenPackageExists pkgName:
        if promptConfirm("Remove all versions of " & cyan(pkgName) & "?"):
          removeDir(cluePkgsPath / pkgName)
          displaySuccess("All versions of " & pkgName & " removed")
        else:
          displayInfo("Uninstallation cancelled.")

proc dumpCommand*(v: Values) =
  ## Dump package info from registry
  withClueDB do:
    let pkgName = v.get("pkg").getStr
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
        display(pretty(pkgInfo))

# proc searchCommand*(v: Values) =
#   ## Search command to find packages by name or tags
#   withClueDB do:
#     let query = v.get("query").getStr
#     let res = clueDB.getTable("packages")
#                       .get()
#                       .where("name", newTextValue(query), opContains)
#                       .orWhere("tags", newTextValue(query), opContains)
#                       .toSeq()
#     if res.len == 0:
#       displayInfo("No packages found matching: " & query)
#       return


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
  echo result.versions

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
    displayError("Please specify a Nim version: --nim:<version>")
    return

  # Check choosenim availability and installed versions
  let choosenimInfoOpt = getChoosenimInfo()
  if choosenimInfoOpt.isNone:
    displayError("`choosenim` is not installed or not available in PATH.")
    return

  let choosenimInfo = choosenimInfoOpt.get()

  # Validate requested version is installed
  if requestedVersion notin choosenimInfo.versions:
    displayError("Nim version " & cyan(requestedVersion) & " is not installed.")
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
    displayError("Toolchain path not found: " & nimVersionPath)
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