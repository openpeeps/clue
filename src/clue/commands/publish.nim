# Clue - publish a package to nim-lang/packages
#
# (c) 2026 George Lemon | MIT License
#          Made by Humans from OpenPeeps
#          https://github.com/openpeeps/clue

## `clue publish` — publish the package in the current directory by opening
## a pull request against https://github.com/nim-lang/packages, mirroring
## `nimble publish` (fork, append to packages.json, PR).
##
## Package repos are forge-agnostic: GitHub, GitLab (incl. nested groups),
## Bitbucket, Codeberg, sourcehut and self-hosted git remotes are accepted
## verbatim, and the URL prompt additionally understands nimble-style forge
## shorthand (`gh:`/`gl:`/`cb:`/`srht:` + `user/repo`). Only the index flow
## itself (fork + PR against nim-lang/packages) is GitHub-bound, necessarily.
##
## Auth reuses nimble's token: the `NIMBLE_GITHUB_API_TOKEN` env var first,
## then the first non-empty line of `~/.nimble/github_api_token`. The token
## is kept in memory (and inside push URLs) only — clue never writes it.

import std/[os, osproc, strutils, terminal, times, tempfiles]
import pkg/kapsis/runtime
import pkg/kapsis/interactive/prompts
import pkg/openparser/json

import ../pkgmanager/configs
import ../pkgmanager/nimbleparser

const
  packagesUpstream* = "nim-lang/packages"
  packagesUpstreamUrl* = "https://github.com/" & packagesUpstream
  packagesApiBase* = "https://api.github.com/repos/"
  packagesApiRoot* = "https://api.github.com"
  packagesDefaultBranch* = "master"
  publishTokenEnv* = "NIMBLE_GITHUB_API_TOKEN"

proc nimbleTokenPath*(): string =
  ## Path of nimble's GitHub API token file (secret — callers must never
  ## log its contents, only whether a token was found).
  getHomeDir() / ".nimble" / "github_api_token"

proc splitPublishTags*(s: string): seq[string] =
  ## Split a tag line on commas and any whitespace, dropping empties and
  ## dupes while keeping first-seen order. `"web, library  wrapper"` →
  ## `@["web", "library", "wrapper"]`.
  for part in s.split({',', ' ', '\t', '\n', '\r', '\f', '\v'}):
    let tag = part.strip()
    if tag.len > 0 and tag notin result:
      result.add(tag)

proc normalizeRepoUrl*(url: string): string =
  ## Normalize a git remote URL to its canonical `https://` form for the
  ## packages index: strips a trailing `.git`, maps scp-like
  ## `git@host:owner/repo` and `ssh://[user@]host[:port]/path` to https, and
  ## rejects URLs embedding a username or password.
  var u = url.strip()
  if u.endsWith(".git"):
    u = u[0 ..< ^4]
  u = u.strip(chars = {'/'})
  if u.startsWith("git+"):
    u = u[4 .. ^1]
  if "://" notin u and '@' in u and ':' in u:
    # scp-like syntax: [user@]host:path
    let atPos = u.find('@')
    let colonPos = u.find(':', atPos)
    let host = u[atPos + 1 ..< colonPos]
    let path = u[colonPos + 1 .. ^1].strip(chars = {'/'})
    if host.len == 0 or path.len == 0:
      raise newException(ValueError, "Cannot parse repository URL: " & url)
    return "https://" & host & "/" & path
  if u.startsWith("ssh://"):
    var rest = u["ssh://".len .. ^1]
    if '@' in rest:
      rest = rest[rest.find('@') + 1 .. ^1]
    let slashPos = rest.find('/')
    if slashPos < 0:
      raise newException(ValueError, "Cannot parse repository URL: " & url)
    var hostPort = rest[0 ..< slashPos]
    let path = rest[slashPos + 1 .. ^1].strip(chars = {'/'})
    if ':' in hostPort:
      hostPort = hostPort[0 ..< hostPort.find(':')]
    if hostPort.len == 0 or path.len == 0:
      raise newException(ValueError, "Cannot parse repository URL: " & url)
    return "https://" & hostPort & "/" & path
  if u.startsWith("http://") or u.startsWith("https://"):
    let schemeEnd = u.find("://") + 3
    let rest = u[schemeEnd .. ^1]
    let slashPos = rest.find('/')
    let authority = if slashPos < 0: rest else: rest[0 ..< slashPos]
    if '@' in authority:
      raise newException(ValueError,
        "Cannot publish the repository URL because it contains username " &
        "and/or password. Fix the remote URL. Hint: \"git remote -v\"")
    return u
  raise newException(ValueError, "Cannot parse repository URL: " & url)

