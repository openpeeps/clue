# Clue deploy remotes — unit tests for the shared ssh/rsync builders and
# remote authentication. No ssh/rsync subprocesses are spawned; the builders
# are pure string functions and `ensureRemoteAuth` is only exercised on its
# non-prompting paths (key configured, or no tty available).

import std/[os, strutils, terminal, unittest]
import clue/deploy/configs
import clue/deploy/remotes

suite "deploy remotes — sshTransport":
  test "key auth keeps BatchMode and the key flag":
    let auth = RemoteAuth(key: "~/.ssh/id_ed25519")
    let cmd = sshTransport("deploy", "example.com", 22, auth, 60)
    check "BatchMode=yes" in cmd
    check "-i " in cmd
    check "deploy@example.com" in cmd
    check "-p " notin cmd

  test "custom port is passed through":
    let cmd = sshTransport("deploy", "example.com", 2222,
      RemoteAuth(key: "k"), 60)
    check "-p 2222" in cmd

  test "sshpass path prefixes the transport and never embeds the secret":
    let auth = RemoteAuth(password: "s3cr3t!", useSshpass: true)
    let cmd = sshTransport("deploy", "example.com", 22, auth, 60)
    check cmd.startsWith("sshpass -e ssh")
    check "s3cr3t!" notin cmd
    # No BatchMode: ssh must prompt so that sshpass has something to answer.
    check "BatchMode" notin cmd

  test "password without sshpass drops BatchMode for interactive ssh":
    let auth = RemoteAuth(password: "s3cr3t!", useSshpass: false)
    let cmd = sshTransport("deploy", "example.com", 22, auth, 60)
    check "BatchMode" notin cmd
    check "s3cr3t!" notin cmd

  test "sshCmd single-quotes the remote command":
    let cmd = sshCmd("deploy", "example.com", 22, RemoteAuth(key: "k"),
      60, "systemctl status app")
    check cmd.startsWith("ssh ")
    check "systemctl status app" in cmd

suite "deploy remotes — rsyncCmd":
  test "local sync has no ssh transport":
    let cmd = rsyncCmd("/s/src", "/d/dst", "", "", 0, RemoteAuth(), 60,
      dryRun = false, delete = false, checksum = false, compress = true,
      exclude = @[])
    check "-e " notin cmd
    check cmd == "rsync -a --partial " & quoteShell("/s/src") & "/ " &
      quoteShell("/d/dst") & "/"

  test "dry-run, delete, checksum and excludes are flagged":
    let cmd = rsyncCmd("/s/src", "/d/dst", "", "", 0, RemoteAuth(), 60,
      dryRun = true, delete = true, checksum = true, compress = true,
      exclude = @["*.tmp", ".DS_Store"])
    check " -n" in cmd
    check "--delete" in cmd
    check "--checksum" in cmd
    check "--exclude=*.tmp" in cmd
    check "--exclude=.DS_Store" in cmd

  test "remote sync uses the ssh transport and user@host:path":
    let cmd = rsyncCmd("/s/src", "deploy@example.com:/srv/www", "deploy",
      "example.com", 22, RemoteAuth(key: "k"), 60, dryRun = false,
      delete = false, checksum = false, compress = true, exclude = @[])
    check "-e 'ssh " in cmd
    check "deploy@example.com:/srv/www/" in cmd

  test "rsync -e transport carries no host (rsync appends it from dest)":
    let cmd = rsyncCmd("/s/src", "deploy@example.com:/srv/www", "deploy",
      "example.com", 22, RemoteAuth(key: "k"), 60, dryRun = false,
      delete = false, checksum = false, compress = true, exclude = @[])
    check "-e 'ssh -i k -o BatchMode=yes -o ConnectTimeout=60'" in cmd

  test "rsync -e transport with sshpass carries no host either":
    let cmd = rsyncCmd("/s/src", "deploy@example.com:/srv/www", "deploy",
      "example.com", 22, RemoteAuth(password: "pw", useSshpass: true), 60,
      dryRun = false, delete = false, checksum = false, compress = true,
      exclude = @[])
    check "-e 'sshpass -e ssh -o ConnectTimeout=60'" in cmd
    check "pw" notin cmd

suite "deploy remotes — ensureRemoteAuth":
  test "a configured key resolves without prompting":
    let (auth, ok) = ensureRemoteAuth("deploy", "example.com", "~/.ssh/k")
    check ok
    check auth.key == "~/.ssh/k"
    check auth.password == ""
    check not auth.useSshpass

  test "no key and no tty fails cleanly instead of hanging":
    if isatty(stdin):
      skip()
    else:
      let (_, ok) = ensureRemoteAuth("deploy", "example.com", "")
      check not ok

suite "deploy remotes — steps":
  test "stepLabel prefers the name over the command":
    check stepLabel(RunStep(name: "Who am I", run: "whoami")) == "Who am I"
    check stepLabel(RunStep(run: "uptime")) == "uptime"

  test "validateSteps rejects a step without run":
    check not validateSteps(@[RunStep(name: "oops")], "prod")
    check validateSteps(@[RunStep(run: "whoami")], "prod")
    check validateSteps(@[], "prod")

suite "deploy remotes — toMsysPath":
  test "drive-letter paths become posix without a colon":
    check toMsysPath("C:\\Users\\a\\site") == "/c/Users/a/site"
    check toMsysPath("D:/x") == "/d/x"
    check toMsysPath("c:\\a") == "/c/a"

  test "colon-free paths only get backslashes normalized":
    check toMsysPath("/c/already") == "/c/already"
    check toMsysPath("dist\\site") == "dist/site"
    check toMsysPath("\\\\srv\\share") == "//srv/share"
    check toMsysPath("user@host:/srv/app") == "user@host:/srv/app"
