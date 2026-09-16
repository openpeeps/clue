# Clue deploy configs — unit tests for `clue.deploy.yaml` / `.json`
# parsing, default filling, path expansion and the option helpers.

import std/[os, options, strutils, tables, unittest]
import clue/deploy/configs

proc writeTemp(name: string, content: string): string =
  let dir: string = getTempDir() / "clue_deploy_configs" / $getCurrentProcessId()
  createDir(dir)
  let path: string = dir / name
  writeFile(path, content)
  path

suite "deploy configs — defaults":
  test "compressOn/partialOn default to true":
    check compressOn(WebProfile()) == true
    check partialOn(WebProfile()) == true
    check compressOn(WebProfile(compress: some(false))) == false

  test "systemd option helpers default to true":
    check sdDaemonReload(SystemdConfig()) == true
    check sdRestart(SystemdConfig()) == true
    check sdSudo(SystemdConfig()) == true
    check sdStatus(SystemdConfig()) == true
    check sdRestart(SystemdConfig(restart: some(false))) == false

suite "deploy configs — expandPath":
  test "expands leading tilde":
    let p = expandPath("~/foo/bar")
    # expandPath does a raw string concat (getHomeDir() & "foo/bar"), so the
    # separators may differ from the normalized `\` path on Windows — compare
    # both sides with a normalized separator.
    check p.replace('\\', '/') == (getHomeDir() / "foo/bar").replace('\\', '/')

  test "expands env vars with $VAR and ${VAR}":
    putEnv("CLUE_TEST_VAR", "abc")
    check expandPath("/x/$CLUE_TEST_VAR/y") == "/x/abc/y"
    check expandPath("/x/${CLUE_TEST_VAR}/y") == "/x/abc/y"
    delEnv("CLUE_TEST_VAR")

  test "leaves plain paths unchanged":
    check expandPath("/usr/local/bin") == "/usr/local/bin"

suite "deploy configs — findDeployConfig":
  test "returns customPath when the file exists":
    let p = writeTemp("custom.yaml", "type: web\n")
    defer: removeDir(getTempDir() / "clue_deploy_configs" / $getCurrentProcessId())
    check findDeployConfig(p) == p

  test "raises on a missing customPath":
    expect IOError:
      discard findDeployConfig("/nonexistent/clue.deploy.yaml")

  test "scans the standard filenames in the current dir":
    let base = getTempDir() / "clue_deploy_scan" / $getCurrentProcessId()
    createDir(base)
    defer: removeDir(base)
    writeFile(base / "clue.deploy.json", "{}")
    let oldDir = getCurrentDir()
    setCurrentDir(base)
    defer: setCurrentDir(oldDir)
    check findDeployConfig().extractFilename == "clue.deploy.json"

suite "deploy configs — parseDeployConfig":
  test "parses a yaml web config with profile defaults":
    let p = writeTemp("deploy.yaml", """
project: myapp
type: web
web:
  profiles:
    production:
      host: example.com
      user: deploy
      remoteDir: /srv/myapp
      systemd:
        service: myapp
""")
    defer: removeDir(getTempDir() / "clue_deploy_configs" / $getCurrentProcessId())
    let cfg = parseDeployConfig(p)
    check cfg.path == p
    check cfg.project == "myapp"
    check cfg.web.profiles.hasKey("production")
    let prof = cfg.web.profiles["production"]
    check prof.name == "production"
    check prof.host == "example.com"
    check prof.port == 22
    check prof.timeout == 60
    check cfg.web.localDir == "dist/web"

  test "parses a json web config":
    let p = writeTemp("deploy.json", """
{"project":"app","type":"web",
  "web":{"profiles":{"prod":{"host":"h","user":"u","remoteDir":"/srv","port":2200}}}}
""")
    defer: removeDir(getTempDir() / "clue_deploy_configs" / $getCurrentProcessId())
    let cfg = parseDeployConfig(p)
    check cfg.web.profiles["prod"].port == 2200
    check cfg.web.profiles["prod"].name == "prod"

  test "raises on an unsupported extension":
    let p = writeTemp("deploy.toml", "project: x\n")
    defer: removeDir(getTempDir() / "clue_deploy_configs" / $getCurrentProcessId())
    expect IOError:
      discard parseDeployConfig(p)

  test "ignores unknown top-level keys for forward compatibility":
    let p = writeTemp("legacy.yaml", """
project: x
type: cli
github:
  repo: owner/x
release:
  repo: owner/x
  workflow: .github/workflows/release.yml
""")
    defer: removeDir(getTempDir() / "clue_deploy_configs" / $getCurrentProcessId())
    let cfg = parseDeployConfig(p)
    check cfg.project == "x"
    check cfg.`type` == "cli"

