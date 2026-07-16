# Clue - A cool toolkit for Nim developers
#
# (c) 2026 George Lemon | MIT License
#          Made by Humans from OpenPeeps
#          https://github.com/openpeeps/clue

import std/[tables, json, strutils]
import ../ir

proc parseSchema*(node: JsonNode): Schema

proc parseProperties*(node: JsonNode): OrderedTableRef[string, Schema] =
  if node.isNil or node.kind != JObject:
    return
  new(result)
  for key, val in node.fields:
    result[key] = parseSchema(val)

proc parseSchemaArray*(node: JsonNode): seq[Schema] =
  if node.isNil or node.kind != JArray:
    return
  for item in node.elems:
    let s = parseSchema(item)
    if not s.isNil:
      result.add(s)

proc detectSchemaType(node: JsonNode): SchemaType =
  if node.hasKey("type"):
    try:
      return parseEnum[SchemaType](node["type"].getStr)
    except:
      return stObject
  if node.hasKey("properties") or
     node.hasKey("allOf") or
     node.hasKey("oneOf") or
     node.hasKey("anyOf"):
    return stObject
  if node.hasKey("items"):
    return stArray
  if node.hasKey("enum"):
    return stString
  stObject

proc parseSchema*(node: JsonNode): Schema =
  if node.isNil or node.kind != JObject:
    return nil
  new(result)
  if node.hasKey("$ref"):
    result.refPath = node["$ref"].getStr
    return
  result.fieldType = detectSchemaType(node)
  if node.hasKey("name"):
    result.name = node["name"].getStr
  if node.hasKey("title"):
    result.title = node["title"].getStr
  if node.hasKey("description"):
    result.description = node["description"].getStr
  if node.hasKey("nullable"):
    result.nullable = node["nullable"].getBool
  if node.hasKey("readOnly"):
    result.readOnly = node["readOnly"].getBool
  if node.hasKey("writeOnly"):
    result.writeOnly = node["writeOnly"].getBool
  if node.hasKey("deprecated"):
    result.deprecated = node["deprecated"].getBool
  if node.hasKey("default"):
    result.default = node["default"]
  if node.hasKey("example"):
    result.example = node["example"]
  if node.hasKey("enum") and node["enum"].kind == JArray:
    for e in node["enum"].elems:
      result.enumValues.add(
        if e.kind == JString: e.getStr
        else: $e
      )
  if node.hasKey("properties"):
    result.properties = parseProperties(node["properties"])
  if node.hasKey("required") and node["required"].kind == JArray:
    for r in node["required"].elems:
      result.required.add(r.getStr)
  if node.hasKey("allOf"):
    result.allOf = parseSchemaArray(node["allOf"])
  if node.hasKey("oneOf"):
    result.oneOf = parseSchemaArray(node["oneOf"])
  if node.hasKey("anyOf"):
    result.anyOf = parseSchemaArray(node["anyOf"])
  if node.hasKey("items"):
    result.items = parseSchema(node["items"])
  if node.hasKey("minItems"):
    result.minItems = node["minItems"].getInt
  if node.hasKey("maxItems"):
    result.maxItems = node["maxItems"].getInt
  if node.hasKey("format"):
    case result.fieldType
    of stString:
      result.stringFormat = node["format"].getStr
    of stInteger:
      try:
        result.integerFormat = parseEnum[IntegerFormat](node["format"].getStr)
      except:
        result.integerFormat = ifAny
    of stNumber:
      try:
        result.numberFormat = parseEnum[NumberFormat](node["format"].getStr)
      except:
        result.numberFormat = nfAny
    else: discard
  if node.hasKey("pattern"):
    result.pattern = node["pattern"].getStr
  if node.hasKey("minLength"):
    result.minLength = node["minLength"].getInt
  if node.hasKey("maxLength"):
    result.maxLength = node["maxLength"].getInt
  if node.hasKey("minimum"):
    case result.fieldType
    of stInteger: result.intMin = node["minimum"].getInt
    of stNumber: result.floatMin = node["minimum"].getFloat
    else: discard
  if node.hasKey("maximum"):
    case result.fieldType
    of stInteger: result.intMax = node["maximum"].getInt
    of stNumber: result.floatMax = node["maximum"].getFloat
    else: discard

proc parseSchemaMap*(node: JsonNode): OrderedTableRef[string, Schema] =
  if node.isNil or node.kind != JObject:
    return
  new(result)
  for key, val in node.fields:
    result[key] = parseSchema(val)
