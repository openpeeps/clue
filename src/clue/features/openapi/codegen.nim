# Clue - A cool toolkit for Nim developers
#
# (c) 2026 George Lemon | LGPLv3 License
#          Made by Humans from OpenPeeps
#          https://github.com/openpeeps/clue

import std/[tables, json, strformat, strutils, os, times, sequtils, wordwrap]
import pkg/openparser/json as openjson
import ./ir, ./specparser

const nimKeywords = ["addr", "and", "as", "asm", "bind", "block", "break", "case",
  "cast", "concept", "const", "continue", "converter", "defer", "discard",
  "distinct", "div", "do", "elif", "else", "end", "enum", "except", "export",
  "finally", "for", "from", "func", "if", "import", "in", "include", "interface",
  "is", "isnot", "iterator", "let", "macro", "method", "mixin", "mod", "nil",
  "not", "notin", "object", "of", "or", "out", "proc", "ptr", "raise", "ref",
  "return", "shl", "shr", "static", "template", "try", "tuple", "type", "using",
  "var", "when", "while", "xor", "yield"]

proc safeIdent(name: string): string =
  if name in nimKeywords: "`" & name & "`" else: name

proc fmtDocComment(indent: string, desc: string; maxWidth = 80): string =
  if desc.len == 0: return
  for line in desc.splitLines:
    let trimmed = line.strip
    if trimmed.len == 0:
      result &= &"{indent}##\n"
    else:
      let wrapped = wrapWords(trimmed, maxWidth)
      for wLine in wrapped.splitLines:
        result &= &"{indent}## {wLine.strip}\n"

const
  stubMetaclient = staticRead("stubs/metaclient.nim")
  stubMetaclientOAuth2 = staticRead("stubs/metaclient_oauth2.nim")
  stubReadme = staticRead("stubs/readme.md")
  stubNimble = staticRead("stubs/pkg.nimble")
  stubHeader = staticRead("stubs/header.txt")

type
  Generator* = ref object
    pkg*: Package
    outputDir*: string
    pkgName*: string
    pkgIdent*: string
    baseUri*: string
    genTime*: string
    schemas*: OrderedTableRef[string, Schema]
    authType*: string
    oauthTokenUrl*: string
    oauthAuthUrl*: string

proc toPascalCase(s: string): string =
  var nextUpper = true
  for c in s:
    if c in {'_', '-', '/', ':'}:
      nextUpper = true
    elif nextUpper:
      add result, c.toUpperAscii
      nextUpper = false
    else:
      add result, c

proc toSnakeCase(s: string): string =
  for i, c in s:
    if c.isUpperAscii:
      if i > 0:
        add result, '_'
      add result, c.toLowerAscii
    else:
      add result, c

proc toCamelCase(s: string): string =
  var nextUpper = false
  for c in s:
    if c in {'_', '-', '/', ':'}:
      nextUpper = true
    elif nextUpper:
      add result, c.toUpperAscii
      nextUpper = false
    else:
      add result, c

proc genEndpoint*(path: string, skipPrefixPath: sink string = ""): tuple[ident, module, endpoint: string] =
  var i = 0
  while i <= path.high:
    case path[i]
    of '/', '_', '-':
      if i != 0:
        add result.module, '_'
      inc i
      while i <= path.high and path[i] notin {'a'..'z'}:
        inc i
      if i <= path.high:
        add result.ident, path[i].toUpperAscii
        add result.module, path[i]
    of '{', '}':
      discard
    else:
      add result.ident, path[i]
      add result.module, path[i]
    inc i
  result.endpoint = path
  if skipPrefixPath.len > 0 and result.ident.startsWith(skipPrefixPath):
    result.ident = result.ident[skipPrefixPath.len .. ^1]
  result.module = result.module.toLowerAscii

proc schemaNameToTypeName(name: string): string =
  toPascalCase(name)

proc schemaNameToEnumName(name: string): string =
  toPascalCase(name)

