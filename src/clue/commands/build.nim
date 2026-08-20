# Clue - A cool toolkit for Nim developers
#
# (c) 2026 George Lemon | LGPLv3 License
#          Made by Humans from OpenPeeps
#          https://github.com/openpeeps/clue
import std/[os, osproc, strformat, strutils, algorithm, sets, tables, json, sequtils, options, locks]
import pkg/semver
import pkg/kapsis/[runtime, interactive/prompts]
import pkg/malebolgia

import ../pkgmanager/nimbleparser
import ../pkgmanager/configs
import ../pkgmanager/versions
import ../pkgmanager/resolver
import ./manager
import ./nimscript

proc writeRaw(s: string) =
  ## Write compiler output verbatim (preserves ANSI colors).
  if s.len == 0: return
  write(stdout, s)
  if s[^1] != '\n':
    write(stdout, "\n")

proc depNameOf(d: NimbleDependency): string =
  if d.name.len > 0: d.name else: d.url

proc installedVersionSatisfies(depPath: string, constraint: VersionConstraint): bool =
  ## True when the installed version extracted from `depPath` satisfies the
  ## nimble constraint. Any/0.0.0 constraints always pass.
  if constraint.kind == vcAny: return true
  if constraint.kind == vcExact and constraint.version.major == 0 and
     constraint.version.minor == 0 and constraint.version.patch == 0:
    return true
  # path is like ~/.clue/packages/<name>/<version> — extract the last component
  let versionStr = depPath.lastPathPart
  try:
    let installedVer = parseVersion(versionStr)
    return installedVer.satisfies(constraint)
  except CatchableError:
    return true  # can't parse — assume OK, don't block the build

proc installedCoversFeatures(name: string, feats: seq[string]): bool =
  ## True when the installed manifest for `name` was resolved with every
  ## requested feature (so `-d:features.<name>.<feat>` is meaningful).
  if feats.len == 0:
    return true
  let map = installedFeatures()
  if not map.hasKey(name):
    return false
  for f in feats:
    if f notin map[name]:
      return false
  true

proc srcDirPath(verDir, depName: string): string =
  ## Nim resolves `import pkg/<name>` to `<path>/<name>/<name>.nim`.
  ## For clue-installed packages (raw repo copies) the module often lives in
  ## a `srcDir` subdir, so point `--path` at the source dir when present.
  let nimblePath = verDir / depName.changeFileExt("nimble")
  if fileExists(nimblePath):
    try:
      let srcDir = parseNimbleFile(nimblePath).srcDir
      if srcDir.len > 0 and dirExists(verDir / srcDir):
        return verDir / srcDir
    except CatchableError:
      discard
  verDir

proc resolveDepPath(depName: string, preferRef = ""): string =
  ## Locate an installed dependency, preferring the dir for `preferRef`
  ## (branch/tag) when given, else the latest semver version. Uses the recorded
  ## `--path` from the install index when available (falls back to scanning the
  ## filesystem for legacy installs).
  let recorded = resolveInstalledPath(depName, preferRef)
  if recorded.len > 0:
    return srcDirPath(recorded, depName)
  let clueInstall = cluePkgsPath / depName
  if dirExists(clueInstall):
    if preferRef.len > 0 and dirExists(clueInstall / preferRef):
      return srcDirPath(clueInstall / preferRef, depName)
    var dirs: seq[string] = @[]
    for entry in walkDir(clueInstall):
      if entry.kind == pcDir:
        dirs.add(entry.path.extractFilename)
    var best = ""
    var bestIsSemver = false
    for d in dirs:
      var isSemver = false
      try:
        discard parseVersion(d)
        isSemver = true
      except CatchableError:
        discard
      if best.len == 0:
        best = d
        bestIsSemver = isSemver
      elif isSemver and not bestIsSemver:
        best = d
        bestIsSemver = true
      elif isSemver == bestIsSemver:
        if isSemver:
          if parseVersion(d) > parseVersion(best): best = d
        elif d > best:
          best = d
    if best.len > 0:
      return srcDirPath(clueInstall / best, depName)
  ""

