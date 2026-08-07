# Clue - A cool toolkit for Nim developers
#
# (c) 2026 George Lemon | LGPLv3 License
#          Made by Humans from OpenPeeps
#          https://github.com/openpeeps/clue

import std/[sequtils, options, tables, sets, strformat, strutils,
          streams, times, os, osproc]

import pkg/[semver, openparser/json]
import pkg/kapsis/[runtime, interactive/prompts]

import ../pkgmanager/resolver
import ../pkgmanager/configs
import ../pkgmanager/versions
import ../pkgmanager/nimbleparser

proc depName(d: NimbleDependency): string =
  if d.name.len > 0: d.name else: d.url

proc parseFeatureFlags*(s: string): seq[string] =
  for f in s.split(','):
    let ff = f.strip()
    if ff.len > 0:
      result.add(ff)

proc isGitUrl*(s: string): bool =
  s.startsWith("https://") or s.startsWith("http://") or
  s.startsWith("git@") or s.startsWith("git+") or
  s.startsWith("ssh://")

proc toGitSshUrl*(url: string): string =
  ## Translate an https(s) git URL into an scp-like SSH URL
  ## (`git@host:path.git`) so `git clone` runs over SSH using the user's
  ## default SSH keys — enabling installs of private repositories.
  var u = url.strip()
  if u.startsWith("git+"):
    u = u[4 .. ^1]
  if not (u.startsWith("https://") or u.startsWith("http://")):
    return u
  let slashPos = u.split("://")[1].find('/')
  if slashPos < 0:
    return u
  let host = u.split("://")[1][0 ..< slashPos]
  var path = u.split("://")[1][slashPos + 1 .. ^1]
  if not path.endsWith(".git"):
    path.add(".git")
  result = "git@" & host & ":" & path

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

