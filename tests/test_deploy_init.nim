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

  test "bin type keeps the release block commented without a repo":
    let y = buildDeployYaml("myapp", "bin", "1.0.0", "example.com", "deploy", "/srv/myapp")
    check "# release:" in y
    check "#   repo: \"owner/myapp\"" in y
    check "#   asset: \"myapp_linux-x86_64.tar.gz\"" in y
    check "\nrelease:" notin y

  test "bin type activates the release block with a repo":
    let y = buildDeployYaml("myapp", "bin", "1.0.0", "example.com", "deploy",
      "/srv/myapp", "acme/myapp")
    check "\n      release:" in y
    check "repo: \"acme/myapp\"" in y
    check "asset: \"myapp_linux-x86_64.tar.gz\"" in y
    check "mode: local" in y
    check "binary: \"myapp\"" in y
    check "# release:" notin y

  test "static type ships dir plus web without systemd":
    let y = buildDeployYaml("site", "static", "0.2.0", "example.com", "deploy", "/srv/www")
    check "type: static" in y
    check "systemd:" notin y
    check "from: \"dist/site\"" in y
    check "localDir: dist/site" in y
    check "host: \"example.com\"" in y
    check "to: \"/srv/www\"" in y
    check "github" notin y

  test "web profiles carry a commented steps example":
    for deployType in ["bin", "static"]:
      let y = buildDeployYaml("myapp", deployType, "1.0.0", "example.com",
        "deploy", "/srv/myapp")
      check "#      steps:" in y
      check "run: \"whoami\"" in y
      check "\n      steps:" notin y