proc collectResolvedPaths*(nimble: NimbleFile, activeRootFeatures: seq[string],
    pkgName: string, verbose: bool): tuple[pathFlags: seq[string], featureDefines: string] =
  ## Resolve the dependency `--path` flags (and feature defines) for the given
  ## package, auto-installing anything missing. Used by `clue build` and
  ## `clue test`.
  # Effective direct deps = hard requires + requires of active root features.
  var directDeps: seq[NimbleDependency] = nimble.requires
  for f in activeRootFeatures:
    if nimble.features.hasKey(f):
      for d in nimble.features[f]:
        directDeps.add(d)

  var pathFlags: seq[string]
  var processed = initHashSet[string]()

  # 1. Ensure direct deps are installed with the right features, resolving
  #    their paths. A registry-installed dep lacking a requested feature is
  #    re-resolved so its manifest records the feature (→ defines). Develop-mode
  #    installs are authoritative — their live source defines the feature, so
  #    they're never re-installed for this purpose.
  var directNames: seq[string]
  var directFeats = initTable[string, seq[string]]()
  for dep in directDeps:
    if dep.isNim: continue
    let name = depNameOf(dep)
    let refStr = if dep.branch.len > 0: dep.branch elif dep.tag.len > 0: dep.tag else: ""
    var depPath = resolveDepPath(name, refStr)
    if depPath.len > 0 and isInsidePkgs(depPath):
      var needsReinstall = false
      if not installedCoversFeatures(name, dep.features):
        if verbose: displayInfo("Refreshing " & name & " (features: " & dep.features.join(", ") & ")")
        needsReinstall = true
      elif not installedVersionSatisfies(depPath, dep.constraint):
        if verbose: displayInfo("Reinstalling " & name & " (constraint " & $dep.constraint & " not satisfied by " & depPath.lastPathPart & ")")
        needsReinstall = true
      if needsReinstall:
        installPackage(name, refStr, false, dep.features, verbose, constraint = dep.constraint)
        depPath = resolveDepPath(name, refStr)
    if depPath.len == 0:
      if verbose: displayInfo("Dependency not installed, fetching: " & name)
      installPackage(name, refStr, false, dep.features, verbose, constraint = dep.constraint)
      depPath = resolveDepPath(name, refStr)
    if depPath.len > 0:
      processed.incl(name)
      directNames.add(name)
      directFeats[name] = dep.features
      pathFlags.add("--path:" & depPath)
      if verbose: display("  dep " & name & " → " & depPath)
    else:
      displayWarning("Dependency not found: " & name)

  # 2. Ensure the whole transitive closure is on the path, installing
  #    any transitive deps that are missing. Loop until the closure
  #    stops growing (installing one dep may pull in more).
  var changed = true
  while changed:
    changed = false
    for name in collectInstalledDepNames(directNames):
      if name in processed:
        continue
      processed.incl(name)
      var depPath = resolveDepPath(name)
      if depPath.len == 0:
        if verbose: displayInfo("Transitive dependency not installed, fetching: " & name)
        installPackage(name, "", false, @[], verbose)
        depPath = resolveDepPath(name)
        changed = true
      if depPath.len > 0:
        pathFlags.add("--path:" & depPath)
        if verbose: display("  dep " & name & " → " & depPath)
      else:
        displayWarning("Transitive dependency not found: " & name)

  # dedupe path flags while preserving order
  var seenFlags = initHashSet[string]()
  pathFlags = pathFlags.filterIt(block:
    if it in seenFlags:
      false
    else:
      seenFlags.incl(it)
      true)

  # feature defines so `when defined(features.<pkg>.<feat>)` works in code —
  # for the root package and every dependency with active features. Direct deps
  # use the features parsed from the nimble `requires` lines (authoritative,
  # covers develop-mode installs whose manifest records no features); the rest
  # of the closure uses the features recorded at install time.
  var featureDefines = ""
  var definedFeats = initHashSet[string]()
  for f in activeRootFeatures:
    let d = " -d:features." & pkgName & "." & f
    if d notin definedFeats:
      definedFeats.incl(d)
      featureDefines.add(d)
  for name, feats in directFeats:
    for f in feats:
      let d = " -d:features." & name & "." & f
      if d notin definedFeats:
        definedFeats.incl(d)
        featureDefines.add(d)
  let featsMap = installedFeatures()
  for name in collectInstalledDepNames(directNames):
    if featsMap.hasKey(name):
      for f in featsMap[name]:
        let d = " -d:features." & name & "." & f
        if d notin definedFeats:
          definedFeats.incl(d)
          featureDefines.add(d)
  (pathFlags, featureDefines)

