# Clue - A cool toolkit for Nim developers
#
# (c) 2026 George Lemon | LGPLv3 License
#          Made by Humans from OpenPeeps
#          https://github.com/openpeeps/clue
import std/[os, osproc, strformat, strutils, algorithm, sets, tables, json, sequtils, options, locks]
import pkg/semver
import pkg/kapsis/[runtime, interactive/prompts]
import pkg/kapsis/interactive/spinny
import pkg/malebolgia

import ../pkgmanager/nimbleparser
import ../pkgmanager/configs
import ../pkgmanager/versions
import ./manager

proc writeRaw(s: string) =
  ## Write compiler output verbatim (preserves ANSI colors).
  if s.len == 0: return
  write(stdout, s)
  if s[^1] != '\n':
    write(stdout, "\n")

proc depNameOf(d: NimbleDependency): string =
  if d.name.len > 0: d.name else: d.url

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
    if depPath.len > 0 and isInsidePkgs(depPath) and
        not installedCoversFeatures(name, dep.features):
      if verbose: displayInfo("Refreshing " & name & " (features: " & dep.features.join(", ") & ")")
      installPackage(name, refStr, false, dep.features, verbose)
      depPath = resolveDepPath(name, refStr)
    if depPath.len == 0:
      if verbose: displayInfo("Dependency not installed, fetching: " & name)
      installPackage(name, refStr, false, dep.features, verbose)
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
    else: ""

  # Module mode: `clue build foo.nim` — no nimble file needed; every installed
  # package is put on the import path so any `import xyz` resolves.
  if file.len > 0:
    var spinny: Spinny
    let useSpinner = not verbose
    if useSpinner:
      spinny = newSpinny("Building " & file & "...", skDots, time = true)
      spinny.start()
    let pathFlags = allInstalledPaths().mapIt("--path:" & it)
    var flags = " " & pathFlags.join(" ") & " --colors:on"
    if isRelease:
      flags.add(" -d:release --opt:size")
    elif isDebug:
      flags.add(" --debugger:native")
    let outFile =
      if outPath.len > 0: outPath
      else: file.extractFilename.changeFileExt("")
    let cmd = "nim c" & flags & " --out:" & outFile & " " & file
    if verbose:
      display("  " & cyan(cmd))
    let (output, exitCode) = execCmdEx(cmd)
    if exitCode != 0:
      if useSpinner:
        spinny.error("Build failed for " & file)
      else:
        displayError("Build failed for " & file)
      writeRaw(output)
    else:
      if verbose:
        writeRaw(output)
      elif useSpinner:
        spinny.success("Built " & file)
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
    displayError("No .nimble file found in " & pkgDir)
    return

  let nimble = parseNimbleFile(nimblePath)
  let pkgName = nimblePath.extractFilename.changeFileExt("")

  if nimble.bin.len == 0:
    displayInfo("No binaries defined in " & nimblePath)
    return

  let srcDir =
    if nimble.srcDir.len > 0: nimble.srcDir
    else: "src"

  let binDir =
    if nimble.binDir.len > 0: nimble.binDir
    else: "bin"

  # Single spinner wrapping the whole build; it degrades to a plain status line
  # when the output is not a terminal (pipes/CI).
  var spinny: Spinny
  let useSpinner = not verbose
  if useSpinner:
    spinny = newSpinny("Resolving dependencies...", skDots, time = true)
    spinny.start()

  let (pathFlags, featureDefines) =
    collectResolvedPaths(nimble, activeRootFeatures, pkgName, verbose)

  discard existsOrCreateDir(pkgDir / binDir)

  # 3. Compile each binary. `--colors:on` keeps nim's ANSI colors in the
  #    captured output; errors are always printed (raw, colored), and with
  #    --verbose the warnings/hints are shown too.
  var spinnerRunning = useSpinner
  for bin in nimble.bin:
    let srcFile = pkgDir / srcDir / bin.addFileExt("nim")
    let outFile = pkgDir / binDir / bin
    var flags = " " & pathFlags.join(" ") & featureDefines & " --colors:on"
    if isRelease:
      flags.add(" -d:release --opt:size")
    elif isDebug:
      flags.add(" --debugger:native")

    let cmd = &"nim c{flags} --out:{outFile} {srcFile}"
    if verbose:
      display("  " & cyan(cmd))
    if spinnerRunning:
      spinny.setText("Building " & bin & "...")

    let (output, exitCode) = execCmdEx(cmd)
    if exitCode != 0:
      # errors always shown, regardless of --verbose, colors preserved
      if spinnerRunning:
        spinny.error("Build failed for " & bin)
        spinnerRunning = false
      else:
        displayError("Build failed for " & bin)
      writeRaw(output)
    else:
      if verbose:
        writeRaw(output)
      elif not useSpinner:
        displaySuccess("Built " & bin & " → " & outFile)

  if spinnerRunning:
    spinny.success("Built successfully")

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
  ## Compile and run the test modules in `tests/` (files starting with `test`,
  ## e.g. `test_*.nim` / `test1.nim`) against clue-managed dependencies,
  ## printing nim's raw output (no spinner). Nim auto-loads any `tests/*.nims`
  ## config (e.g. `config.nims`) when compiling files in that directory. Tests
  ## run one by one by default; `--threads` compiles and runs them in parallel
  ## on the malebolgia pool and reports the exit code at the end.
  devShadowWarningsEnabled = true
  let useThreads = v.has("--threads")

  let pkgDir = getCurrentDir()
  let nimblePath = findNimbleFile(pkgDir)
  if nimblePath.len == 0:
    displayError("No .nimble file found in " & pkgDir)
    return
  let nimble = parseNimbleFile(nimblePath)
  let pkgName = nimblePath.extractFilename.changeFileExt("")

  var activeRootFeatures: seq[string]
  if v.has("--features"):
    activeRootFeatures = parseFeatureFlags(v.get("--features").getStr)
  if "dev" notin activeRootFeatures:
    activeRootFeatures.add("dev")

  let (pathFlags, featureDefines) =
    collectResolvedPaths(nimble, activeRootFeatures, pkgName, verbose = false)

  let testsDir = pkgDir / "tests"
  var testFiles: seq[string]
  if dirExists(testsDir):
    for f in walkFiles(testsDir / "test*.nim"):
      testFiles.add(f)
  sort(testFiles)

  if testFiles.len == 0:
    displayInfo("No test modules found in " & testsDir)
    return

  let flags = " " & pathFlags.join(" ") & featureDefines & " --hints:off --colors:on"

  if not useThreads:
    # Serial: one by one, stop at the first failing test (exit 1).
    for file in testFiles:
      let base = file.extractFilename.changeFileExt("")
      let outFile = getTempDir() / "clue_test_" & base
      removeFile(outFile)
      let cmd = &"nim c -r{flags} --out:{outFile} {file}"
      let (output, exitCode) = execCmdEx(cmd)
      writeRaw(output)
      if exitCode != 0:
        displayError("Test failed: " & base)
        quit(1)
    return

  # Parallel: spawn every test on the malebolgia pool. Each worker prints its
  # own output as soon as it finishes (no FlowVar/`^`, nothing blocks on the
  # slowest test). Only the exit codes are kept; the process exits non-zero if
  # any test failed.
  var exitCodes = newSeq[int](testFiles.len)
  var m = createMaster()
  m.awaitAll:
    for i, file in testFiles:
      let base = file.extractFilename.changeFileExt("")
      m.spawn runTest(TestJob(file: file, base: base, flags: flags)) -> exitCodes[i]
  var failed = false
  for i, code in exitCodes:
    if code != 0:
      failed = true
      displayError("Test failed: " & testFiles[i].extractFilename.changeFileExt(""))
  if failed:
    quit(1)
