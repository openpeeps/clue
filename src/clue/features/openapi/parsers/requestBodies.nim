# Clue - A cool toolkit for Nim developers
#
# (c) 2026 George Lemon | MIT License
#          Made by Humans from OpenPeeps
#          https://github.com/openpeeps/clue

import std/[tables, json]
import ../ir
import ./schemas

proc parseMediaType*(node: JsonNode): MediaType =
  if node.isNil or node.kind != JObject:
    return
  if node.hasKey("schema"):
    result.schema = parseSchema(node["schema"])
  if node.hasKey("example"):
    result.example = node["example"]

proc parseContent*(node: JsonNode): OrderedTableRef[string, MediaType] =
  if node.isNil or node.kind != JObject:
    return
  new(result)
  for key, val in node.fields:
    result[key] = parseMediaType(val)

proc parseRequestBody*(node: JsonNode): RequestBody =
  if node.isNil or node.kind != JObject:
    return nil
  new(result)
  if node.hasKey("$ref"):
    result.refPath = node["$ref"].getStr
    return
  if node.hasKey("description"):
    result.description = node["description"].getStr
  if node.hasKey("required"):
    result.required = node["required"].getBool
  if node.hasKey("content"):
    result.content = parseContent(node["content"])

proc parseRequestBodyMap*(node: JsonNode): OrderedTableRef[string, RequestBody] =
  if node.isNil or node.kind != JObject:
    return
  new(result)
  for key, val in node.fields:
    result[key] = parseRequestBody(val)