proc resolveBackend(v: Values): string =
  if v.has("-b"): v.get("-b").getAny
  else: "c"

proc buildCommand*(v: Values) =

  let file =
    if v.has("file"): v.get("file").getStr
    else: ""
  let isRelease = v.has("--release")
  let isDebug = v.has("--debug")
  let verbose = v.has("--verbose")
  devShadowWarningsEnabled = verbose
  let outPath =
    if v.has("--out"): v.get("--out").getStr
    elif v.has("-o"): v.get("-o").getStr
    else: ""
  let backend = resolveBackend(v)
  let nimFlags = extras.join(" ")

  # Module mode: `clue build foo.nim` — no nimble file needed; every installed
  # package is put on the import path so any `import xyz` resolves.
  if file.len > 0:
    let pathFlags = allInstalledPaths().mapIt("--path:" & it)
    var flags = " " & pathFlags.join(" ") & " --colors:on" & " " & nimFlags
    if isRelease:
      flags.add(" -d:release --opt:size")
    elif isDebug:
      flags.add(" --debugger:native")
    let outFile =
      if outPath.len > 0: outPath
      else: file.extractFilename.changeFileExt("")
    let cmd = resolveNimBin() & " " & backend & flags & " --out:" & outFile & " " & file
    if verbose:
      display("  " & cyan(cmd))
    let (output, exitCode) = execCmdEx(cmd)
    if exitCode != 0:
      writeRaw(output)
      displayError("Build failed for " & file, quitProcess = true)
    else:
      if verbose:
        writeRaw(output)
      else:
        displaySuccess("Built " & file & " → " & outFile)
    return

  # Project mode: build the current package from its nimble file.

  # Active root features: `--features:foo,bar` + the implicit `dev` feature
  # (always active when building a package, matching nimble).
  var activeRootFeatures: seq[string]
  if v.has("--features"):
    activeRootFeatures = parseFeatureFlags(v.get("--features").getStr)
  if "dev" notin activeRootFeatures:
    activeRootFeatures.add("dev")

  let pkgDir = getCurrentDir()
  let nimblePath = findNimbleFile(pkgDir)

  if nimblePath.len == 0:
    displayError("No .nimble file found in " & pkgDir, quitProcess = true)
    return

  # Before build hook
  discard runNimscriptHook(nimblePath, "build", before=true)

  let nimble = parseNimbleFile(nimblePath)
  let pkgName = nimblePath.extractFilename.changeFileExt("")

  checkNimConstraint(nimble)

  if nimble.bin.len == 0:
    displayInfo("No binaries defined in " & nimblePath)
    return

  let srcDir =
    if nimble.srcDir.len > 0: nimble.srcDir
    else: "src"

  let binDir =
    if outPath.len > 0: outPath
    elif nimble.binDir.len > 0: nimble.binDir
    else: "bin"

  let (pathFlags, featureDefines) =
    collectResolvedPaths(nimble, activeRootFeatures, pkgName, verbose)

  if outPath.len > 0:
    discard existsOrCreateDir(outPath)
  else:
    discard existsOrCreateDir(pkgDir / binDir)

  # 3. Compile each binary. `--colors:on` keeps nim's ANSI colors in the
  #    captured output; errors are always printed (raw, colored), and with
  #    --verbose the warnings/hints are shown too.
  var buildFailed = false
  for bin in nimble.bin:
    let srcFile = pkgDir / srcDir / bin.addFileExt("nim")
    let outFile = if outPath.len > 0: outPath / bin
                  else: pkgDir / binDir / bin
    var flags = " " & pathFlags.join(" ") & featureDefines & " --colors:on" & " " & nimFlags
    if isRelease:
      flags.add(" -d:release --opt:size")
    elif isDebug:
      flags.add(" --debugger:native")

    let cmd = &"{resolveNimBin()} {backend}{flags} --out:{outFile} {srcFile}"
    if verbose:
      display("  " & cyan(cmd))

    let (output, exitCode) = execCmdEx(cmd)
    if exitCode != 0:
      writeRaw(output)
      displayError("Build failed for " & bin)
      buildFailed = true
    else:
      if verbose:
        writeRaw(output)
      else:
        displaySuccess("Built → " & outFile)

  # After build hook (runs even if build failed, for cleanup)
  discard runNimscriptHook(nimblePath, "build", before=false)

  if buildFailed:
    quit(1)