proc nimTypeForSchema*(schema: Schema, schemas: OrderedTableRef[string, Schema]; typeNameHint = ""): string =
  if schema.refPath.len > 0:
    let parts = schema.refPath.split("/")
    return schemaNameToTypeName(parts[^1])
  case schema.fieldType
  of stString:
    if schema.enumValues.len > 0:
      let name = if schema.name.len > 0: schema.name else: typeNameHint
      if name.len > 0:
        return schemaNameToEnumName(name)
    return "string"
  of stInteger:
    if schema.integerFormat == int32:
      return "int32"
    return "int64"
  of stNumber:
    return "float64"
  of stBoolean:
    return "bool"
  of stArray:
    if not schema.items.isNil:
      return &"seq[{nimTypeForSchema(schema.items, schemas)}]"
    return "seq[JsonNode]"
  of stObject:
    if schema.name.len > 0:
      return schemaNameToTypeName(schema.name)
    return "JsonNode"

proc pascalSingular(tag: string): string =
  let singular =
    if tag.endsWith("s"): tag[0..^2]
    else: tag
  toPascalCase(singular)

proc paramHasEnum(param: Parameter): bool =
  param.schema != nil and param.schema.enumValues.len > 0

proc paramIsSimpleArray(param: Parameter): bool =
  param.schema != nil and param.schema.fieldType == stArray and
    param.schema.items != nil and param.schema.items.enumValues.len == 0

proc enumParamNimType(param: Parameter; tag: string): string =
  let enumName = safeIdent(pascalSingular(tag) & toPascalCase(param.name) & "Option")
  "set[" & enumName & "]"

proc enumParamDefault(param: Parameter; tag: string): string =
  if paramHasEnum(param): "{}"
  elif paramIsSimpleArray(param): "@[]"
  else: ""

proc paramDefaultValue(param: Parameter): string =
  if param.schema.isNil or param.schema.default.isNil or param.schema.default.kind == JNull:
    return
  let d = param.schema.default
  case param.schema.fieldType
  of stString:
    result = "\"" & d.getStr & "\""
  of stInteger:
    if d.kind == JInt:
      result = $d.getInt
  of stNumber:
    if d.kind == JFloat:
      result = $d.getFloat
  of stBoolean:
    result = if d.getBool: "true" else: "false"
  else: discard

proc genEnumForQueryParam(param: Parameter; tag: string): string =
  let enumName = safeIdent(pascalSingular(tag) & toPascalCase(param.name) & "Option")
  result = &"  {enumName}* = enum\n"
  for val in param.schema.enumValues:
    let fieldName = toCamelCase(param.name) & toPascalCase(val)
    result &= &"    {fieldName} = \"{val}\"\n"

proc genTypeDefinition*(schemaName: string, schema: Schema, schemas: OrderedTableRef[string, Schema]): string =
  if schema.refPath.len > 0:
    let refParts = schema.refPath.split("/")
    let targetType = schemaNameToTypeName(refParts[refParts.high])
    let typeName = schemaNameToTypeName(schemaName)
    if typeName != targetType:
      result = &"  {typeName}* = {targetType}\n"
    return
  case schema.fieldType
  of stObject:
    let typeName = schemaNameToTypeName(schemaName)
    result = &"  {typeName}* = ref object of RootObj\n"
    result &= fmtDocComment("    ", schema.description)
    if not schema.properties.isNil:
      for propName, propSchema in schema.properties.pairs:
        let nimName = safeIdent(toSnakeCase(propName))
        let nimType = nimTypeForSchema(propSchema, schemas)
        let isRequired = propName in schema.required
        if isRequired:
          result &= &"    {nimName}*: {nimType}\n"
        else:
          result &= &"    {nimName}*: Option[{nimType}]\n"
        result &= fmtDocComment("      ", propSchema.description)
  of stString:
    if schema.enumValues.len > 0:
      let enumName = schemaNameToEnumName(schemaName)
      result = &"  {enumName}* = enum\n"
      result &= fmtDocComment("    ", schema.description)
      for val in schema.enumValues:
        let fieldName = toCamelCase(val)
        result &= &"    {fieldName} = \"{val}\"\n"
  else:
    discard

proc genTypes*(schemas: OrderedTableRef[string, Schema]): string =
  result = "import std/[options, json]\n"
  result &= "import ./metaclient\n\n"
  result &= "type\n"
  var first = true
  for schemaName, schema in schemas.pairs:
    let typeDef = genTypeDefinition(schemaName, schema, schemas)
    if typeDef.len > 0:
      if not first:
        result &= "\n"
      result &= typeDef
      first = false

