# Clue - A cool toolkit for Nim developers
#
# (c) 2026 George Lemon | LGPLv3 License
#          Made by Humans from OpenPeeps
#          https://github.com/openpeeps/clue

## Minimal local documentation server for `clue docs.open`.
##
## All generated `nim doc` assets under the requested version dir are loaded
## into memory once at startup; every request is then a plain table lookup —
## no disk I/O, no traversal possible (only preloaded relative paths are ever
## served). Built entirely on the Nim standard library.

import std/[asynchttpserver, asyncdispatch, httpcore, mimetypes,
            net, os, osproc, strutils, uri, tables]

import pkg/kapsis/interactive/prompts

proc loadAssets(docDir: string): tuple[files: TableRef[string, string], index: string] =
  ## Recursively load every file under `docDir` into memory, keyed by its
  ## URL-relative path (forward slashes). Also picks the default document.
  result.files = newTable[string, string]()
  for c in ["index.html", docDir.extractFilename & ".html", "theindex.html"]:
    if fileExists(docDir / c):
      result.index = c
      break
  if result.index.len == 0:
    result.index = "index.html"
  for f in walkDirRec(docDir):
    if f.extractFilename.startsWith("."):
      continue
    let rel = relativePath(f, docDir).replace(DirSep, '/')
    result.files[rel] = readFile(f)

proc serveDocs*(docDir, pkgName: string, port: Port) =
  ## Serve the preloaded docs for `pkgName` over HTTP, opening the browser.
  if not dirExists(docDir):
    displayError("Documentation not found for " & pkgName & " at " & docDir, quitProcess = true)
    return
  let (files, index) = loadAssets(docDir)
  if files.len == 0:
    displayError("No documentation assets found in " & docDir, quitProcess = true)
    return
  let mimes = newMimetypes()
  let server = newAsyncHttpServer()

  proc cb(req: Request) {.async, gcsafe.} =
    var path = req.url.path
    if path.startsWith('/'):
      path = path[1 .. ^1]
    path = decodeUrl(path)
    if path.len == 0 or path.endsWith('/'):
      path = path & index
    if files.hasKey(path):
      let headers = newHttpHeaders([
        ("Content-Type", mimes.getMimetype(path.splitFile.ext, "application/octet-stream"))
      ])
      await req.respond(Http200, files[path], headers)
    else:
      await req.respond(Http404, "Not Found")

  let url = "http://127.0.0.1:" & $port & "/"
  displayInfo("Serving " & pkgName & " docs at " & url & " (Ctrl+C to stop)")
  when defined(macosx):
    discard execCmdEx("open \"" & url & "\"")
  elif defined(linux):
    discard execCmdEx("xdg-open \"" & url & "\"")
  waitFor server.serve(port, cb)