var testOutputLock: Lock
testOutputLock.initLock()

type
  TestJob = object
    file: string
    base: string
    flags: string

proc printTestOutput(output: string) {.gcsafe.} =
  if output.len == 0: return
  withLock testOutputLock:
    write(stdout, output)
    if output[^1] != '\n':
      write(stdout, "\n")
    flushFile(stdout)

proc runTest(job: TestJob): int {.gcsafe.} =
  ## Compile and run a single test module, printing its output as soon as it
  ## finishes. A dedicated `--nimcache` avoids concurrent `nim` processes racing
  ## on a shared cache directory. Returns the test's exit code.
  let outFile = getTempDir() / ("clue_test_" & job.base)
  let ncDir = getTempDir() / ("clue_test_nc_" & job.base)
  removeFile(outFile)
  let cmd = &"nim c -r{job.flags} --nimcache:{ncDir} --out:{outFile} {job.file}"
  let (output, exitCode) = execCmdEx(cmd)
  printTestOutput(output)
  exitCode

proc testCommand*(v: Values) =
  ## Compile and run test modules via nimscript. If the .nimble file defines
  ## a `task test`, it is executed directly. Otherwise a built-in default
  ## discovers `tests/t*.nim` and compiles each with `nim <backend> -r`.
  let pkgDir = getCurrentDir()
  let nimblePath = findNimbleFile(pkgDir)
  if nimblePath.len == 0:
    displayError("No .nimble file found in " & pkgDir, quitProcess = true)
    return

  checkNimConstraint(parseNimbleFile(nimblePath))
  let backend = if v.has("-b"): v.get("-b").getAny else: "c"
  let nimFlags = extras

  # Resolve dependency paths and feature defines so both custom nimscript
  # tasks and the built-in default runner compile with the same flags as
  # `clue build`.  Custom tasks read them via getPathsClause(); the default
  # runner receives them as a CLI argument.
  let pathFlags = allInstalledPaths().mapIt("--path:" & it)
  var featureDefines = ""
  let featsMap = installedFeatures()
  for pkg, feats in featsMap:
    for f in feats:
      featureDefines.add(" -d:features." & pkg & "." & f)
  let depFlags = pathFlags.join(" ") & " " & featureDefines.strip()
  putEnv("__NIMBLE_PATHS", depFlags.replace("--path:", "").strip())

  # Check if the .nimble file defines a custom `task test`
  let tasks = listTasks(nimblePath)
  for (name, _) in tasks:
    if name.toLowerAscii == "test":
      displayInfo("Running task 'test' from " & nimblePath.extractFilename() & "...")
      let beforeCode = execNimscript(nimblePath, "testBefore", passNim = nimFlags)
      if beforeCode != 0:
        displayWarning("before hook for 'test' failed (exit " & $beforeCode & ")")
      let exitCode = execNimscript(nimblePath, "test", passNim = nimFlags)
      let afterCode = execNimscript(nimblePath, "testAfter", passNim = nimFlags)
      if afterCode != 0:
        displayWarning("after hook for 'test' failed (exit " & $afterCode & ")")
      if exitCode != 0:
        displayError("Task 'test' failed (exit " & $exitCode & ")")
        quit(1)
      return

  # No custom task — run built-in default via a compiled test runner
  displayInfo("Running default test task...")

  # Before test hook
  discard runNimscriptHook(nimblePath, "test", before=true)
  let testRunnerCode = """import os, osproc, strutils, times, terminal, json

proc resolveNimBin(): string =
  let venvConfig = getCurrentDir() / ".env" / "venv.json"
  if fileExists(venvConfig):
    try:
      let config = parseFile(venvConfig)
      let nimBin = config["nim_bin"].getStr()
      if nimBin.len > 0 and dirExists(nimBin):
        let nimExe = nimBin / "nim"
        if fileExists(nimExe):
          return nimExe
    except CatchableError:
      discard
  let nimPath = findExe("nim")
  if nimPath.len > 0:
    return nimPath
  let choosenimBin = getHomeDir() / ".choosenim" / "current" / "bin" / "nim"
  if fileExists(choosenimBin):
    return choosenimBin
  "nim"

var currentProcess: Process

proc handleSigint() {.noconv.} =
  if currentProcess != nil:
    currentProcess.kill()
  quit(1)

setControlCHook(handleSigint)

let parts = commandLineParams()
let extraFlags = if parts.len > 0: parts[0] else: ""
let nimFlags = if parts.len > 1: parts[1] else: ""
let backend = if parts.len > 2: parts[2] else: "c"
var failed: seq[string]
var passed: int

for kind, path in walkDir("tests"):
  if kind == pcFile and path.endsWith(".nim") and path.extractFilename.startsWith("t"):
    let name = path.extractFilename.changeFileExt("")
    styledEcho fgCyan, "Compiling ", name, ".nim (" & backend & " backend)"
    let outFile = getTempDir() / ("clue_test_" & name)
    var args = @[backend, "-r", "--colors:on"]
    if extraFlags.len > 0:
      for f in extraFlags.split(" "):
        if f.len > 0: args.add(f)
    if nimFlags.len > 0:
      for f in nimFlags.split(" "):
        if f.len > 0: args.add(f)
    args.add("--out:" & outFile)
    args.add(path.extractFilename)
    currentProcess = startProcess(resolveNimBin(), args = args,
      workingDir = "tests", options = {poParentStreams})
    let code = currentProcess.waitForExit()
    currentProcess.close()
    if code != 0:
      styledEcho fgRed, "FAILED: ", name
      failed.add(name)
    else:
      styledEcho fgGreen, "OK: ", name
      inc passed

if failed.len > 0:
  styledEcho fgRed, $failed.len & " test(s) failed: " & failed.join(", ")
  quit(1)
else:
  styledEcho fgGreen, "All " & $passed & " test(s) passed!"
"""
  let projectName = pkgDir.lastPathPart()
  let buildTempDir = clueBuildTempPath / projectName
  discard existsOrCreateDir(clueBuildTempPath)
  discard existsOrCreateDir(buildTempDir)

  # Copy config.nims and nimble.paths so the Nim compiler resolves imports
  let srcConfig = pkgDir / "config.nims"
  let srcPaths = pkgDir / "nimble.paths"
  if fileExists(srcConfig):
    copyFile(srcConfig, buildTempDir / "config.nims")
  if fileExists(srcPaths):
    copyFile(srcPaths, buildTempDir / "nimble.paths")

  let runnerNim = buildTempDir / "clue_test_runner.nim"
  let runnerOut = buildTempDir / "clue_test_runner"
  writeFile(runnerNim, testRunnerCode)
  let (buildOutput, buildCode) = execCmdEx(
    resolveNimBin() & " c --out:" & runnerOut & " " & runnerNim)
  removeFile(runnerNim)
  if buildCode != 0:
    removeDir(buildTempDir)
    displayError("Failed to compile test runner: " & buildOutput)
    quit(1)
  let exitCode = execCmd(runnerOut.quoteShell & " " & depFlags.quoteShell &
    " " & nimFlags.join(" ").quoteShell & " " & backend.quoteShell)
  removeFile(runnerOut)
  removeDir(buildTempDir)

  # After test hook (runs even if tests failed)
  discard runNimscriptHook(nimblePath, "test", before=false)

  if exitCode != 0:
    displayError("Tests failed (exit " & $exitCode & ")", quitProcess = true)