proc genEnumType(schemaName: string, schema: Schema): string =
  let enumName = schemaNameToEnumName(schemaName)
  result = &"  {enumName}* = enum\n"
  for val in schema.enumValues:
    let fieldName = toCamelCase(val)
    result &= &"    {fieldName} = \"{val}\"\n"

proc genRequestType(ident: string, bodySchema: Schema, schemas: OrderedTableRef[string, Schema]): string =
  if bodySchema.isNil or bodySchema.refPath.len > 0:
    return ""
  if bodySchema.fieldType == stObject and not bodySchema.properties.isNil:
    result = &"  {ident}Request = object\n"
    for propName, propSchema in bodySchema.properties.pairs:
      let nimName = safeIdent(toSnakeCase(propName))
      let nimType = nimTypeForSchema(propSchema, schemas)
      let isRequired = propName in bodySchema.required
      if isRequired:
        result &= &"    {nimName}: {nimType}\n"
      else:
        result &= &"    {nimName}: Option[{nimType}]\n"
    if result.endsWith("\n"):
      result.setLen(result.len - 1)

proc genResponseType(ident: string, httpMeth: string, responseSchema: Schema, schemas: OrderedTableRef[string, Schema]): string =
  if responseSchema.isNil or responseSchema.refPath.len > 0:
    return
  if responseSchema.fieldType == stObject and not responseSchema.properties.isNil:
    let typeName = httpMeth.toLowerAscii.toUpperAscii[0] & httpMeth.toLowerAscii[1..^1] & ident & "Response"
    let desc = fmtDocComment("    ", responseSchema.description)
    result = &"  {typeName}* = object\n"
    result &= desc
    for propName, propSchema in responseSchema.properties.pairs:
      let nimName = safeIdent(toSnakeCase(propName))
      let nimType = nimTypeForSchema(propSchema, schemas)
      result &= &"    {nimName}: {nimType}\n"
      result &= fmtDocComment("      ", propSchema.description)
    if result.endsWith("\n"):
      result.setLen(result.len - 1)

