# Clue - A cool toolkit for Nim developers
#
# (c) 2026 George Lemon | MIT License
#          Made by Humans from OpenPeeps
#          https://github.com/openpeeps/clue

import std/[tables, json]
import ../ir
import ./schemas, ./parameters, ./requestBodies, ./responses, ./security

proc parseComponents*(node: JsonNode): Components =
  if node.isNil or node.kind != JObject:
    return
  if node.hasKey("schemas"):
    result.schemas = parseSchemaMap(node["schemas"])
  if node.hasKey("parameters"):
    result.parameters = parseParameterMap(node["parameters"])
  if node.hasKey("requestBodies"):
    result.requestBodies = parseRequestBodyMap(node["requestBodies"])
  if node.hasKey("responses"):
    result.responses = parseResponseMap(node["responses"])
  if node.hasKey("securitySchemes"):
    result.securitySchemes = parseSecuritySchemeMap(node["securitySchemes"])
  if node.hasKey("headers"):
    result.headers = parseParameterMap(node["headers"])