proc expandForgeAlias*(s: string): string =
  ## Expand `alias:user/repo` shorthand to a canonical https URL.
  ## Known aliases: `github`/`gh`, `gitlab`/`gl`, `codeberg`/`cb`/`cberg`,
  ## `sourcehut`/`srht` (a missing `~` is auto-prefixed for sourcehut, as in
  ## nimble). Raises ValueError on unknown aliases or malformed input.
  let input = s.strip()
  let colonPos = input.find(':')
  if colonPos <= 0:
    raise newException(ValueError,
      "Invalid forge alias (expected alias:user/repo): " & s)
  let alias = input[0 ..< colonPos].toLowerAscii()
  var rest = input[colonPos + 1 .. ^1].strip(chars = {'/'})
  let host =
    case alias
    of "github", "gh": "github.com"
    of "gitlab", "gl": "gitlab.com"
    of "codeberg", "cb", "cberg": "codeberg.org"
    of "sourcehut", "srht": "git.sr.ht"
    else: raise newException(ValueError, "Unknown forge alias '" & alias &
      "'. Known aliases: github (gh), gitlab (gl), codeberg (cb), sourcehut (srht).")
  if rest.len == 0 or '/' notin rest:
    raise newException(ValueError,
      "Invalid forge alias (expected alias:user/repo): " & s)
  if host == "git.sr.ht" and not rest.startsWith('~'):
    rest = '~' & rest
  "https://" & host & "/" & rest

proc isForgeAliasShape*(s: string): bool =
  ## True when `s` looks like `alias:path` shorthand: exactly one colon, no
  ## `://`, and no `@` before the colon (scp-like `user@host:path` is a URL,
  ## not an alias — this ordering guard is what keeps the two apart).
  let input = s.strip()
  if "://" in input:
    return false
  let colonPos = input.find(':')
  if colonPos <= 0:
    return false
  if ':' in input[colonPos + 1 .. ^1]:
    return false
  if '@' in input[0 ..< colonPos]:
    return false
  true

proc resolveRepoUrl*(input: string): string =
  ## Resolve human-typed repo input: forge-alias shorthand expands first,
  ## anything else goes through normal URL normalization. Auto-detected git
  ## remote output must bypass this (it is already canonical) and call
  ## `normalizeRepoUrl` directly.
  let s = input.strip()
  if isForgeAliasShape(s):
    return expandForgeAlias(s)
  normalizeRepoUrl(s)

proc publishEntry*(name, url, description, license, web: string,
    tags: seq[string]): JsonNode =
  ## Build the packages.json entry for a package, matching the index schema.
  var tagsArr = newJArray()
  for t in tags:
    tagsArr.add(%t)
  result = %*{
    "name": name,
    "url": url,
    "method": "git",
    "tags": tagsArr,
    "description": description,
    "license": license,
    "web": web
  }

proc entryExists*(packagesJson: JsonNode, name: string): bool =
  ## True when `packages.json` (a top-level array) already holds `name`.
  if packagesJson.kind != JArray:
    return false
  for entry in packagesJson:
    if entry.kind == JObject and entry.hasKey("name") and
        entry["name"].getStr == name:
      return true
  false

proc readPublishToken*(): string =
  ## The GitHub API token for publishing: env var first, then the first
  ## non-empty line of nimble's token file. "" when none is configured.
  ## The value itself is never logged.
  if existsEnv(publishTokenEnv):
    let tok = getEnv(publishTokenEnv).strip()
    if tok.len > 0:
      return tok
  try:
    for line in readFile(nimbleTokenPath()).splitLines():
      let tok = line.strip()
      if tok.len > 0:
        return tok
  except IOError, OSError:
    discard
  ""

proc curlApi(url, token: string, payload = ""): tuple[output: string, exitCode: int] =
  ## Minimal GitHub API client over curl (same transport as registry
  ## downloads): GET by default, POST with a JSON body when `payload` is set.
  var cmd = "curl -fsSL --connect-timeout 15 -H " &
    quoteShell("Authorization: token " & token) & " -H " &
    quoteShell("Accept: application/vnd.github+json")
  if payload.len > 0:
    cmd.add(" -X POST -H " & quoteShell("Content-Type: application/json") &
      " --data " & quoteShell(payload))
  cmd.add(" " & quoteShell(url))
  execCmdEx(cmd)

