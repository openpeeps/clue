# Clue deploy init — unit tests for the `clue.deploy.yaml` template.

import std/[strutils, unittest]
import clue/deploy/init

suite "deploy init — buildDeployYaml":
  test "bin type ships web with systemd plus binary and assets dir profiles":
    let y = buildDeployYaml("myapp", "bin", "1.0.0", "example.com", "deploy", "/srv/myapp")
    check "type: bin" in y
    check "systemd:" in y
    check "service: \"myapp\"" in y
    check "binary:" in y
    check "from: \"bin\"" in y
    check "# assets:" in y
    check "#   to: \"/srv/myapp/assets\"" in y
    check "host: \"example.com\"" in y
    check "user: \"deploy\"" in y
    check "to: \"/srv/myapp\"" in y
    check "github" notin y
    check "workflow" notin y

  test "bin type with empty remoteDir leaves assets target empty":
    let y = buildDeployYaml("myapp", "bin", "1.0.0", "", "", "")
    check "#   to: \"\"" in y

  test "static type ships dir plus web without systemd":
    let y = buildDeployYaml("site", "static", "0.2.0", "example.com", "deploy", "/srv/www")
    check "type: static" in y
    check "systemd:" notin y
    check "from: \"dist/site\"" in y
    check "localDir: dist/site" in y
    check "host: \"example.com\"" in y
    check "to: \"/srv/www\"" in y
    check "github" notin y
