# Clue - A cool toolkit for Nim developers
#
# (c) 2026 George Lemon | MIT License
#          Made by Humans from OpenPeeps
#          https://github.com/openpeeps/clue

import std/[tables, json, strutils]
import ../ir
import ./parameters, ./requestBodies, ./responses, ./security, ./servers

proc parseOperation*(node: JsonNode): Operation =
  if node.isNil or node.kind != JObject:
    return nil
  new(result)
  if node.hasKey("tags") and node["tags"].kind == JArray:
    for t in node["tags"].elems:
      result.tags.add(t.getStr)
  if node.hasKey("summary"):
    result.summary = node["summary"].getStr
  if node.hasKey("description"):
    result.description = node["description"].getStr
  if node.hasKey("operationId"):
    result.operationId = node["operationId"].getStr
  if node.hasKey("parameters"):
    result.parameters = parseParameters(node["parameters"])
  if node.hasKey("requestBody"):
    result.requestBody = parseRequestBody(node["requestBody"])
  if node.hasKey("responses"):
    result.responses = parseResponseMap(node["responses"])
  if node.hasKey("deprecated"):
    result.deprecated = node["deprecated"].getBool
  if node.hasKey("security"):
    result.security = parseSecurityRequirements(node["security"])
  if node.hasKey("servers"):
    result.servers = parseServers(node["servers"])

proc parsePathItem*(path: string, node: JsonNode): PathItem =
  if node.isNil or node.kind != JObject:
    return nil
  new(result)
  if node.hasKey("summary"):
    result.summary = node["summary"].getStr
  if node.hasKey("description"):
    result.description = node["description"].getStr
  if node.hasKey("parameters"):
    result.parameters = parseParameters(node["parameters"])
  if node.hasKey("get"):
    result.get = parseOperation(node["get"])
  if node.hasKey("put"):
    result.put = parseOperation(node["put"])
  if node.hasKey("post"):
    result.post = parseOperation(node["post"])
  if node.hasKey("delete"):
    result.delete = parseOperation(node["delete"])
  if node.hasKey("options"):
    result.options = parseOperation(node["options"])
  if node.hasKey("head"):
    result.head = parseOperation(node["head"])
  if node.hasKey("patch"):
    result.patch = parseOperation(node["patch"])
  if node.hasKey("trace"):
    result.trace = parseOperation(node["trace"])

proc parsePaths*(node: JsonNode): OrderedTableRef[string, PathItem] =
  if node.isNil or node.kind != JObject:
    return
  new(result)
  for key, val in node.fields:
    let pi = parsePathItem(key, val)
    if not pi.isNil:
      result[key] = pi
