# Clue - facade over datpkgr (app-agnostic library)
#
# (c) 2026 George Lemon | MIT License
# This file is now a thin wrapper that delegates to datpkgr.
# All filesystem is via flysystem single LocalDriver at ~/.clue,
# callbacks replace kapsis, and manifest is pluggable (.nimble for Clue).

import std/[os, osproc, strutils, options, terminal]
import pkg/boogie/stores/rdbms
import pkg/flysystem
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

proc clueLog*(level: LogLevel, msg: string) {.gcsafe.} =
  if msg == "":
    display("")
    return
  # indented package lines (e.g. "  semver@1.2.3") should be plain display, no Info prefix
  # color "#HEAD" suffix in blue; tree lines (with ├─/└─/│+ v) should be cyan
  if msg.len >= 2 and msg[0] == ' ' and msg[1] == ' ':
    let isCached = " (cached)" in msg or " using HEAD" in msg or " (cached" in msg or "fetched " in msg
    # tree has box chars or " v<digit>" (version) — plain " v" would misclassify "  valido@…" (v-name)
    var hasVersion = false
    var idx = 0
    while idx < msg.len - 1:
      if msg[idx] == ' ' and msg[idx+1] == 'v' and idx+2 < msg.len and msg[idx+2] in {'0'..'9'}:
        hasVersion = true
        break
      inc idx
    let isTree = not isCached and ("├─" in msg or "└─" in msg or "│" in msg or hasVersion)
    let headIdx = msg.find("#HEAD")
    if headIdx >= 0:
      let prefix = msg[0 ..< headIdx]
      let suffix = if headIdx + 5 < msg.len: msg[headIdx + 5 .. ^1] else: ""
      let baseFg = if isTree: terminal.fgCyan else: DefaultTextFg
      display(@[span(prefix, baseFg, indentSize = 0),
                span("#HEAD", terminal.fgBlue, indentSize = 0),
                span(suffix, baseFg, indentSize = 0)])
    else:
      if isTree:
        display(span(msg, terminal.fgCyan))
      else:
        # special styling for indented non-tree lines
        # 1) "  name (cached)" -> "(cached)" cyan
        let cachedIdx = msg.find(" (cached)")
        if cachedIdx >= 0:
          let prefix = msg[0 ..< cachedIdx]
          let suffix = msg[cachedIdx .. ^1]
          display(@[span(prefix, DefaultTextFg, indentSize = 0),
                    span(suffix, terminal.fgCyan, indentSize = 0)])
          return
        # 2) "  fetched <name> using HEAD" -> chevron prefix, HEAD green
        #    "  fetched <name> (N version(s))" -> parenthesized part green
        let fetchedIdx = msg.find("fetched ")
        if fetchedIdx >= 0:
          let usingHeadIdx = msg.find(" using HEAD")
          if usingHeadIdx >= 0:
            let leading = msg[0 ..< fetchedIdx]
            let namePart = msg[fetchedIdx + "fetched ".len ..< usingHeadIdx]
            display(@[span(leading, DefaultTextFg, indentSize = 0),
                      span("→ ", DefaultTextFg, indentSize = 0),
                      span("fetched ", terminal.fgCyan, indentSize = 0),
                      span(namePart, DefaultTextFg, indentSize = 0),
                      span(" using ", terminal.fgCyan, indentSize = 0),
                      span("HEAD", terminal.fgGreen, indentSize = 0)])
            return
          let parenIdx = msg.find(" (", fetchedIdx)
          if parenIdx >= 0:
            let prefix = msg[0 ..< parenIdx]
            let suffix = msg[parenIdx .. ^1]
            # prefix needs chevron inserted after leading spaces
            let leading = prefix[0 ..< fetchedIdx]
            let restPrefix = prefix[fetchedIdx .. ^1]
            display(@[span(leading, DefaultTextFg, indentSize = 0),
                      span("> ", DefaultTextFg, indentSize = 0),
                      span(restPrefix, DefaultTextFg, indentSize = 0),
                      span(suffix, terminal.fgGreen, indentSize = 0)])
            return
          # fallback: just add chevron
          let leading = msg[0 ..< fetchedIdx]
          let rest = msg[fetchedIdx .. ^1]
          display(@[span(leading, DefaultTextFg, indentSize = 0),
                    span("> ", DefaultTextFg, indentSize = 0),
                    span(rest, DefaultTextFg, indentSize = 0)])
          return
        # 3) "  pkg@version" -> version green
        let atIdx = msg.find("@")
        if atIdx >= 0:
          let prefix = msg[0 .. atIdx] # includes "@"
          let verPart = if atIdx + 1 < msg.len: msg[atIdx+1 .. ^1] else: ""
          display(@[span(prefix, DefaultTextFg, indentSize = 0),
                    span(verPart, indentSize = 0)])
          return
        display(msg)
    return
  # Dependency tree: header via displayInfo (cyan label), tree body cyan
  if msg == "Dependency tree":
    displayInfo(msg)
    return
  if level == lvlInfo and ("├─" in msg or "└─" in msg or "│" in msg or ( block:
    var hasV = false
    var ii = 0
    while ii < msg.len - 1:
      if msg[ii] == ' ' and msg[ii+1] == 'v' and ii+2 < msg.len and msg[ii+2] in {'0'..'9'}:
        hasV = true
        break
      inc ii
    hasV )):
    # keep entire tree line cyan, but keep #HEAD blue if present
    let headIdx = msg.find("#HEAD")
    if headIdx >= 0:
      let prefix = msg[0 ..< headIdx]
      let suffix = if headIdx + 5 < msg.len: msg[headIdx + 5 .. ^1] else: ""
      display(@[span(prefix, terminal.fgCyan, indentSize = 0),
                span("#HEAD", terminal.fgBlue, indentSize = 0),
                span(suffix, terminal.fgCyan, indentSize = 0)])
    else:
      display(span(msg, terminal.fgCyan))
    return
  if level == lvlInfo and (msg == "No orphaned packages to prune" or msg.startsWith("Pruned ")):
    displaySuccess(msg)
    return
  case level
  of lvlDebug: displayInfo(msg)
  of lvlInfo: displayInfo(msg)
  of datpkgrConfig.lvlSuccess: displaySuccess(msg)
  of lvlWarn: displayWarning(msg)
  of lvlError: displayError(msg)

proc getClueCfg*(): DatpkgrConfig =
  if clueCfgImpl.isNil:
    clueCfgImpl = newDatpkgrConfig("clue", callbacks = Callbacks(log: clueLog))
    clueCfgImpl.withNimbleSupport(clueNimbleParser.nimbleManifestParser)
  clueCfgImpl

template clueCfg*(): DatpkgrConfig = getClueCfg()

proc newProjectDisk*(dir = getCurrentDir()): Filesystem =
  ## Temporary readonly disk for the local project at `dir`.
  ## Created once per command that needs `getCurrentDir()`.
  ## Must be run from the package root (where .nimble lives).
  result = newFilesystem("project")
  result.addDisk("project", newLocalDriver(dir), PolicyRules(readOnly: true))

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
