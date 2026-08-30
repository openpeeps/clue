# Shim - delegates to datpkgr (language-agnostic) with Clue's .nimble entry via clueCfg
import std/[os, strutils, tables, sets, sequtils, json, options, times]
import pkg/semver
import datpkgr/versions as dv
import datpkgr/git as dg
import datpkgr/types
import datpkgr/config
import datpkgr/install as di
import ./configs as clueConfigs
import ./nimbleparser

export dv.DiscoveredVersion
export types
export di.InstalledRecord
export nimbleparser.NimbleFile
export nimbleparser.NimbleDependency

proc toGitSshUrl*(url: string): string = dg.toGitSshUrl(url)

proc tagForVersion*(dest: string, version: string): string = dv.tagForVersion(dest, version)

proc cachedVersions*(name: string): seq[DiscoveredVersion] = dv.cachedVersions(clueConfigs.clueCfg, name)
proc discoverVersions*(name, url: string, refresh = false, cloneOnMiss = true): seq[DiscoveredVersion] =
  dv.discoverVersions(clueConfigs.clueCfg, name, url, refresh, cloneOnMiss)
proc discoverVersionsBatch*(pkgs: openArray[PkgRef], refresh = false, onDone: proc(name: string, versions: int, cached: bool) = nil): Table[string, seq[DiscoveredVersion]] =
  dv.discoverVersionsBatch(clueConfigs.clueCfg, pkgs, refresh, onDone)
proc headVersion*(name: string): Version = dv.headVersion(clueConfigs.clueCfg, name)

# Dep cache
proc getDeps*(name, version: string, features: seq[string] = @[], refresh = false, url = ""): seq[PkgDependency] =
  dv.getDeps(clueConfigs.clueCfg, name, version, features, refresh, url)

# Git ops via datpkgr/git with clueCfg
proc clonePackage*(url, dest: string, refresh = false, nonInteractive = false): bool =
  dg.clonePackage(clueConfigs.clueCfg, url, dest, refresh, nonInteractive)
proc checkoutTag*(dest, tag: string): bool = dg.checkoutTag(clueConfigs.clueCfg, dest, tag)
proc checkoutHead*(dest: string, refresh = false): bool = dg.checkoutHead(clueConfigs.clueCfg, dest, refresh)
proc checkoutRef*(dest, refStr: string, refresh = false): bool = dg.checkoutRef(clueConfigs.clueCfg, dest, refStr, refresh)
proc checkoutTagRaw*(dest, tag: string): bool {.gcsafe.} = dg.checkoutTagRaw(dest, tag)
proc checkoutHeadRaw*(dest: string, refresh = false): bool {.gcsafe.} = dg.checkoutHeadRaw(dest, refresh)
proc checkoutRefRaw*(dest, refStr: string, refresh = false): bool {.gcsafe.} = dg.checkoutRefRaw(dest, refStr, refresh)
proc gitHeadInfo*(name, url: string): Option[dg.GitHeadInfo] = dg.gitHeadInfo(clueConfigs.clueCfg, name, url)

proc recordInstall*(name, version: string, deps: seq[types.DepEntry], root = false, features: seq[string] = @[], installPath = "") =
  di.recordInstall(clueConfigs.clueCfg, name, version, deps, root, features, installPath)
proc installedPath*(name, version: string): string = di.installedPath(clueConfigs.clueCfg, name, version)
proc resolveInstalledPath*(name, preferRef: string): string = di.resolveInstalledPath(clueConfigs.clueCfg, name, preferRef)
proc installedRecords*(name: string): seq[di.InstalledRecord] = di.installedRecords(clueConfigs.clueCfg, name)
proc isDevInstall*(rec: di.InstalledRecord): bool = di.isDevInstall(clueConfigs.clueCfg, rec)
proc installedRoots*(): seq[string] = di.installedRoots(clueConfigs.clueCfg)
proc collectInstalledDepNames*(rootNames: seq[string]): seq[string] = di.collectInstalledDepNames(clueConfigs.clueCfg, rootNames)
proc allInstalledPaths*(): seq[string] = di.allInstalledPaths(clueConfigs.clueCfg)
proc installedFeatures*(): Table[string, seq[string]] = di.installedFeatures(clueConfigs.clueCfg)
proc unrecordInstall*(name, version: string) = di.unrecordInstall(clueConfigs.clueCfg, name, version)
proc pruneOrphans*(verbose = true) = di.pruneOrphans(clueConfigs.clueCfg, verbose)
proc installedCount*(): int = di.installedCount(clueConfigs.clueCfg)

# Expose devShadowWarningsEnabled as alias to datpkgr/install's var so manager's assignments propagate
template devShadowWarningsEnabled*(): var bool = di.devShadowWarningsEnabled
