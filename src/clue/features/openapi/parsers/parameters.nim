# Clue - A cool toolkit for Nim developers
#
# (c) 2026 George Lemon | MIT License
#          Made by Humans from OpenPeeps
#          https://github.com/openpeeps/clue

import std/[tables, json, strutils]
import ../ir
import ./schemas

proc parseParameter*(node: JsonNode): Parameter =
  if node.isNil or node.kind != JObject:
    return nil
  new(result)
  if node.hasKey("$ref"):
    result.refPath = node["$ref"].getStr
    return
  if node.hasKey("name"):
    result.name = node["name"].getStr
  if node.hasKey("description"):
    result.description = node["description"].getStr
  if node.hasKey("in"):
    try:
      result.kind = parseEnum[ParameterIn](node["in"].getStr)
    except:
      discard
  if node.hasKey("required"):
    result.required = node["required"].getBool
  if node.hasKey("deprecated"):
    result.deprecated = node["deprecated"].getBool
  if node.hasKey("allowEmptyValue"):
    result.allowEmptyValue = node["allowEmptyValue"].getBool
  if node.hasKey("schema"):
    result.schema = parseSchema(node["schema"])
  if node.hasKey("example"):
    result.example = node["example"]

proc parseParameters*(node: JsonNode): seq[Parameter] =
  if node.isNil or node.kind != JArray:
    return
  for item in node.elems:
    let p = parseParameter(item)
    if not p.isNil:
      result.add(p)

proc parseParameterMap*(node: JsonNode): OrderedTableRef[string, Parameter] =
  if node.isNil or node.kind != JObject:
    return
  new(result)
  for key, val in node.fields:
    result[key] = parseParameter(val)