proc installPackage*(pkgName: string, pkgRef: string = "", refresh = false,
    features: seq[string] = @[], verbose = true, url = "") =
  ## Install a package and its dependencies into ~/.clue/packages.
  ## Uses fast, cached version discovery and only installs versions that
  ## satisfy the resolved constraints. Prunes orphans afterwards.
  ## `features` activates the root package's `feature "name":` requires.
  ## `verbose` controls progress output (clue build calls it quietly).
  ## `url` bypasses the registry lookup and installs straight from a git URL.
  withClueDB do:
    var rootMeta: PkgRef
    if url.len > 0:
      rootMeta = PkgRef(name: pkgName, url: url, refStr: "")
    else:
      let rootMetaOpt = fetchPkgMeta(pkgName)
      if rootMetaOpt.isNone:
        displayError("Package not found in registry: " & pkgName)
        return
      rootMeta = rootMetaOpt.get()

    # 1. Ensure root clone exists (full clone kept in cache)
    let rootDest = cluePkgsCachePath / pkgName
    if not dirExists(rootDest):
      if verbose: displayInfo("Fetching " & pkgName & "...")
      if not clonePackage(rootMeta.url, rootDest):
        return
    else:
      if verbose: displayInfo("Using cached " & pkgName)
      if refresh:
        discard clonePackage(rootMeta.url, rootDest)

    # 2. Root constraint: explicit semver ref, else latest (vcAny).
    #    Non-semver refs (git branches/tags via `pkg@ref` / `#ref`) install
    #    the ref directly. Feature refs (`pkg[feat]`) are NOT git refs.
    var rootConstraint = VersionConstraint(kind: vcAny, version: newVersion(0, 0, 0))
    if pkgRef.len > 0:
      try:
        rootConstraint = VersionConstraint(kind: vcExact, version: parseVersion(pkgRef))
      except CatchableError:
        rootMeta.refStr = pkgRef
        if verbose: display("  " & cyan(pkgName & "@" & pkgRef))

    # 3. Register root versions (constraints are enforced by findBestMatch)
    var registry: PackageRegistry
    var pkgRefs = initTable[string, PkgRef]()
    pkgRefs[pkgName] = rootMeta
    let rootVersions = discoverVersions(pkgName, rootMeta.url, refresh)
    if rootVersions.len == 0:
      registry.addPackage(UnresolvedPackage(name: pkgName, version: headVersion(pkgName), dependencies: @[]))
    else:
      for v in rootVersions:
        registry.addPackage(UnresolvedPackage(name: pkgName, version: v.version, dependencies: @[]))

    # 4. Lazy dep provider: expands the graph on demand, registering
    #    only in-range / reachable versions into the registry. Also records
    #    the features each package was resolved with (for the manifest).
    var activeFeatOf = initTable[string, seq[string]]()
    proc provider(name: string, version: Version, feats: seq[string]): seq[Dependency] =
      activeFeatOf[name] = feats
      let deps = getDeps(name, $version, feats, refresh)
      result = @[]
      for d in deps:
        let dn = depName(d)
        # ensure we know the package URL
        var meta = pkgRefs.getOrDefault(dn, PkgRef())
        if meta.url.len == 0:
          let m = fetchPkgMeta(dn)
          if m.isSome:
            meta = m.get()
            pkgRefs[dn] = meta
        if meta.url.len == 0:
          if verbose: displayWarning("Unknown package in registry, skipping: " & dn)
          continue
        # register versions on first sight
        if dn notin registry:
          if d.branch.len > 0 or d.tag.len > 0:
            # genuine git ref dep (`pkg#ref` / url#ref): no semver resolution
            var m = meta
            m.refStr = if d.branch.len > 0: d.branch else: d.tag
            pkgRefs[dn] = m
            registry.addPackage(UnresolvedPackage(name: dn, version: newVersion(0, 0, 0), dependencies: @[]))
          else:
            let versions = discoverVersions(dn, meta.url, refresh)
            if versions.len == 0:
              registry.addPackage(UnresolvedPackage(name: dn, version: headVersion(dn), dependencies: @[]))
            else:
              for v in versions:
                registry.addPackage(UnresolvedPackage(name: dn, version: v.version, dependencies: @[]))
        if d.branch.len > 0 or d.tag.len > 0:
          result.add(Dependency(name: dn,
            constraint: VersionConstraint(kind: vcExact, version: newVersion(0, 0, 0)),
            features: d.features))
        else:
          result.add(Dependency(name: dn, constraint: d.constraint, features: d.features))

    # 5. Resolve
    let roots = @[Dependency(name: pkgName, constraint: rootConstraint, features: features)]
    var resolved: seq[ResolvedPackage]
    try:
      resolved = registry.resolve(roots, provider)
    except CircularDependencyError as e:
      displayError("Circular dependency: " & e.msg); return
    except VersionConflictError as e:
      displayError("Version conflict: " & e.msg); return
    except PackageNotFoundError as e:
      displayError("Package not found during resolution: " & e.msg); return

    var name2ver: Table[string, string]
    for rp in resolved:
      name2ver[rp.name] = $rp.version
    if verbose:
      displayInfo("Resolved " & $resolved.len & " package(s):")
      for rp in resolved:
        var label = cyan(rp.name) & " @" & $rp.version
        let feats = activeFeatOf.getOrDefault(rp.name)
        if feats.len > 0:
          label.add(" (features: " & feats.join(", ") & ")")
        display("  " & label)

    # 6. Install each resolved package from the cache (clean, flat layout)
    var installedCount = 0
    for rp in resolved:
      let meta = pkgRefs.getOrDefault(rp.name, PkgRef())
      let verStr =
        if meta.refStr.len > 0: meta.refStr
        else: $rp.version
      let cacheDir = cluePkgsCachePath / rp.name
      if not dirExists(cacheDir):
        let m = fetchPkgMeta(rp.name)
        if m.isNone:
          displayWarning("No URL for " & rp.name & ", skipping")
          continue
        if not clonePackage(m.get().url, cacheDir):
          continue
      # checkout the exact resolved ref/tag
      if meta.refStr.len > 0:
        discard checkoutRef(cacheDir, meta.refStr)
      elif verStr != "0.0.0":
        let tag = tagForVersion(cacheDir, verStr)
        if tag.len > 0:
          discard checkoutTag(cacheDir, tag)

      let verDir = cluePkgsPath / rp.name / verStr
      if dirExists(verDir):
        if verbose: display("  " & cyan(rp.name) & " v" & verStr & " (already installed)")
        installedCount.inc
        continue
      try:
        let nimblePath = cacheDir / rp.name.changeFileExt("nimble")
        var pkgNimble = NimbleFile(srcDir: "")
        if fileExists(nimblePath):
          pkgNimble = parseNimbleFile(nimblePath)
        installCleanCopy(cacheDir, verDir, pkgNimble)
        installedCount.inc
        if verbose: displaySuccess("Installed " & rp.name & " v" & verStr)
      except CatchableError:
        displayWarning("Failed to install " & rp.name & " v" & verStr)

    # 7. Record install manifests (resolved dep graph, used for pruning).
    #    Only the explicitly-installed package is a root; transitive deps
    #    are pruned when no longer reachable from any root.
    for rp in resolved:
      let meta = pkgRefs.getOrDefault(rp.name, PkgRef())
      let verStr = if meta.refStr.len > 0: meta.refStr else: $rp.version
      let feats = activeFeatOf.getOrDefault(rp.name)
      var deps: seq[DepEntry]
      for d in getDeps(rp.name, $rp.version, feats):
        let dn = depName(d)
        if d.branch.len > 0:
          deps.add((dn, d.branch))
        elif name2ver.hasKey(dn):
          deps.add((dn, name2ver[dn]))
      recordInstall(rp.name, verStr, deps, root = rp.name == pkgName, features = feats)

    if installedCount > 0 and verbose:
      displaySuccess("Installed " & $installedCount & " package(s) to " & cluePkgsPath)

    # 8. Prune orphans / out-of-range versions
    pruneOrphans(verbose)

