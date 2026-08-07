# Clue - A cool toolkit for Nim developers
#
# (c) 2026 George Lemon | LGPLv3 License
#          Made by Humans from OpenPeeps
#          https://github.com/openpeeps/clue

## Local mock server for OpenAPI 3.x specifications.
##
## Drives an asynchronous HTTP server (stdlib only) that answers requests
## with sample data generated from the spec's response schemas. Useful for
## developing a generated API client against without a real backend.

import std/[asyncdispatch, asyncnet, net, strutils, strformat, terminal]
import pkg/openparser/json as openjson

export asyncdispatch, asyncnet

const
  MockHttpMethods = ["get", "post", "put", "delete", "patch", "options", "head", "trace"]
  MaxSampleDepth = 16

type
  MockRoute* = object
    httpMethod*: string
    path*: string
    statusCode*: int
    reasonPhrase*: string
    contentType*: string
    body*: openjson.JsonNode

  MockServer* = ref object
    spec*: openjson.JsonNode
    host*: string
    port*: Port
    routes*: seq[MockRoute]
    sock*: AsyncSocket
    verbose*: bool
    started*: bool

proc statusColor(code: int): ForegroundColor =
  case code
  of 200 .. 299: fgGreen
  of 300 .. 399: fgCyan
  of 400 .. 499: fgYellow
  else: fgRed

proc reasonPhrase(code: int): string =
  case code
  of 200: "OK"
  of 201: "Created"
  of 202: "Accepted"
  of 204: "No Content"
  of 301: "Moved Permanently"
  of 302: "Found"
  of 304: "Not Modified"
  of 400: "Bad Request"
  of 401: "Unauthorized"
  of 403: "Forbidden"
  of 404: "Not Found"
  of 405: "Method Not Allowed"
  of 406: "Not Acceptable"
  of 409: "Conflict"
  of 410: "Gone"
  of 415: "Unsupported Media Type"
  of 422: "Unprocessable Entity"
  of 429: "Too Many Requests"
  of 500: "Internal Server Error"
  of 501: "Not Implemented"
  of 502: "Bad Gateway"
  of 503: "Service Unavailable"
  of 504: "Gateway Timeout"
  else: "OK"

proc deref(spec: openjson.JsonNode, node: openjson.JsonNode): openjson.JsonNode =
  ## Follow a `$ref` (`#/components/<section>/<key>`) chain to the actual
  ## definition node. Returns `node` unchanged when it is not a reference.
  if node.isNil or node.kind != JObject or not node.hasKey("$ref"):
    return node
  let refPath = node["$ref"].getStr
  if not refPath.startsWith("#/components/") or not spec.hasKey("components"):
    return node
  let parts = refPath[2 .. ^1].split("/")
  if parts.len < 3:
    return node
  let comps = spec["components"]
  if comps.kind != JObject or not comps.hasKey(parts[1]):
    return node
  let section = comps[parts[1]]
  let key = parts[2 .. ^1].join("/")
  if section.kind != JObject or not section.hasKey(key):
    return node
  result = deref(spec, section[key])

proc sampleJson*(spec: openjson.JsonNode, schema: openjson.JsonNode,
    depth = 0): openjson.JsonNode =
  ## Generate a representative sample `JsonNode` from an OpenAPI schema node.
  ## Follows `$ref`, uses `example`/`default` when present, and otherwise
  ## synthesizes values from `type` (objects, arrays, enums, scalars).
  if schema.isNil or schema.kind != JObject:
    return %""
  if depth > MaxSampleDepth:
    return %""
  let resolved = deref(spec, schema)
  if resolved.isNil:
    return %""
  if resolved.hasKey("example"):
    return resolved["example"]
  if resolved.hasKey("default"):
    return resolved["default"]
  if resolved.hasKey("allOf"):
    result = newJObject()
    for sub in resolved["allOf"]:
      let sample = sampleJson(spec, sub, depth + 1)
      if sample != nil and sample.kind == JObject:
        for k, v in sample.pairs:
          result[k] = v
    return result
  if resolved.hasKey("oneOf") or resolved.hasKey("anyOf"):
    # `oneOf`/`anyOf` schemas are generated as (empty) object types, so sample
    # an empty object rather than a variant the generated type cannot parse.
    return newJObject()
  let typ = if resolved.hasKey("type"): resolved["type"].getStr else: "object"
  case typ
  of "object":
    result = newJObject()
    if resolved.hasKey("properties"):
      for name, propSchema in resolved["properties"].pairs:
        result[name] = sampleJson(spec, propSchema, depth + 1)
  of "array":
    result = newJArray()
    if resolved.hasKey("items"):
      let item = sampleJson(spec, resolved["items"], depth + 1)
      if item != nil:
        result.add(item)
  of "string":
    if resolved.hasKey("enum") and resolved["enum"].len > 0:
      result = resolved["enum"][0]
    elif resolved.hasKey("format"):
      case resolved["format"].getStr
      of "date-time": result = %"2026-01-01T00:00:00Z"
      of "date": result = %"2026-01-01"
      of "email": result = %"user@example.com"
      of "uuid": result = %"00000000-0000-0000-0000-000000000000"
      of "uri": result = %"https://example.com"
      else: result = %"string"
    else:
      result = %"string"
  of "integer":
    if resolved.hasKey("minimum"):
      result = %resolved["minimum"].getBiggestInt
    else:
      result = %1
  of "number":
    if resolved.hasKey("minimum"):
      result = %resolved["minimum"].getFloat
    else:
      result = %1.0
  of "boolean":
    result = %true
  else:
    result = %"string"