proc gitHubUser*(token: string): string =
  ## Resolve the token owner (`login`) — also verifies the token works.
  let (output, code) = curlApi(packagesApiRoot & "/user", token)
  if code != 0:
    return ""
  try:
    let j = parseJson(output)
    if j.kind == JObject and j.hasKey("login"):
      return j["login"].getStr
  except CatchableError:
    discard
  ""

proc isCorrectFork(output: string): bool =
  ## True when a `GET /repos/{user}/packages` body is a fork of nim-lang/packages.
  try:
    let j = parseJson(output)
    if j.kind == JObject and j.hasKey("fork") and j["fork"].getBool:
      let parent = j["parent"]
      if parent.kind == JObject and parent.hasKey("full_name"):
        return parent["full_name"].getStr == packagesUpstream
  except CatchableError:
    discard
  false

proc ensureFork*(user, token: string): bool =
  ## Make sure `{user}/packages` is a fork of nim-lang/packages, forking
  ## first when needed. Returns false with the caller logging the reason.
  let (output, code) = curlApi(packagesApiBase & user & "/packages", token)
  if code == 0 and isCorrectFork(output):
    return true
  displayInfo("Forking " & packagesUpstream & " ...")
  let (_, forkCode) = curlApi(packagesApiBase & packagesUpstream & "/forks", token, "{}")
  if forkCode != 0:
    displayError("Unable to create fork. The access token might not have enough permissions (needs `public_repo`).", quitProcess = true)
    return false
  displayInfo("Waiting 10s to let GitHub create the fork ...")
  sleep(10_000)
  true

proc runGit(workdir, args: string): bool =
  ## Run a git command in `workdir`, echoing its output on failure.
  let (output, code) = execCmdEx("git " & args, workingDir = workdir)
  if code != 0:
    displayError("git " & args & " failed: " & output.strip(), quitProcess = false)
    return false
  true

proc createPullRequest*(token, user, branch, title, body: string): string =
  ## Open the PR against nim-lang/packages; returns its `html_url` or "".
  let payload = %*{
    "title": title,
    "head": user & ":" & branch,
    "base": packagesDefaultBranch,
    "body": body
  }
  let (output, code) = curlApi(packagesApiBase & packagesUpstream & "/pulls",
    token, $payload)
  if code != 0:
    return ""
  try:
    let j = parseJson(output)
    if j.kind == JObject and j.hasKey("html_url"):
      return j["html_url"].getStr
  except CatchableError:
    discard
  ""

proc detectRepoUrl*(): string =
  ## The current checkout's remote URL ("" when not a git checkout).
  if not dirExists(getCurrentDir() / ".git"):
    return ""
  let (output, code) = execCmdEx("git ls-remote --get-url")
  if code != 0:
    return ""
  output.strip()

