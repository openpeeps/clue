# Clue - A cool toolkit for Nim developers
#
# (c) 2026 George Lemon | MIT License
#          Made by Humans from OpenPeeps
#          https://github.com/openpeeps/clue

import std/[sequtils, options, tables, strformat, sets,
          streams, times, strutils, os, osproc, threadpool]

import pkg/[semver, openparser/json]
import pkg/kapsis/[runtime, interactive/prompts]

import ../features/pkgmanager/resolver
import ../features/pkgmanager/configs

type
  PkgDepInfo = tuple[name: string, constraint: VersionConstraint, refStr: string]
  PkgRef = object
    name: string
    refStr: string  # explicit branch/tag only — "" = default branch
    url: string

proc fetchPkgMeta(pkgName: string): Option[PkgRef] =
  withNimboxDB do:
    let res = nimboxDB.getTable("packages")
                      .get()
                      .where("name", newTextValue(pkgName))
                      .toSeq()
    if res.len == 0:
      return none(PkgRef)
    return some(PkgRef(name: pkgName, url: $(res[0][1]["url"]), refStr: ""))
  none(PkgRef)

proc clonePackage(url, dest, refStr: string): bool =
  ## Shallow-clone a package. refStr = branch/tag or "" for default branch.
  if dirExists(dest):
    return true  # already cached
  let cmd =
    if refStr.len > 0: "git clone --branch " & refStr & " " & url & " " & dest
    else:              "git clone " & url & " " & dest
  let (output, exitCode) = execCmdEx(cmd)
  if exitCode != 0:
    displayWarning("Failed to clone " & url & ": " & output)
    return false
  true

proc checkGitTag(dest, version: string): bool =
  ## Check whether a semver tag exists in the cloned repo.
  ## Uses startProcess instead of execCmdEx — safe to call from spawned threads.
  ## Tries both "vX.Y.Z" and "X.Y.Z" forms.
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
  let nimbleFilePath = nimboxPkgsCachePath / pkgName / pkgName.changeFileExt("nimble")
  if not fileExists(nimbleFilePath):
    return ("0.0.0", @[])

  let pkgNimble = parseNimbleFile(nimbleFilePath)
  let pkgVersion = if pkgNimble.hasKey("version"): pkgNimble["version"].getStr else: "0.0.0"

  var deps: seq[PkgDepInfo] = @[]

  if pkgNimble.hasKey("requires"):
    for dep in pkgNimble["requires"]:
      let depName = dep["name"].getStr
      if depName == "nim": continue

      var constraint = VersionConstraint(kind: vcAny, version: newVersion(0, 0, 0))
      var depRef = ""

      if dep.hasKey("branch"):
        depRef = dep["branch"].getStr
        if depRef == "head": depRef = ""
      elif dep.hasKey("tag"):
        depRef = dep["tag"].getStr
      elif dep.hasKey("constraints"):
        let cs = dep["constraints"]
        if cs.len > 0 and cs[0].hasKey("version"):
          let op = if cs[0].hasKey("operator"): cs[0]["operator"].getStr else: ">="
          constraint = parseConstraint(op & cs[0]["version"].getStr)

      if depName notin pkgRefs:
        let metaOpt = fetchPkgMeta(depName)
        if metaOpt.isSome:
          var meta = metaOpt.get()
          meta.refStr = depRef
          pkgRefs[depName] = meta
        else:
          displayWarning("Unknown package in registry: " & depName)

      deps.add((name: depName, constraint: constraint, refStr: depRef))

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
  withNimboxDB do:
    # look up root in DB
    let rootMetaOpt = fetchPkgMeta(pkgName)
    if rootMetaOpt.isNone:
      displayError("Package not found in registry: " & pkgName)
      return

    var pkgRefs: Table[string, PkgRef]
    var rootMeta = rootMetaOpt.get()
    rootMeta.refStr = pkgRef
    pkgRefs[pkgName] = rootMeta

    # Clone root synchronously — we need its .nimble to start
    let rootDest = nimboxPkgsCachePath / pkgName
    if not dirExists(rootDest):
      echo "Fetching " & pkgName & "..."
      if not clonePackage(rootMeta.url, rootDest, pkgRef):
        return
    else:
      echo "Using cached " & pkgName

    # bfs wave by wave concurrent cloning
    var registry: PackageRegistry
    var visited: HashSet[string]
    # depTree stores (version, deps) per package for tree printing
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
      # echo "Cloning " & $wave.len & " package(s)..."
      displayInfo("Cloning " & $wave.len & " package(s)...")
      var futs: seq[FlowVar[bool]] = @[]
      for w in wave:
        let meta = pkgRefs.getOrDefault(w.name, PkgRef())
        if meta.url.len == 0:
          displayWarning("No URL for " & w.name & ", skipping.")
          futs.add(spawn (proc(): bool = false)())
          continue
        let dest = nimboxPkgsCachePath / w.name
        if dirExists(dest):
          display("  " & cyan(w.name) & " (cached)")
          futs.add(spawn (proc(): bool = true)())
        else:
          futs.add(spawn clonePackage(meta.url, dest, w.refStr))
          display("  " & cyan(meta.url))
      sync()

      var nextWave: seq[tuple[name: string, refStr: string]] = @[]
      for i, w in wave:
        if not (^futs[i]):
          echo "  skipping deps of " & w.name & " (clone failed)"
          continue

        let (ver, deps) = parseDepsFromNimble(w.name, pkgRefs)
        depTree[w.name] = (ver, deps)
        registry.addPackage(UnresolvedPackage(
          name: w.name,
          version: parseVersion(ver),
          dependencies: deps.mapIt(Dependency(name: it.name, constraint: it.constraint))
        ))

        for d in deps:
          if d.name notin visited:
            visited.incl(d.name)
            nextWave.add((d.name, d.refStr))

      wave = nextWave

    # Print dependency tree
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
        # If this dep has its own subtree, recurse; otherwise just print leaf
        if dep.name in depTree:
          printTree(dep.name, indent + 1, childIsLast)
        else:
          let childBranch = repeat("│  ", indent) & (if childIsLast: "└─ " else: "├─ ")
          echo childBranch & dep.name & constraintStr

    printTree(pkgName, 0, true)
    echo "" # extra newline after tree

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
    # echo "Resolved " & $resolved.len & " package(s). Verifying tags..."

    # Fetch tags for any repo that was already cached (full clone fetches them,
    # but older shallow-cloned caches may be missing them)
    # for rp in resolved:
    #   let dest = nimboxPkgsCachePath / rp.name
    #   if dirExists(dest):
    #     let p = startProcess("git",
    #       args = ["-C", dest, "fetch", "--tags", "--quiet"],
    #       options = {poUsePath, poStdErrToStdOut})
    #     discard p.waitForExit()
    #     p.close()

    # Concurrently verify git tags
    type TagCheck = tuple[name: string, version: string, dest: string]
    var tagChecks: seq[TagCheck] = @[]
    var tagFuts: seq[FlowVar[bool]] = @[]

    for rp in resolved:
      let meta = pkgRefs.getOrDefault(rp.name, PkgRef())
      if meta.refStr.len == 0 and $rp.version != "0.0.0":
        let dest = nimboxPkgsCachePath / rp.name
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
    else:
      displaySuccess("All " & $resolved.len & " package(s) installed")

