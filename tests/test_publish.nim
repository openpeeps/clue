# Clue commands/publish — unit tests for the pure helpers behind
# `clue publish`: tag splitting, repo URL normalization, packages.json
# entry building and duplicate detection. Network/git flows are covered
# by `--dry-run` only, never by live fixtures here.

import std/[unittest, json]
import clue/commands/publish

suite "publish — splitPublishTags":
  test "comma separated":
    check splitPublishTags("web,library,wrapper") == @["web", "library", "wrapper"]

  test "space separated":
    check splitPublishTags("web library wrapper") == @["web", "library", "wrapper"]

  test "mixed commas, spaces and tabs":
    check splitPublishTags("web, library\twrapper ,  algo") ==
      @["web", "library", "wrapper", "algo"]

  test "drops empties and dupes, keeps order":
    check splitPublishTags("web,, web  ,library,web") == @["web", "library"]

  test "empty input yields no tags":
    check splitPublishTags("") == newSeq[string]()
    check splitPublishTags(" ,  , ") == newSeq[string]()

suite "publish — normalizeRepoUrl":
  test "https URL passes through, .git stripped":
    check normalizeRepoUrl("https://github.com/nimbase/nbrotli.git") ==
      "https://github.com/nimbase/nbrotli"
    check normalizeRepoUrl("https://github.com/nimbase/nbrotli") ==
      "https://github.com/nimbase/nbrotli"

  test "scp-like ssh URL becomes https":
    check normalizeRepoUrl("git@github.com:nimbase/nbrotli.git") ==
      "https://github.com/nimbase/nbrotli"
    check normalizeRepoUrl("git@github.com:nimbase/nbrotli") ==
      "https://github.com/nimbase/nbrotli"

  test "ssh:// URL becomes https":
    check normalizeRepoUrl("ssh://git@github.com/nimbase/nbrotli.git") ==
      "https://github.com/nimbase/nbrotli"

  test "embedded credentials are rejected":
    expect ValueError:
      discard normalizeRepoUrl("https://user:secret@github.com/nimbase/nbrotli")
    expect ValueError:
      discard normalizeRepoUrl("https://user@github.com/nimbase/nbrotli")

  test "garbage is rejected":
    expect ValueError:
      discard normalizeRepoUrl("not a url at all !!!")
    expect ValueError:
      discard normalizeRepoUrl("")

suite "publish — normalizeRepoUrl across forges":
  test "GitLab nested groups, scp and https":
    check normalizeRepoUrl("git@gitlab.com:group/sub/repo.git") ==
      "https://gitlab.com/group/sub/repo"
    check normalizeRepoUrl("https://gitlab.com/group/sub/repo.git") ==
      "https://gitlab.com/group/sub/repo"

  test "GitLab ssh:// with port":
    check normalizeRepoUrl("ssh://git@gitlab.com:2222/group/repo.git") ==
      "https://gitlab.com/group/repo"

  test "Bitbucket scp and https":
    check normalizeRepoUrl("git@bitbucket.org:owner/repo.git") ==
      "https://bitbucket.org/owner/repo"
    check normalizeRepoUrl("https://bitbucket.org/owner/repo") ==
      "https://bitbucket.org/owner/repo"

  test "Codeberg scp":
    check normalizeRepoUrl("git@codeberg.org:user/repo.git") ==
      "https://codeberg.org/user/repo"

  test "sourcehut scp keeps the tilde":
    check normalizeRepoUrl("git@git.sr.ht:~user/repo") ==
      "https://git.sr.ht/~user/repo"

  test "self-hosted https passes through":
    check normalizeRepoUrl("https://git.example.com:8443/team/repo.git") ==
      "https://git.example.com:8443/team/repo"

suite "publish — forge aliases":
  test "all forges expand":
    check expandForgeAlias("github:nimbase/nbrotli") ==
      "https://github.com/nimbase/nbrotli"
    check expandForgeAlias("gh:nimbase/nbrotli") ==
      "https://github.com/nimbase/nbrotli"
    check expandForgeAlias("gitlab:group/sub/repo") ==
      "https://gitlab.com/group/sub/repo"
    check expandForgeAlias("gl:group/sub/repo") ==
      "https://gitlab.com/group/sub/repo"
    check expandForgeAlias("codeberg:user/repo") ==
      "https://codeberg.org/user/repo"
    check expandForgeAlias("cb:user/repo") ==
      "https://codeberg.org/user/repo"
    check expandForgeAlias("sourcehut:user/repo") ==
      "https://git.sr.ht/~user/repo"
    check expandForgeAlias("srht:~user/repo") ==
      "https://git.sr.ht/~user/repo"

  test "unknown aliases and bad shapes raise":
    expect ValueError:
      discard expandForgeAlias("gitea:user/repo")
    expect ValueError:
      discard expandForgeAlias("gl:lonely")
    expect ValueError:
      discard expandForgeAlias("nocolon")

  test "alias shape detection never fires on real URLs":
    check isForgeAliasShape("gl:user/repo")
    check not isForgeAliasShape("https://gitlab.com/user/repo")
    check not isForgeAliasShape("git@gitlab.com:user/repo")
    check not isForgeAliasShape("git@github.com:owner/repo")
    check not isForgeAliasShape("owner/repo")
    check not isForgeAliasShape("")

  test "resolveRepoUrl routes aliases and URLs":
    check resolveRepoUrl("gl:group/repo") ==
      "https://gitlab.com/group/repo"
    check resolveRepoUrl("https://gitlab.com/group/repo.git") ==
      "https://gitlab.com/group/repo"
    check resolveRepoUrl("git@bitbucket.org:owner/repo.git") ==
      "https://bitbucket.org/owner/repo"
    expect ValueError:
      discard resolveRepoUrl("gitea:user/repo")

suite "publish — publishEntry":
  test "builds the index entry schema":
    let entry = publishEntry("nbrotli", "https://github.com/nimbase/nbrotli",
      "Pure Nim Brotli compressor/decompressor", "MIT",
      "https://github.com/nimbase/nbrotli",
      @["compressor", "brotli"])
    check entry["name"].getStr == "nbrotli"
    check entry["url"].getStr == "https://github.com/nimbase/nbrotli"
    check entry["method"].getStr == "git"
    check entry["tags"].len == 2
    check entry["tags"][0].getStr == "compressor"
    check entry["tags"][1].getStr == "brotli"
    check entry["description"].getStr == "Pure Nim Brotli compressor/decompressor"
    check entry["license"].getStr == "MIT"
    check entry["web"].getStr == "https://github.com/nimbase/nbrotli"

suite "publish — entryExists":
  test "finds existing names, misses others":
    let arr = %*[
      {"name": "nbrotli", "url": "https://github.com/nimbase/nbrotli"},
      {"name": "tim", "url": "https://github.com/tim-engine/tim"}
    ]
    check entryExists(arr, "tim")
    check not entryExists(arr, "kapsis")
    check not entryExists(newJArray(), "kapsis")
    check not entryExists(%*{"name": "tim"}, "other")