proc responseSchema(spec: openjson.JsonNode,
    responses: openjson.JsonNode): tuple[status: int, schema: openjson.JsonNode] =
  ## Pick the success response for an operation: first `2xx` code, falling
  ## back to `default` (treated as 200), else 200 with no schema.
  result = (200, nil)
  if responses.isNil or responses.kind != JObject:
    return
  for code, resp in responses:
    if code.len == 3 and code[0] == '2':
      result.status = parseInt(code)
      let r = deref(spec, resp)
      if r != nil and r.kind == JObject and r.hasKey("content"):
        let content = r["content"]
        if content.kind == JObject and content.hasKey("application/json"):
          result.schema = content["application/json"]["schema"]
      return
  if responses.hasKey("default"):
    let r = deref(spec, responses["default"])
    if r != nil and r.kind == JObject and r.hasKey("content"):
      let content = r["content"]
      if content.kind == JObject and content.hasKey("application/json"):
        result.schema = content["application/json"]["schema"]

proc buildRoutes*(spec: openjson.JsonNode): seq[MockRoute] =
  ## Build the mock route table from `spec["paths"]`.
  if spec.isNil or not spec.hasKey("paths"):
    return
  for path, pathItem in spec["paths"]:
    if pathItem == nil or pathItem.kind != JObject:
      continue
    for httpMeth in MockHttpMethods:
      if not pathItem.hasKey(httpMeth):
        continue
      let op = pathItem[httpMeth]
      if op == nil or op.kind != JObject:
        continue
      let responses =
        if op.hasKey("responses"): op["responses"]
        else: nil
      let (status, schema) = responseSchema(spec, responses)
      let body = sampleJson(spec, schema)
      result.add(MockRoute(
        httpMethod: httpMeth.toUpperAscii,
        path: path,
        statusCode: status,
        reasonPhrase: reasonPhrase(status),
        contentType: "application/json",
        body: if body.isNil: %*{} else: body
      ))

proc renderResponse(route: MockRoute): string =
  let body = if route.body.isNil: "{}" else: openjson.toJson(route.body)
  let contentType =
    if route.contentType.len > 0: route.contentType
    else: "application/json"
  result = "HTTP/1.1 " & $route.statusCode & " " & route.reasonPhrase & "\r\n" &
    "Content-Type: " & contentType & "\r\n" &
    "Content-Length: " & $body.len & "\r\n" &
    "Connection: close\r\n\r\n" & body

proc renderError(status: int, body: openjson.JsonNode): string =
  let bodyStr = openjson.toJson(body)
  result = "HTTP/1.1 " & $status & " " & reasonPhrase(status) & "\r\n" &
    "Content-Type: application/json\r\n" &
    "Content-Length: " & $bodyStr.len & "\r\n" &
    "Connection: close\r\n\r\n" & bodyStr

proc buildRouteIndex*(routes: seq[MockRoute]): openjson.JsonNode =
  ## Build an index of routes grouped by path, with each path mapping to its
  ## HTTP methods and status codes, e.g. `{"/api/health": {"get": 200}}`.
  result = newJObject()
  for route in routes:
    if not result.hasKey(route.path):
      result[route.path] = newJObject()
    result[route.path][route.httpMethod.toLowerAscii] = %route.statusCode

proc pathMatches(routePath, requestPath: string): bool =
  ## Match a request path against a route path, treating `{param}` segments
  ## as wildcards (e.g. `/api/pets/{petId}` matches `/api/pets/1`).
  let routeSegs = routePath.split('/')
  let reqSegs = requestPath.split('/')
  if routeSegs.len != reqSegs.len:
    return false
  for i in 0 ..< routeSegs.len:
    let rs = routeSegs[i]
    if rs.len > 0 and rs[0] == '{' and rs[^1] == '}':
      continue
    if rs != reqSegs[i]:
      return false
  true