proc installCommand*(v: Values) =
  let pkgInput = split(v.get("pkg").getStr, "@")
  let pkgName = pkgInput[0]
  let pkgRef = if pkgInput.len > 1 and pkgInput[1] != "head": pkgInput[1] else: ""
  installPackage(pkgName, pkgRef)

template whenPackageExists(pkgName: string, body: untyped): untyped =
  let pkgPath = nimboxPkgsPath / pkgName
  if dirExists(pkgPath):
    # Check if the package exists in the database
    let res = nimboxDB.getTable("packages")
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
  ## Uninstall a package from the system
  withNimboxDB do:
    let pkgName = v.get("pkg").getStr
    whenPackageExists pkgName:
      if promptConfirm("Are you sure you want to uninstall package: " & cyan(pkgName) & "?"):
        removeDir(nimboxPkgsPath / pkgName)
        displaySuccess("Package uninstalled: " & cyan(pkgName))
      else:
        displayInfo("Uninstallation cancelled.")

proc dumpCommand*(v: Values) =
  ## Dump package info from registry
  withNimboxDB do:
    let pkgName = v.get("pkg").getStr
    whenPackageExists pkgName:
      let res = nimboxDB.getTable("packages")
                        .get()
                        .where("name", newTextValue(pkgName))
                        .toSeq()
      if res.len > 0:
        var pkgData = res[0]
        var pkgInfo = %*{
          "method": pkgData[1]["method"].getStr,
          "name": pkgData[1]["name"].getStr,
          "url": pkgData[1]["url"].getStr,
          "description": pkgData[1]["description"].getStr,
          "web": pkgData[1]["web"].getStr,
          "license": pkgData[1]["license"].getStr,
          "tags": fromJson(pkgData[1]["tags"].jsonVal)
        }
        display(pretty(pkgInfo))

# proc searchCommand*(v: Values) =
#   ## Search command to find packages by name or tags
#   withNimboxDB do:
#     let query = v.get("query").getStr
#     let res = nimboxDB.getTable("packages")
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
# Generated by nimbox venv

