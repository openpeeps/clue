# Clue - A cool toolkit for Nim developers
#
# (c) 2026 George Lemon | MIT License
#          Made by Humans from OpenPeeps
#          https://github.com/openpeeps/clue

import std/[tables, json]
import ../ir

proc parseServerVariable*(node: JsonNode): ServerVariable =
  if node.isNil or node.kind != JObject:
    return
  if node.hasKey("default"):
    result.default = node["default"].getStr
  if node.hasKey("description"):
    result.description = node["description"].getStr
  if node.hasKey("enum") and node["enum"].kind == JArray:
    for e in node["enum"].elems:
      result.`enum`.add(e.getStr)

proc parseServerVariables*(node: JsonNode): OrderedTableRef[string, ServerVariable] =
  if node.isNil or node.kind != JObject:
    return
  new(result)
  for key, val in node.fields:
    result[key] = parseServerVariable(val)

proc parseServer*(node: JsonNode): Server =
  if node.isNil or node.kind != JObject:
    return
  if node.hasKey("url"):
    result.url = node["url"].getStr
  if node.hasKey("description"):
    result.description = node["description"].getStr
  if node.hasKey("variables"):
    result.variables = parseServerVariables(node["variables"])

proc parseServers*(node: JsonNode): seq[Server] =
  if node.isNil or node.kind != JArray:
    return
  for item in node.elems:
    result.add(parseServer(item))