proc handleConn(conn: AsyncSocket, server: MockServer) {.async.} =
  try:
    let reqLine = await conn.recvLine()
    if reqLine.len == 0:
      conn.close()
      return
    let parts = reqLine.strip(chars = {'\r'}).split(' ')
    if parts.len < 3:
      await conn.send(renderError(400, %*{"error": "Malformed request"}))
      conn.close()
      return
    let meth = parts[0].toUpperAscii
    let path = parts[1].split('?')[0]
    while true:
      var line = await conn.recvLine()
      line = line.strip(leading = false, trailing = true, chars = {'\r', '\n'})
      if line.len == 0:
        break
    if path == "/" and meth == "GET":
      let index = buildRouteIndex(server.routes)
      let body = openjson.toJson(index)
      let resp = "HTTP/1.1 200 OK\r\n" &
        "Content-Type: application/json\r\n" &
        "Content-Length: " & $body.len & "\r\n" &
        "Connection: close\r\n\r\n" & body
      await conn.send(resp)
      conn.close()
      return
    var matched: MockRoute
    var found = false
    for route in server.routes:
      if route.httpMethod == meth and pathMatches(route.path, path):
        matched = route
        found = true
        break
    if found:
      if server.verbose:
        stdout.write("  ")
        setForegroundColor(stdout, fgWhite, bright = true)
        stdout.write(meth.alignLeft(6))
        resetAttributes()
        stdout.write("  ")
        setForegroundColor(stdout, fgCyan)
        stdout.write(path)
        resetAttributes()
        stdout.write(" -> ")
        setForegroundColor(stdout, statusColor(matched.statusCode))
        stdout.write($matched.statusCode)
        resetAttributes()
        stdout.write("\n")
      await conn.send(renderResponse(matched))
    else:
      var pathExists = false
      for route in server.routes:
        if pathMatches(route.path, path):
          pathExists = true
          break
      if pathExists:
        await conn.send(renderError(405, %*{"error": "Method Not Allowed", "method": meth, "path": path}))
      else:
        await conn.send(renderError(404, %*{"error": "Not Found", "path": path}))
    conn.close()
  except CatchableError:
    try:
      conn.close()
    except CatchableError:
      discard

proc newMockServer*(spec: openjson.JsonNode, host = "127.0.0.1",
    port = Port(8080)): MockServer =
  new(result)
  result.spec = spec
  result.host = host
  result.port = port
  result.routes = buildRoutes(spec)

proc open*(server: MockServer): Future[void] {.async.} =
  server.sock = newAsyncSocket()
  server.sock.setSockOpt(OptReuseAddr, true)
  server.sock.bindAddr(server.port, server.host)
  server.sock.listen()
  let (_, actualPort) = server.sock.getLocalAddr()
  server.port = actualPort
  server.started = true

proc close*(server: MockServer) =
  if not server.sock.isNil and server.started:
    server.sock.close()
  server.started = false

proc serve*(server: MockServer): Future[void] {.async.} =
  if not server.started:
    await server.open()
  while server.started:
    try:
      let conn = await server.sock.accept()
      asyncCheck handleConn(conn, server)
    except CatchableError:
      if not server.started:
        break
      raise

var activeMockServer: MockServer

proc printRoutes*(routes: seq[MockRoute]) =
  ## Print the route table with aligned columns and color:
  ## method (bold), status (colored by code), route path (cyan).
  if routes.len == 0:
    return
  var methodW, statusW: int
  for r in routes:
    methodW = max(methodW, r.httpMethod.len)
    statusW = max(statusW, ($r.statusCode & " " & r.reasonPhrase).len)
  for r in routes:
    let status = $r.statusCode & " " & r.reasonPhrase
    stdout.write("  ")
    setForegroundColor(stdout, fgWhite, bright = true)
    stdout.write(r.httpMethod.alignLeft(methodW))
    resetAttributes()
    stdout.write("  ")
    setForegroundColor(stdout, statusColor(r.statusCode))
    stdout.write(status.alignLeft(statusW))
    resetAttributes()
    stdout.write("  ")
    setForegroundColor(stdout, fgCyan)
    stdout.write(r.path)
    resetAttributes()
    stdout.write("\n")

proc ctrlCHook() {.noconv.} =
  try:
    activeMockServer.close()
  except CatchableError:
    discard
  quit(0)

proc startMockServer*(spec: openjson.JsonNode, host = "127.0.0.1",
    port = Port(8080)) =
  ## Bind and run the mock server forever (until Ctrl+C).
  activeMockServer = newMockServer(spec, host, port)
  waitFor activeMockServer.open()
  echo "Clue OpenAPI mock server listening on http://" & host & ":" & $activeMockServer.port
  printRoutes(activeMockServer.routes)
  setControlCHook(ctrlCHook)
  waitFor activeMockServer.serve()
