# Clue deploy init — unit tests for git-repo URL normalization (the only
# pure, exported helper; the yaml/workflow builders are private).

import std/unittest
import clue/deploy/init

suite "deploy init — parseGitRepo":
  test "https url becomes owner/repo":
    check parseGitRepo("https://github.com/openpeeps/clue.git") == "openpeeps/clue"
    check parseGitRepo("https://github.com/openpeeps/clue") == "openpeeps/clue"

  test "scp-like ssh url":
    check parseGitRepo("git@github.com:openpeeps/clue.git") == "openpeeps/clue"

  test "ssh:// and git+ urls":
    check parseGitRepo("ssh://git@github.com/openpeeps/clue.git") == "openpeeps/clue"
    check parseGitRepo("git+https://github.com/openpeeps/clue.git") == "openpeeps/clue"

  test "empty and degenerate input":
    check parseGitRepo("") == ""
    check parseGitRepo("notaurl") == ""