proc genEndpointProc(httpMeth: string; path: string; operation: Operation;
  schemas: OrderedTableRef[string, Schema];
  pkgIdent: string; tag: string): string =
  let ep = genEndpoint(path)
  let httpMethod = httpMeth.toLowerAscii
  let procName = httpMethod & ep.ident
  let errType = &"{pkgIdent}ClientError"
  let methUpper = httpMeth.toUpperAscii

  var pathParams: seq[Parameter]
  var queryParams: seq[Parameter]
  var hasBody = false
  var bodyRefName: string
  var bodyNeedsRequestType = false
  var successCode = ""
  var successSchema: Schema

  for param in operation.parameters:
    if param.isNil: continue
    case param.kind
    of pinPath: pathParams.add(param)
    of pinQuery: queryParams.add(param)
    else: discard

  if not operation.requestBody.isNil and not operation.requestBody.content.isNil:
    for mediaType, mt in operation.requestBody.content.pairs:
      if mediaType == "application/json" and not mt.schema.isNil:
        let bodySchema = mt.schema
        hasBody = true
        if bodySchema.refPath.len > 0:
          let refParts = bodySchema.refPath.split("/")
          bodyRefName = schemaNameToTypeName(refParts[refParts.high])
        elif bodySchema.fieldType == stObject and not bodySchema.properties.isNil:
          bodyNeedsRequestType = true

  for statusCode, response in operation.responses.pairs:
    if statusCode.startsWith("2") and not response.content.isNil:
      for mediaType, mt in response.content.pairs:
        if mediaType == "application/json" and not mt.schema.isNil:
          successCode = statusCode
          successSchema = mt.schema
          break
    if successCode.len > 0: break

  let respTypeName =
    if successSchema != nil and successSchema.refPath.len > 0:
      let parts = successSchema.refPath.split("/")
      schemaNameToTypeName(parts[parts.high])
    elif successSchema != nil:
      httpMeth.toLowerAscii.toUpperAscii[0] & httpMeth.toLowerAscii[1..^1] & ep.ident & "Response"
    else:
      "AsyncResponse"

  result = "\n"

  var paramStrs: seq[string]
  paramStrs.add("client: " & pkgIdent & "Client")
  for param in operation.parameters:
    if param.isNil: continue
    let paramName = safeIdent(toCamelCase(param.name))
    let nimType = nimTypeForSchema(param.schema, schemas)
    case param.kind
    of pinPath:
      paramStrs.add(paramName & ": " & nimType)
    of pinQuery:
      let defaultVal = paramDefaultValue(param)
      if defaultVal.len > 0:
        paramStrs.add(paramName & ": " & nimType & " = " & defaultVal)
      elif paramHasEnum(param):
        paramStrs.add(paramName & ": " & enumParamNimType(param, tag) & " = {}")
      elif paramIsSimpleArray(param):
        paramStrs.add(paramName & ": seq[string] = @[]")
      elif param.required:
        paramStrs.add(paramName & ": " & nimType)
      else:
        paramStrs.add(paramName & ": " & nimType & " = default(" & nimType & ")")
    else: discard

  if hasBody:
    if bodyRefName.len > 0:
      paramStrs.add("body: " & bodyRefName)
    elif bodyNeedsRequestType:
      paramStrs.add("body: " & ep.ident & "Request")

  let procPrefix = "proc " & procName & "*("
  let suffix = ": Future[" & respTypeName & "] {.async.} =\n"
  const maxLine = 80
  let align = procPrefix.len
  result &= procPrefix
  var lineLen = procPrefix.len
  for i, p in paramStrs:
    let comma = if i > 0: ", " else: ""
    let totalLen = comma.len + p.len
    if lineLen + totalLen > maxLine and i > 0:
      result &= ",\n" & spaces(align)
      lineLen = align
    elif i > 0:
      result &= ", "
      lineLen += 2
    result &= p
    lineLen += p.len
  result &= ")" & suffix

  let docDesc =
    if operation.description.len > 0:
      fmtDocComment("  ", operation.description.strip)
    elif operation.summary.len > 0:
      fmtDocComment("  ", operation.summary)
    else: ""
  if docDesc.len > 0:
    result &= docDesc & "\n"

  if queryParams.len > 0:
    result &= "  var q = initOrderedTable[string, string]()\n"
    for param in queryParams:
      let paramName = safeIdent(toCamelCase(param.name))
      if paramHasEnum(param) or paramIsSimpleArray(param):
        result &= &"  for v in {paramName}: q[\"{param.name}\"] = $v\n"
      else:
        result &= &"  q[\"{param.name}\"] = ${paramName}\n"

  if pathParams.len > 0:
    var fmtPath = ep.endpoint
    for param in pathParams:
      let paramName = safeIdent(toCamelCase(param.name))
      fmtPath = fmtPath.replace(&"{{{param.name}}}", &"{{{paramName}}}")
    if queryParams.len > 0:
      result &= &"  let res = await client.http{methUpper}(fmt\"{fmtPath}\", q)\n"
    elif hasBody:
      result &= &"  let res = await client.http{methUpper}(fmt\"{fmtPath}\", body)\n"
    else:
      result &= &"  let res = await client.http{methUpper}(fmt\"{fmtPath}\")\n"
  else:
    if queryParams.len > 0:
      result &= &"  let res = await client.http{methUpper}(\"{ep.endpoint}\", q)\n"
    elif hasBody:
      result &= &"  let res = await client.http{methUpper}(\"{ep.endpoint}\", body)\n"
    else:
      result &= &"  let res = await client.http{methUpper}(\"{ep.endpoint}\")\n"

  if respTypeName == "AsyncResponse":
    result &= "  return res\n"
  else:
    result &= "  let body = await res.body\n"
    result &= &"  case res.code\n"
    result &= &"  of Http{successCode}:\n"
    result &= &"    result = fromJson(body, {respTypeName})\n"
    result &= "  else:\n"
    result &= &"    raise newException({errType}, body)\n"