proc publishCommand*(v: Values) =
  ## Publish the current package by opening a PR against nim-lang/packages.
  let yesMode = v.has("--yes") or v.has("-Y")
  let dryRun = v.has("--dry-run")

  # The package under the current path: a .nimble file is mandatory.
  let projectFs = newProjectDisk()
  let nimblePath = findNimbleFile(getCurrentDir(), getClueCfg(), projectFs)
  if nimblePath.len == 0:
    displayError("No .nimble file found in " & getCurrentDir() &
      ". `clue publish` must run inside a package directory.", quitProcess = true)
    return
  let nimble = parseNimbleFile(nimblePath)
  let pkgName = nimblePath.extractFilename.changeFileExt("")
  if pkgName.len == 0:
    displayError("Could not derive a package name from " & nimblePath, quitProcess = true)
    return
  if nimble.description.strip().len == 0:
    displayError("The .nimble file has no `description` — refusing to publish an undescribed package.", quitProcess = true)
    return
  if nimble.license.strip().len == 0:
    displayError("The .nimble file has no `license` — refusing to publish an unlicensed package.", quitProcess = true)
    return

  # Repository URL: local remote first, prompt as fallback.
  var url = ""
  let detected = detectRepoUrl()
  if detected.len > 0:
    try:
      url = normalizeRepoUrl(detected)
    except ValueError as e:
      displayError(e.msg, quitProcess = true)
      return
  if url.len == 0:
    if not yesMode and not isatty(stdout):
      displayError("Could not detect a git remote. Pass the URL interactively from a terminal.", quitProcess = true)
      return
    let typed = prompt("Repository URL of " & pkgName & " (or forge alias like gl:user/repo)").strip()
    if typed.len == 0:
      displayInfo("Cancelled.")
      quit(0)
    try:
      # Human-typed input: forge shorthand expands, anything else normalizes.
      url = resolveRepoUrl(typed)
    except ValueError as e:
      displayError(e.msg, quitProcess = true)
      return

  # Tags: flag or prompt; comma- and whitespace-separated alike.
  var tags: seq[string]
  if v.has("--tags"):
    tags = splitPublishTags(v.get("--tags").getStr)
  else:
    if not isatty(stdout):
      displayError("No `--tags` given and no interactive terminal. Re-run with `--tags:\"web, library\"`.", quitProcess = true)
      return
    tags = splitPublishTags(prompt(
      "Comma or space separated list of tags? (For example: web library wrapper)"))
  if tags.len == 0:
    displayError("At least one tag is required to publish.", quitProcess = true)
    return

  let web =
    if v.has("--web"): v.get("--web").getStr.strip()
    else: url
  if web.len == 0:
    displayError("Empty `--web` URL.", quitProcess = true)
    return

  let entry = publishEntry(pkgName, url, nimble.description.strip(),
    nimble.license.strip(), web, tags)
  let branchName = "add-" & pkgName & "-" & getTime().utc.format("HHmm")

  if dryRun:
    displayInfo("Dry run — no network or git changes made.")
    displayInfo("Package entry:")
    echo pretty(entry)
    displayInfo("Would fork " & packagesUpstreamUrl & ", append the entry to " &
      "packages.json on branch " & branchName & ", push, and open a PR against " &
      packagesDefaultBranch & ".")
    displaySuccess("Dry run complete")
    return

  # Auth only past this point: dry runs stay fully offline.
  let token = readPublishToken()
  if token.len == 0:
    displayError("No GitHub API token found. Set the " & publishTokenEnv &
      " environment variable or create " & nimbleTokenPath() &
      " (one token per line, first non-empty line is used).", quitProcess = true)
    return
  let user = gitHubUser(token)
  if user.len == 0:
    displayError("Could not verify the GitHub API token (GET /user failed). Check the token and network.", quitProcess = true)
    return
  displaySuccess("Verified as " & user)

  if not yesMode:
    if not isatty(stdout):
      displayError("`clue publish` needs confirmation; re-run with --yes in non-interactive environments.", quitProcess = true)
      return
    if not promptConfirm("Open a pull request adding " & pkgName & " to " & packagesUpstream & "?"):
      displayInfo("Cancelled.")
      quit(0)

  if not ensureFork(user, token):
    return
  let workdir = createTempDir("clue-publish-", "")
  try:
    if not runGit(workdir, "init -q"): return
    if not runGit(workdir, "checkout -q -b " & packagesDefaultBranch): return
    displayInfo("Fetching your fork ...")
    if not runGit(workdir, "pull -q https://github.com/" & user & "/packages"): return
    displayInfo("Syncing with upstream ...")
    if not runGit(workdir, "pull -q " & packagesUpstreamUrl & ".git " & packagesDefaultBranch): return
    # NB: the token travels inside the push URL (never stored in the repo,
    # same as nimble); git redacts credentials from any echoed errors, and
    # runGit only echoes output on failure.
    if not runGit(workdir, "push -q https://" & token & "@github.com/" & user &
        "/packages " & packagesDefaultBranch):
      return
    let pkgsFile = workdir / "packages.json"
    if not fileExists(pkgsFile):
      displayError("No packages.json found in the fork.", quitProcess = true)
      return
    var packagesJson: JsonNode
    try:
      packagesJson = parseJson(readFile(pkgsFile))
    except CatchableError as e:
      displayError("Could not parse packages.json: " & e.msg, quitProcess = true)
      return
    if packagesJson.kind != JArray:
      displayError("packages.json is not a top-level array.", quitProcess = true)
      return
    if entryExists(packagesJson, pkgName):
      displayError("Package '" & pkgName & "' is already listed in packages.json.", quitProcess = true)
      return
    packagesJson.add(entry)
    writeFile(pkgsFile, pretty(packagesJson))
    if not runGit(workdir, "checkout -q -B " & branchName): return
    if not runGit(workdir, "commit -q packages.json -m " &
        quoteShell("Added package " & pkgName)): return
    displayInfo("Pushing branch " & branchName & " ...")
    if not runGit(workdir, "push -q https://" & token & "@github.com/" & user &
        "/packages " & branchName):
      return
    displayInfo("Creating pull request ...")
    let prUrl = createPullRequest(token, user, branchName,
      "Add package " & pkgName, nimble.description.strip() & "\n\n" & url)
    if prUrl.len == 0:
      displayError("Pull request creation failed.", quitProcess = true)
      return
    displaySuccess("Pull request opened: " & prUrl)
  finally:
    try: removeDir(workdir)
    except OSError, IOError: discard
