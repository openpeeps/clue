# Clue - facade over datpkgr (app-agnostic library)
#
# (c) 2026 George Lemon | MIT License
# This file is now a thin wrapper that delegates to datpkgr.
# All filesystem is via flysystem single LocalDriver at ~/.clue,
# callbacks replace kapsis, and manifest is pluggable (.nimble for Clue).

import std/[os, osproc, strutils, options]
import pkg/boogie/stores/rdbms
import pkg/openparser/json
import pkg/semver
import pkg/kapsis/interactive/prompts
import datpkgr/config as datpkgrConfig
import datpkgr/types as datpkgrTypes
import datpkgr/store as datpkgrStore
import ./nimbleparser as clueNimbleParser

export rdbms
export datpkgrTypes
export datpkgrConfig

# Global config for Clue - lazy init to avoid module init order segfault
var clueCfgImpl: DatpkgrConfig

proc getClueCfg*(): DatpkgrConfig =
  if clueCfgImpl.isNil:
    clueCfgImpl = newDatpkgrConfig("clue")
    clueCfgImpl.withNimbleSupport(clueNimbleParser.nimbleManifestParser)
  clueCfgImpl

template clueCfg*(): DatpkgrConfig = getClueCfg()

# Back-compat globals expected by existing clue code (as templates for lazy)
template cluePath*: string = getClueCfg().rootPath
template clueDBPath*: string = getClueCfg().dbPath()
template versionsDBPath*: string = getClueCfg().versionsDBPath()
template cluePkgsPath*: string = getClueCfg().pkgsPath()
template cluePkgsCachePath*: string = getClueCfg().pkgsCachePath()
template clueBinPath*: string = getClueCfg().binPath()
template clueBuildTempPath*: string = getClueCfg().buildTempPath()
template clueDevelopPath*: string = getClueCfg().developPath()
template clueSourcesPath*: string = getClueCfg().rootPath / "sources.json"
template clueRegistriesDir*: string = getClueCfg().rootPath / "registries"
template nimbleLocalPackages*: string = getClueCfg().legacyRegistryPath
template nimblePackagesUrl*: string = getClueCfg().defaultRegistryUrl
template defaultSourceName*: string = getClueCfg().defaultSourceName

# Re-export Store handles for direct DB access (used by a few places)
template clueDB*: Store = getClueCfg().stores.db
template versionsDB*: Store = getClueCfg().stores.versionsDB

template debugEnabled*: untyped = getClueCfg().debugEnabled

proc debugLog*(msg: string) =
  if getClueCfg().debugEnabled:
    getClueCfg().logDebug(msg)

# Delegated helpers - keep original signatures so existing code compiles
proc isInsidePkgs*(dir: string): bool = clueCfg.isInsidePkgs(dir)
proc safeRemoveDir*(dir: string) = clueCfg.safeRemoveDir(dir)
proc safeRemoveSymlink*(p: string) = clueCfg.safeRemoveSymlink(p)

proc isValidSourceName*(s: string): bool = datpkgrStore.isValidSourceName(s)
proc sourceCachePath*(name: string): string = clueCfg.sourceCachePath(name)
proc ensureSourcesFile*() = clueCfg.ensureSourcesFile()
proc loadSources*(): seq[Source] = clueCfg.loadSources()
proc saveSources*(sources: seq[Source]) = clueCfg.saveSources(sources)

proc resetClueForTests*() = clueCfg.resetDatpkgrForTests()
proc seedPackagesTable*(nimblePackages: JsonNode, source: string = defaultSourceName): int =
  clueCfg.seedPackagesTable(nimblePackages, source)

proc initClue*() = clueCfg.initDatpkgr()

proc refreshSource*(sourceName: string): bool = clueCfg.refreshSource(sourceName)
proc refreshAllSources*(): bool = clueCfg.refreshAllSources()
proc refreshRegistry*(): bool = clueCfg.refreshRegistry()

template withClueDB*(body: untyped) =
  clueCfg.withDatpkgrDB:
    body

proc fetchPkgMeta*(pkgName: string, sourceFilter: string = ""): Option[PkgRef] =
  clueCfg.fetchPkgMeta(pkgName, sourceFilter)

proc fetchAllPkgMetas*(pkgName: string): seq[PkgRef] =
  clueCfg.fetchAllPkgMetas(pkgName)

# Toolchain helpers — Nim-specific, owned by Clue (not datpkgr)
proc resolveNimBin*(): string =
  let venvConfig = getCurrentDir() / ".env" / "venv.json"
  if fileExists(venvConfig):
    try:
      let cfg = parseFile(venvConfig)
      let nimBin = cfg["nim_bin"].getStr()
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

proc defaultToolchainFlags*(userFlags = ""): string =
  if userFlags.contains("--passC") or userFlags.contains("--passL"):
    return ""
  var parts: seq[string]
  proc check(incDir, libDir: string) =
    if dirExists(incDir):
      parts.add(" --passC:-I" & incDir)
    if dirExists(libDir):
      parts.add(" --passL:-L" & libDir)
      parts.add(" --passL:-Wl,-rpath," & libDir)
  when defined(macosx):
    check("/opt/local/include", "/opt/local/lib")
    check("/opt/homebrew/include", "/opt/homebrew/lib")
    check("/usr/local/include", "/usr/local/lib")
  elif defined(linux):
    check("/usr/local/include", "/usr/local/lib")
  result = parts.join("")

proc defaultColorsFlag*(userFlags = ""): string =
  if userFlags.contains("--colors"): "" else: " --colors:on"

proc detectNimVersion*(): string =
  let (outp, code) = execCmdEx(resolveNimBin() & " --version")
  if code != 0:
    return "2.2.10"
  for line in outp.splitLines():
    if "Nim Compiler Version" in line:
      for w in line.splitWhitespace():
        if w.len > 0 and w[0] in {'0'..'9'}:
          let parts = w.split('.')
          if parts.len >= 2:
            return if parts.len >= 3: parts[0] & "." & parts[1] & "." & parts[2]
                   else: parts[0] & "." & parts[1]
  "2.2.10"

proc checkNimConstraint*(nimble: clueNimbleParser.NimbleFile) =
  for d in nimble.requires:
    if not d.isNim: continue
    if d.constraint.kind == vcAny: continue
    let currentNim = detectNimVersion()
    try:
      let curVer = parseVersion(currentNim)
      if not curVer.satisfies(d.constraint):
        if d.constraint.kind == vcExact:
          displayError("Nim " & currentNim & " does not satisfy exact constraint " &
            $d.constraint & " — required by nimble, cannot proceed", quitProcess = true)
        else:
          displayWarning("Nim " & currentNim & " does not satisfy constraint " &
            $d.constraint & " — build may fail")
    except CatchableError:
      discard