proc genEndpointFile*(tag: string, ops: seq[tuple[path: string, meth: string, operation: Operation]],
  schemas: OrderedTableRef[string, Schema];
  pkgIdent: string): string =
  result = stubHeader
  result &= "import std/[strformat, options, json]\n"
  result &= "import ./metaclient\n"
  result &= "import ./types\n\n"

  var hasTypes = false
  var firstType = true
  for (path, meth, operation) in ops:
    let ep = genEndpoint(path)
    var bodySchema: Schema
    if not operation.requestBody.isNil and not operation.requestBody.content.isNil:
      for mediaType, mt in operation.requestBody.content.pairs:
        if mediaType == "application/json" and not mt.schema.isNil:
          bodySchema = mt.schema
          break
    if not bodySchema.isNil and bodySchema.refPath.len == 0 and bodySchema.fieldType == stObject and not bodySchema.properties.isNil:
      let reqType = genRequestType(ep.ident, bodySchema, schemas)
      if reqType.len > 0:
        if not hasTypes:
          result &= "type\n"
          hasTypes = true
        if not firstType:
          result &= "\n"
        result &= reqType
        firstType = false
    for statusCode, response in operation.responses.pairs:
      if not response.content.isNil:
        for mediaType, mt in response.content.pairs:
          if mediaType == "application/json" and not mt.schema.isNil:
            let respType = genResponseType(ep.ident, meth, mt.schema, schemas)
            if respType.len > 0:
              if not hasTypes:
                result &= "type\n"
                hasTypes = true
              if not firstType:
                result &= "\n"
              result &= respType
              firstType = false

  var emittedEnums: seq[string]
  for (path, meth, operation) in ops:
    for param in operation.parameters:
      if param != nil and param.kind == pinQuery and paramHasEnum(param):
        let enumName = pascalSingular(tag) & toPascalCase(param.name) & "Option"
        if enumName notin emittedEnums:
          emittedEnums.add(enumName)
          let enumDef = genEnumForQueryParam(param, tag)
          if enumDef.len > 0:
            if not hasTypes:
              result &= "type\n"
              hasTypes = true
            if not firstType:
              result &= "\n"
            result &= enumDef
            firstType = false

  if hasTypes:
    result &= "\n"

  for (path, meth, operation) in ops:
    result &= genEndpointProc(meth, path, operation, schemas, pkgIdent, tag)

proc serverIdent(description, url: string): string =
  let src =
    if description.len > 0: description
    else: url
  result = ""
  var nextUpper = true
  for c in src:
    if c == ' ' or c == '-' or c == '_' or c == '/' or c == '.' or c == ':':
      nextUpper = true
    elif c.isAlphaAscii or c.isDigit:
      if nextUpper:
        result.add(c.toUpperAscii)
        nextUpper = false
      else:
        result.add(c)

proc genServers*(servers: seq[Server]): string =
  result = "const\n"
  for i, srv in servers:
    let name = "server" & serverIdent(srv.description, srv.url)
    result &= &"  {name}* = \"{srv.url}\"\n"

proc groupOperations*(pkg: Package): OrderedTableRef[string, seq[tuple[path: string, meth: string, operation: Operation]]] =
  new(result)
  if pkg.oapi.isNil or pkg.oapi.paths.isNil:
    return
  for curPath, pathItem in pkg.oapi.paths.pairs:
    if pathItem.isNil: continue
    let items: array[8, tuple[op: Operation, meth: string]] = [
      (pathItem.get, "GET"), (pathItem.post, "POST"), (pathItem.put, "PUT"),
      (pathItem.delete, "DELETE"), (pathItem.patch, "PATCH"),
      (pathItem.options, "OPTIONS"), (pathItem.head, "HEAD"), (pathItem.trace, "TRACE")
    ]
    for (op, httpMeth) in items:
      if op == nil: continue
      let tag =
        if op.tags.len > 0:
          let firstTag = op.tags[0].toLowerAscii
          if firstTag.len > 0: firstTag
          else: genEndpoint(curPath).module
        else:
          genEndpoint(curPath).module
      if not result.hasKey(tag):
        result[tag] = newSeq[tuple[path: string, meth: string, operation: Operation]]()
      result[tag].add((curPath, httpMeth, op))

proc detectOAuthUrl(scheme: SecurityScheme, kind: string): string =
  if scheme.isNil or scheme.flows.isNil or scheme.flows.kind != JObject:
    return
  for flowName in ["authorizationCode", "implicit", "password", "clientCredentials"]:
    if scheme.flows.hasKey(flowName) and scheme.flows[flowName].kind == JObject:
      let flow = scheme.flows[flowName]
      if flow.hasKey(kind) and flow[kind].kind == JString:
        return flow[kind].getStr

