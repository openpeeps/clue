# Clue - An alternative package manager for Nim development
#
# (c) 2026 George Lemon | MIT License
#          Made by Humans from OpenPeeps
#          https://github.com/openpeeps/clue

## Shim that delegates to the language-agnostic `datpkgr` kit.
##
## `datpkgr` owns all version discovery, git operations and install
## bookkeeping. This module binds it to Clue's configuration
## (`clueCfg`) and re-exports the types that the rest of Clue
## expects, so call-sites do not need to thread `DatpkgrConfig`
## through every layer. For the canonical logic see
## `~/.clue/develop/datpkgr/src/datpkgr/versions.nim`.

# 
# Imports
# 

import std/[os, strutils, tables, sets, sequtils, json, options, times]
import pkg/semver
import datpkgr/versions as dv
import datpkgr/git as dg
import datpkgr/types
import datpkgr/config
import datpkgr/install as di
import ./configs as clueConfigs
import ./nimbleparser

# 
# Re-exports
# 
# Keep public surface identical to the former in-tree implementation
# so consumers can `import pkgmanager/versions` without knowing about
# the `datpkgr` split.

export dv.DiscoveredVersion
export types
export di.InstalledRecord
export nimbleparser.NimbleFile
export nimbleparser.NimbleDependency

# 
# Git URL helpers
# 

proc toGitSshUrl*(url: string): string =
  ## Convert an `https://` remote into the scp-like `git@host:path.git`
  ## form used for SSH fetches. Delegates to `datpkgr/git`.
  dg.toGitSshUrl(url)

proc tagForVersion*(dest: string, version: string): string =
  ## Return the git tag that corresponds to `version` inside `dest`,
  ## or "" if none matches. Reads `.git/packed-refs` and
  ## `refs/tags` directly without spawning git.
  dv.tagForVersion(dest, version)

# 
# Version discovery
# 

proc cachedVersions*(name: string): seq[DiscoveredVersion] =
  ## Versions already cached on disk for `name`.
  dv.cachedVersions(clueConfigs.clueCfg, name)

proc discoverVersions*(
    name, url: string, refresh = false, cloneOnMiss = true
): seq[DiscoveredVersion] =
  ## Discover available versions for `name` from `url`, using the
  ## on-disk cache and falling back to `git ls-remote` when needed.
  dv.discoverVersions(clueConfigs.clueCfg, name, url, refresh, cloneOnMiss)

proc discoverVersionsBatch*(
    pkgs: openArray[PkgRef],
    refresh = false,
    onDone: proc(name: string, versions: int, cached: bool) = nil,
): Table[string, seq[DiscoveredVersion]] =
  ## Parallel version discovery for a batch of packages.
  dv.discoverVersionsBatch(clueConfigs.clueCfg, pkgs, refresh, onDone)

proc headVersion*(name: string): Version =
  ## Best-effort current version for `name` from the version cache.
  dv.headVersion(clueConfigs.clueCfg, name)

# 
# Dependency cache
# 

proc getDeps*(
    name, version: string,
    features: seq[string] = @[],
    refresh = false,
    url = "",
): seq[PkgDependency] =
  ## Direct dependencies of `name@version`, optionally filtered by
  ## `features`. Results are memoized on disk via `datpkgr`.
  dv.getDeps(clueConfigs.clueCfg, name, version, features, refresh, url)

# 
# Git operations (via datpkgr/git with clueCfg)
# 

proc clonePackage*(
    url, dest: string, refresh = false, nonInteractive = false
): bool =
  ## Clone or update `url` into `dest`. Honors `clueCfg` callbacks
  ## for logging and progress.
  dg.clonePackage(clueConfigs.clueCfg, url, dest, refresh, nonInteractive)

proc checkoutTag*(dest, tag: string): bool =
  dg.checkoutTag(clueConfigs.clueCfg, dest, tag)

proc checkoutHead*(dest: string, refresh = false): bool =
  dg.checkoutHead(clueConfigs.clueCfg, dest, refresh)

proc checkoutRef*(dest, refStr: string, refresh = false): bool =
  dg.checkoutRef(clueConfigs.clueCfg, dest, refStr, refresh)

proc checkoutTagRaw*(dest, tag: string): bool {.gcsafe.} =
  ## Low-level checkout without touching `clueCfg` (usable off main thread).
  dg.checkoutTagRaw(dest, tag)

proc checkoutHeadRaw*(dest: string, refresh = false): bool {.gcsafe.} =
  dg.checkoutHeadRaw(dest, refresh)

proc checkoutRefRaw*(dest, refStr: string, refresh = false): bool {.gcsafe.} =
  dg.checkoutRefRaw(dest, refStr, refresh)

proc gitHeadInfo*(name, url: string): Option[dg.GitHeadInfo] =
  dg.gitHeadInfo(clueConfigs.clueCfg, name, url)

# 
# Install bookkeeping (via datpkgr/install with clueCfg)
# 

proc recordInstall*(
    name, version: string,
    deps: seq[types.DepEntry],
    root = false,
    features: seq[string] = @[],
    installPath = "",
) =
  di.recordInstall(clueConfigs.clueCfg, name, version, deps, root, features, installPath)

proc installedPath*(name, version: string): string =
  di.installedPath(clueConfigs.clueCfg, name, version)

proc resolveInstalledPath*(name, preferRef: string): string =
  di.resolveInstalledPath(clueConfigs.clueCfg, name, preferRef)

proc installedRecords*(name: string): seq[di.InstalledRecord] =
  di.installedRecords(clueConfigs.clueCfg, name)

proc isDevInstall*(rec: di.InstalledRecord): bool =
  di.isDevInstall(clueConfigs.clueCfg, rec)

proc installedRoots*(): seq[string] =
  di.installedRoots(clueConfigs.clueCfg)

proc collectInstalledDepNames*(rootNames: seq[string]): seq[string] =
  di.collectInstalledDepNames(clueConfigs.clueCfg, rootNames)

proc allInstalledPaths*(): seq[string] =
  di.allInstalledPaths(clueConfigs.clueCfg)

proc installedFeatures*(): Table[string, seq[string]] =
  di.installedFeatures(clueConfigs.clueCfg)

proc unrecordInstall*(name, version: string) =
  di.unrecordInstall(clueConfigs.clueCfg, name, version)

proc pruneOrphans*(verbose = true) =
  di.pruneOrphans(clueConfigs.clueCfg, verbose)

proc installedCount*(): int =
  di.installedCount(clueConfigs.clueCfg)

# 
# Global flags
# 

# Expose `devShadowWarningsEnabled` as alias to `datpkgr/install`'s
# var so assignments in `manager` propagate to the shared kit.
template devShadowWarningsEnabled*(): var bool =
  di.devShadowWarningsEnabled