suite "deploy configs — release":
  test "parses a dir release block and defaults mode to local":
    let p = writeTemp("release.yaml", """
project: myapp
type: bin
dir:
  profiles:
    binary:
      from: bin
      to: /srv/myapp
      release:
        repo: acme/myapp
        asset: myapp_linux-x86_64.tar.gz
        binary: myapp
""")
    defer: removeDir(getTempDir() / "clue_deploy_configs" / $getCurrentProcessId())
    let cfg = parseDeployConfig(p)
    let rel = cfg.dir.profiles["binary"].release
    check rel.repo == "acme/myapp"
    check rel.asset == "myapp_linux-x86_64.tar.gz"
    check rel.binary == "myapp"
    check rel.mode == "local"

  test "keeps an explicit remote mode":
    let p = writeTemp("release-remote.yaml", """
project: myapp
type: bin
dir:
  profiles:
    binary:
      to: /srv/myapp
      host: example.com
      user: deploy
      release:
        repo: acme/myapp
        asset: myapp
        mode: remote
""")
    defer: removeDir(getTempDir() / "clue_deploy_configs" / $getCurrentProcessId())
    let cfg = parseDeployConfig(p)
    check cfg.dir.profiles["binary"].release.mode == "remote"

  test "release defaults to empty without a block":
    let p = writeTemp("norelease.yaml", """
project: myapp
type: bin
dir:
  profiles:
    binary:
      from: bin
      to: /srv/myapp
""")
    defer: removeDir(getTempDir() / "clue_deploy_configs" / $getCurrentProcessId())
    let cfg = parseDeployConfig(p)
    check cfg.dir.profiles["binary"].release.repo == ""

suite "deploy configs — steps":
  test "parses web and dir steps with names":
    let p = writeTemp("steps.yaml", """
project: myapp
type: bin
web:
  localDir: dist/web
  profiles:
    production:
      host: example.com
      user: deploy
      remoteDir: /srv/myapp
      steps:
        - name: "Who am I"
          run: "whoami"
        - run: "uptime"
dir:
  profiles:
    binary:
      from: bin
      to: /srv/myapp
      steps:
        - run: "systemctl restart myapp"
""")
    defer: removeDir(getTempDir() / "clue_deploy_configs" / $getCurrentProcessId())
    let cfg = parseDeployConfig(p)
    let webSteps = cfg.web.profiles["production"].steps
    check webSteps.len == 2
    check webSteps[0].name == "Who am I"
    check webSteps[0].run == "whoami"
    check webSteps[1].name == ""
    check webSteps[1].run == "uptime"
    let dirSteps = cfg.dir.profiles["binary"].steps
    check dirSteps.len == 1
    check dirSteps[0].run == "systemctl restart myapp"

  test "steps default to empty without a block":
    let p = writeTemp("nosteps.yaml", """
project: myapp
type: bin
dir:
  profiles:
    binary:
      from: bin
      to: /srv/myapp
""")
    defer: removeDir(getTempDir() / "clue_deploy_configs" / $getCurrentProcessId())
    let cfg = parseDeployConfig(p)
    check cfg.dir.profiles["binary"].steps.len == 0