proc newGenerator*(pkg: Package, outputDir: string): Generator =
  new(result)
  result.pkg = pkg
  result.outputDir = outputDir
  result.pkgName = if pkg.id.len > 0: pkg.id else: "client"
  result.pkgIdent = toPascalCase(result.pkgName)
  result.genTime = $now()
  result.authType = "bearer"
  if pkg.oapi != nil:
    if pkg.oapi.servers.len > 0:
      result.baseUri = pkg.oapi.servers[0].url
    if pkg.oapi.components.schemas != nil:
      result.schemas = pkg.oapi.components.schemas
    if pkg.oapi.components.securitySchemes != nil:
      for name, scheme in pkg.oapi.components.securitySchemes.pairs:
        if scheme != nil and scheme.schemeType == sstOAuth2:
          result.authType = "oauth2"
          result.oauthTokenUrl = detectOAuthUrl(scheme, "tokenUrl")
          result.oauthAuthUrl = detectOAuthUrl(scheme, "authorizationUrl")
          break

proc fillTemplate(tmpl: string, vars: Table[string, string]): string =
  result = tmpl
  for key, val in vars:
    result = result.replace(&"{{{key}}}", val)

proc ensureDir(path: string) =
  if not dirExists(path):
    createDir(path)

proc generate*(gen: Generator) =
  let srcDir = gen.outputDir / "src"
  let srcPkgDir = srcDir / gen.pkgName
  ensureDir(srcPkgDir)

  let serverUrl =
    if gen.baseUri.len > 0:
      if gen.baseUri[^1] != '/': gen.baseUri & "/"
      else: gen.baseUri
    else: ""

  let oauth2Require =
    if gen.authType == "oauth2": "\nrequires \"oauth2\""
    else: ""

  let vars = {
    "clue_pkg_name": gen.pkgName,
    "clue_client_ident": gen.pkgIdent & "Client",
    "clue_client_ident_error": gen.pkgIdent & "ClientError",
    "clue_pkg_generation_time": gen.genTime,
    "clue_pkg_license": gen.pkg.license,
    "clue_pkg_desc": gen.pkg.description,
    "clue_base_uri": serverUrl,
    "clue_oauth_token_url": gen.oauthTokenUrl,
    "clue_oauth_auth_url": gen.oauthAuthUrl,
    "clue_requires_oauth2": oauth2Require,
    "pkgVersion": gen.pkg.openApiVersion,
    "pkgAuthor": gen.pkg.author,
    "pkgDesc": gen.pkg.description,
    "pkgLicense": gen.pkg.license,
  }.toTable

  let metaclientStub =
    if gen.authType == "oauth2": stubMetaclientOAuth2
    else: stubMetaclient
  writeFile(srcPkgDir / "metaclient.nim", fillTemplate(metaclientStub, vars))
  writeFile(gen.outputDir / "README.md", fillTemplate(stubReadme, vars))

  if not gen.schemas.isNil and gen.schemas.len > 0:
    let typesCode = genTypes(gen.schemas)
    writeFile(srcPkgDir / "types.nim", typesCode)

  var hasServers = false
  if not gen.pkg.oapi.isNil and gen.pkg.oapi.servers.len > 1:
    let serversCode = genServers(gen.pkg.oapi.servers)
    writeFile(srcPkgDir / "server_urls.nim", serversCode)
    hasServers = true

  let groups = groupOperations(gen.pkg)
  if not groups.isNil:
    for tag, ops in groups.pairs:
      let fileName = tag & ".nim"
      let endpointCode = fillTemplate(genEndpointFile(tag, ops, gen.schemas, gen.pkgIdent), vars)
      writeFile(srcPkgDir / fileName, endpointCode)

  var mainImports: seq[string]
  var mainExports: seq[string]
  for tag, _ in groups.pairs:
    mainImports.add(&"import ./{gen.pkgName}/{tag}")
    mainExports.add(tag)
  mainImports.add(&"import ./{gen.pkgName}/types")
  mainExports.add("types")
  mainImports.add(&"import ./{gen.pkgName}/metaclient")
  mainExports.add("metaclient")
  if hasServers:
    mainImports.add(&"import ./{gen.pkgName}/server_urls")
    mainExports.add("server_urls")

  let mainCode = mainImports.join("\n") & "\n\n" &
    "export " & mainExports.join(", ") & "\n"
  writeFile(srcDir / &"{gen.pkgName}.nim", mainCode)

  writeFile(gen.outputDir / &"{gen.pkgName}.nimble", fillTemplate(stubNimble, vars))

  echo "Generated client package at: ", gen.outputDir
