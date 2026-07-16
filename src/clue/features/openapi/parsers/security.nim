# Clue - A cool toolkit for Nim developers
#
# (c) 2026 George Lemon | MIT License
#          Made by Humans from OpenPeeps
#          https://github.com/openpeeps/clue

import std/[tables, json, strutils]
import ../ir

proc parseSecurityScheme*(node: JsonNode): SecurityScheme =
  if node.isNil or node.kind != JObject:
    return nil
  new(result)
  if node.hasKey("$ref"):
    result.refPath = node["$ref"].getStr
    return
  if node.hasKey("type"):
    try:
      result.schemeType = parseEnum[SecuritySchemeType](node["type"].getStr)
    except:
      discard
  if node.hasKey("description"):
    result.description = node["description"].getStr
  if node.hasKey("name"):
    result.name = node["name"].getStr
  if node.hasKey("in"):
    result.location = node["in"].getStr
  if node.hasKey("scheme"):
    result.scheme = node["scheme"].getStr
  if node.hasKey("bearerFormat"):
    result.bearerFormat = node["bearerFormat"].getStr
  if node.hasKey("flows"):
    result.flows = node["flows"]
  if node.hasKey("openIdConnectUrl"):
    result.openIdConnectUrl = node["openIdConnectUrl"].getStr

proc parseSecuritySchemeMap*(node: JsonNode): OrderedTableRef[string, SecurityScheme] =
  if node.isNil or node.kind != JObject:
    return
  new(result)
  for key, val in node.fields:
    result[key] = parseSecurityScheme(val)

proc parseSecurityRequirement*(node: JsonNode): SecurityRequirement =
  if node.isNil or node.kind != JObject:
    return
  new(result)
  for key, val in node.fields:
    var scopes: seq[string] = @[]
    if val.kind == JArray:
      for s in val.elems:
        scopes.add(s.getStr)
    result[key] = scopes

proc parseSecurityRequirements*(node: JsonNode): seq[SecurityRequirement] =
  if node.isNil or node.kind != JArray:
    return
  for item in node.elems:
    let sr = parseSecurityRequirement(item)
    if not sr.isNil:
      result.add(sr)