proc installCommand*(v: Values) =
  let raw = v.get("pkg").getStr
  let refresh = v.has("--refresh")
  var features: seq[string]
  if v.has("--features"):
    features = parseFeatureFlags(v.get("--features").getStr)
  if isGitUrl(raw):
    # `https://host/owner/repo[#ref]` installs straight from git. The URL is
    # translated to SSH (`git@host:path.git`) so private repos clone with the
    # user's default SSH keys.
    var url = raw
    var urlRef = ""
    let hashPos = url.find('#')
    if hashPos >= 0:
      urlRef = url[hashPos + 1 .. ^1]
      url = url[0 ..< hashPos]
    let name = pkgNameFromUrl(url)
    if name.len == 0:
      displayError("Could not derive a package name from: " & raw)
      return
    installPackage(name, urlRef, refresh, features, url = toGitSshUrl(url))
  else:
    let pkgInput = split(raw, "@")
    let pkgName = pkgInput[0]
    let pkgRef = if pkgInput.len > 1 and pkgInput[1] != "head": pkgInput[1] else: ""
    installPackage(pkgName, pkgRef, refresh, features)

proc versionsCommand*(v: Values) =
  ## Show available versions for a package.
  let pkgName = v.get("pkg").getStr
  let metaOpt = fetchPkgMeta(pkgName)
  if metaOpt.isNone:
    displayError("Package not found in registry: " & pkgName)
    return
  let meta = metaOpt.get()
  let versions = discoverVersions(pkgName, meta.url, v.has("--refresh"))
  if versions.len == 0:
    displayInfo("No semver tags found for " & pkgName)
    return
  displayInfo("Available versions for " & pkgName & ":")
  for v in versions:
    echo "  " & $v.version

proc pruneCommand*(v: Values) =
  ## Prune orphaned or out-of-range installed packages.
  pruneOrphans()

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
          unrecordInstall(pkgName, pkgVersion)
          displaySuccess("Removed " & pkgName & "@" & pkgVersion)
        else:
          displayInfo("Removal cancelled.")
      else:
        displayError("Version not installed: " & pkgName & "@" & pkgVersion)
    else:
      whenPackageExists pkgName:
        if promptConfirm("Remove all versions of " & cyan(pkgName) & "?"):
          removeDir(cluePkgsPath / pkgName)
          unrecordInstall(pkgName, "")
          displaySuccess("All versions of " & pkgName & " removed")
        else:
          displayInfo("Uninstallation cancelled.")
    pruneOrphans()

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
