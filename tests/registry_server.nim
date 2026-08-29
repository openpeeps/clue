## Tiny HTTP server for registry tests.
## Serves a static `packages.json` at /packages.json.
## Not a test file itself — runner only picks up files starting with `t`.

import std/[asynchttpserver, asyncdispatch, json, os, net, strutils]

const nimdropPkg* = """{"name":"nimdrop","url":"https://github.com/nimbase/nimdrop","method":"git","tags":["nimbase","private"],"description":"nimdrop private","license":"MIT","web":"https://github.com/nimbase/nimdrop"}"""
const hetznerPkg* = """{"name":"hetzner-api","url":"https://github.com/nimbase/hetzner-api","method":"git","tags":["hetzner","api"],"description":"hetzner api","license":"MIT","web":"https://github.com/nimbase/hetzner-api"}"""

proc registryJson*(): string =
  "[" & nimdropPkg & "," & hetznerPkg & "]"

proc findFreePort*(): Port =
  var s = newSocket()
  s.bindAddr(Port(0))
  let (_, p) = s.getLocalAddr()
  s.close()
  p

type RegistryServer* = object
  server: AsyncHttpServer
  port*: Port
  thread: Thread[tuple[port: Port, body: string]]

proc serveProc(arg: tuple[port: Port, body: string]) {.thread.} =
  var server = newAsyncHttpServer()
  proc cb(req: Request) {.async.} =
    if req.url.path == "/packages.json":
      await req.respond(Http200, arg.body, newHttpHeaders([("Content-Type","application/json")]))
    else:
      await req.respond(Http404, "not found")
  waitFor server.serve(arg.port, cb)

proc startRegistryServer*(body = registryJson()): RegistryServer =
  for attempt in 0..5:
    let port = findFreePort()
    result.port = port
    result.server = nil
    createThread(result.thread, serveProc, (port, body))
    sleep(300)
    # quick probe to see if port is serving
    var sock = newSocket()
    try:
      sock.connect("127.0.0.1", port)
      sock.close()
      return
    except: discard
  # fallback: last attempt stays

proc stopRegistryServer*(rs: var RegistryServer) =
  # thread will be killed when process exits; no clean shutdown needed for tests
  discard