TARGET_VENV="__VENVDIR__"

# If this venv is already active in this shell, do nothing.
if [ "$NIMBOX_VENV" = "$TARGET_VENV" ]; then
  echo "Nimbox venv already activated: $TARGET_VENV"
  return 0
fi

NIMBOX_VENV="$TARGET_VENV"
export NIMBOX_VENV

# Save previous environment only if not already saved (prevents double-save)
if [ -z "$_NIMBOX_OLD_PATH" ]; then
  export _NIMBOX_OLD_PATH="$PATH"
fi
if [ -z "$_NIMBOX_OLD_NIMBLE_DIR" ]; then
  export _NIMBOX_OLD_NIMBLE_DIR="$NIMBLE_DIR"
fi

# Prompt customization: prefer env var, then .nimbox_prompt file, then default
if [ -z "$NIMBOX_PROMPT" ]; then
  if [ -f "$NIMBOX_VENV/.nimbox_prompt" ]; then
    NIMBOX_PROMPT="$(cat "$NIMBOX_VENV/.nimbox_prompt")"
  else
    NIMBOX_PROMPT="➜ __PKG__"
  fi
fi
export NIMBOX_PROMPT

# Save and set shell prompt for zsh/bash (falls back to PS1); only save once
if [ -n "$ZSH_VERSION" ]; then
  if [ -z "$_NIMBOX_OLD_PROMPT" ]; then
    export _NIMBOX_OLD_PROMPT="$PROMPT"
    PROMPT="$NIMBOX_PROMPT $PROMPT"
  fi
elif [ -n "$BASH_VERSION" ]; then
  if [ -z "$_NIMBOX_OLD_PS1" ]; then
    export _NIMBOX_OLD_PS1="$PS1"
    PS1="$NIMBOX_PROMPT $PS1"
  fi
else
  if [ -z "$_NIMBOX_OLD_PS1" ]; then
    export _NIMBOX_OLD_PS1="$PS1"
    PS1="$NIMBOX_PROMPT $PS1"
  fi
fi

# Set venv-specific vars
export NIMBLE_dir="$NIMBOX_VENV/pkgs"
export NIMBLE_DIR="$NIMBOX_VENV/pkgs"
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
# Generated by nimbox venv

TARGET_VENV="__VENVDIR__"

# If this venv is not active in this shell, do nothing.
if [ -z "$NIMBOX_VENV" ] || [ "$NIMBOX_VENV" != "$TARGET_VENV" ]; then
  echo "Nimbox venv not active for this directory: $TARGET_VENV"
  return 0
fi

# Restore previous PATH if present
if [ -n "$_NIMBOX_OLD_PATH" ]; then
  export PATH="$_NIMBOX_OLD_PATH"
  unset _NIMBOX_OLD_PATH
fi

# Restore previous NIMBLE_DIR or unset
if [ -n "$_NIMBOX_OLD_NIMBLE_DIR" ]; then
  export NIMBLE_DIR="$_NIMBOX_OLD_NIMBLE_DIR"
  unset _NIMBOX_OLD_NIMBLE_DIR
else
  unset NIMBLE_DIR
fi

# Restore prompt
if [ -n "$ZSH_VERSION" ]; then
  if [ -n "$_NIMBOX_OLD_PROMPT" ]; then
    PROMPT="$_NIMBOX_OLD_PROMPT"
    unset _NIMBOX_OLD_PROMPT
  fi
elif [ -n "$BASH_VERSION" ]; then
  if [ -n "$_NIMBOX_OLD_PS1" ]; then
    PS1="$_NIMBOX_OLD_PS1"
    unset _NIMBOX_OLD_PS1
  fi
else
  if [ -n "$_NIMBOX_OLD_PS1" ]; then
    PS1="$_NIMBOX_OLD_PS1"
    unset _NIMBOX_OLD_PS1
  fi
fi

unset NIMBOX_VENV
unset NIMBOX_PROMPT

echo "Nimbox venv deactivated"
"""

  # write activation/deactivation with embedded absolute venv path
  writeFile(activateScript,
    activateContents.replace("__NIMBIN__", nimBinPath)
                    .replace("__VERSION__", requestedVersion)
                    .replace("__PKG__", pkgName)
                    .replace("__VENVDIR__", venvDir))
  writeFile(deactivateScript, deactivateContents.replace("__VENVDIR__", venvDir))


  # write default per-venv prompt file (user can edit or set NIMBOX_PROMPT env var)
  let promptFile = venvDir / ".nimbox_prompt"
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
  - Edit .env/.nimbox_prompt to change the prefix (or set NIMBOX_PROMPT).
  - Activation will prepend that prefix to your current zsh/bash prompt.
"""
  displayInfo(outputMessage)