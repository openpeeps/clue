## Shared helpers for CLI-level tests (`test_cli_*.nim`).
## Not a test file itself — the runner only picks up files starting with 't'.

import std/[os, osproc, strutils]

proc repoRoot*(): string =
  ## The clue project root (tests run with CWD == tests/).
  getCurrentDir().parentDir()

proc clueBin*(): string =
  ## The freshly built binary, falling back to PATH.
  let local = repoRoot() / "bin" / "clue"
  if fileExists(local): return local
  findExe("clue")

proc stripAnsi*(s: string): string =
  ## Remove ANSI escape sequences so JSON output can be parsed.
  var i = 0
  while i < s.len:
    if s[i] == '\x1b' and i + 1 < s.len and s[i+1] == '[':
      var j = i + 2
      while j < s.len and not s[j].isAlphaAscii():
        inc j
      i = if j < s.len: j + 1 else: j
    else:
      result.add(s[i])
      inc i

proc runClue*(args: varargs[string], dir: string): tuple[code: int, outp: string] =
  ## Run the clue binary inside `dir`, capturing stdout+stderr.
  let bin = clueBin()
  doAssert bin.len > 0, "clue binary not found"
  var cmd = bin.quoteShell
  for arg in args:
    cmd.add(" " & arg.quoteShell)
  let (outp, code) = execCmdEx(cmd, options = {poStdErrToStdOut},
    workingDir = dir)
  (code, outp)

proc readNimble*(dir: string): string =
  readFile(dir / "demo.nimble")
