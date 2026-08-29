import std/[os, osproc, strutils, unittest, json, strtabs]
import cli_helpers
import registry_server

proc withTempHome(body: proc(home: string)) =
  let home = getTempDir() / "clue_cli_src_home" / $getCurrentProcessId() & "_" & $getCurrentProcessId()
  createDir(home)
  defer: removeDir(home)
  body(home)

proc runClueWithHome(args: varargs[string], home: string): tuple[code: int, outp: string] =
  var env = newStringTable(modeStyleInsensitive)
  for k, v in envPairs(): env[k] = v
  env["HOME"] = home
  let bin = clueBin()
  var cmd = bin.quoteShell
  for a in args: cmd.add(" " & a.quoteShell)
  let (outp, code) = execCmdEx(cmd, options = {poStdErrToStdOut}, env = env)
  (code, outp)

suite "cli source — add/list/fetch/remove":
  test "full lifecycle via http server":
    var rs = startRegistryServer()
    defer: stopRegistryServer(rs)
    let url = "http://127.0.0.1:" & $rs.port.int & "/packages.json"
    withTempHome(proc(home: string) =
      # list should show default nim-lang initially
      let (c0, o0) = runClueWithHome("source.list", home)
      check c0 == 0
      check o0.contains("nim-lang")

      # add myreg
      let (c1, o1) = runClueWithHome("source.add", "myreg", url, home)
      check c1 == 0
      check o1.contains("Added source")

      # list should now show myreg
      let (c2, o2) = runClueWithHome("source.list", home)
      check c2 == 0
      check o2.contains("myreg")
      checkpoint "list after add: " & stripAnsi(o2)

      let (c3, o3) = runClueWithHome("source.fetch", "myreg", home)
      check c3 == 0
      checkpoint "fetch myreg: " & stripAnsi(o3)

      # remove
      let (c4, o4) = runClueWithHome("source.remove", "myreg", home)
      check c4 == 0
      check o4.contains("Removed")

      # list should no longer contain myreg
      let (c5, o5) = runClueWithHome("source.list", home)
      check c5 == 0
      check not o5.contains("myreg")
    )

  test "invalid name rejected":
    withTempHome(proc(home: string) =
      let (code, outp) = runClueWithHome("source.add", "BadName", "https://example.com/p.json", home)
      check code != 0
      check stripAnsi(outp).toLowerAscii.contains("invalid")
    )
