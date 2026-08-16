# Clue commands/manager — unit tests for the exported pure helper
# functions: URL → package-name derivation, feature flag parsing, git URL
# detection and pluralization.

import std/unittest
import clue/commands/manager

suite "manager — pkgNameFromUrl":
  test "github https url":
    check pkgNameFromUrl("https://github.com/openpeeps/spry") == "spry"
    check pkgNameFromUrl("https://github.com/openpeeps/spry.git") == "spry"

  test "scp-like ssh url":
    check pkgNameFromUrl("git@github.com:openpeeps/spry.git") == "spry"

  test "git+ and ssh:// urls":
    check pkgNameFromUrl("git+https://github.com/openpeeps/spry.git") == "spry"
    check pkgNameFromUrl("ssh://git@github.com/openpeeps/spry.git") == "spry"

  test "ref and query suffixes are stripped":
    check pkgNameFromUrl("https://github.com/openpeeps/spry#master") == "spry"
    check pkgNameFromUrl("https://github.com/openpeeps/spry?ref=main") == "spry"

  test "url with a path deeper than owner/repo takes the last segment":
    check pkgNameFromUrl("https://github.com/openpeeps/awesome/spry") == "spry"

suite "manager — parseFeatureFlags":
  test "splits comma-separated flags and strips whitespace":
    check parseFeatureFlags("ssl,jwt") == @["ssl", "jwt"]
    check parseFeatureFlags("ssl, jwt, async") == @["ssl", "jwt", "async"]

  test "empty input yields no flags":
    check parseFeatureFlags("") == newSeq[string]()
    check parseFeatureFlags(",") == newSeq[string]()

suite "manager — isGitUrl":
  test "recognises git urls":
    check isGitUrl("https://github.com/openpeeps/spry")
    check isGitUrl("http://github.com/openpeeps/spry")
    check isGitUrl("git@github.com:openpeeps/spry.git")
    check isGitUrl("git+https://github.com/openpeeps/spry")
    check isGitUrl("ssh://git@github.com/openpeeps/spry.git")

  test "rejects plain package names":
    check not isGitUrl("spry")
    check not isGitUrl("spry@1.2.0")
    check not isGitUrl("/usr/local/spry")

suite "manager — pluralize":
  test "singular for 1, plural otherwise":
    check pluralize(1, "version") == "version"
    check pluralize(0, "version") == "versions"
    check pluralize(2, "version") == "versions"
    check pluralize(10, "package") == "packages"
