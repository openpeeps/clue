# Clue - A cool toolkit for Nim developers
#
# (c) 2026 George Lemon | LGPLv3 License
#          Made by Humans from OpenPeeps
#          https://github.com/openpeeps/clue

import std/[tables, strutils, json]
import ./ir

proc resolveRef*(oapi: OpenApi, refPath: string): JsonNode =
  if refPath.len == 0:
    return nil
  if not refPath.startsWith("#/"):
    return nil
  let parts = refPath[2..^1].split("/")
  if parts.len < 2:
    return nil
  let section = parts[0]
  let key = parts[1..^1].join("/")
  case section
  of "components":
    if parts.len < 2:
      return nil
    let componentSection = parts[1]
    let componentKey = parts[2..^1].join("/")
    case componentSection
    of "schemas":
      if componentKey in oapi.components.schemas:
        let s = oapi.components.schemas[componentKey]
        if s.refPath.len > 0:
          return resolveRef(oapi, s.refPath)
        result = %*{"type": "object"}
        if s.properties.len > 0:
          var props = newJObject()
          for name, prop in s.properties:
            props[name] = resolveRef(oapi, prop.refPath)
          result["properties"] = props
    of "parameters":
      if componentKey in oapi.components.parameters:
        let p = oapi.components.parameters[componentKey]
        if p.refPath.len > 0:
          return resolveRef(oapi, p.refPath)
    of "requestBodies":
      if componentKey in oapi.components.requestBodies:
        let rb = oapi.components.requestBodies[componentKey]
        if rb.refPath.len > 0:
          return resolveRef(oapi, rb.refPath)
    of "responses":
      if componentKey in oapi.components.responses:
        let r = oapi.components.responses[componentKey]
        if r.refPath.len > 0:
          return resolveRef(oapi, r.refPath)
    of "securitySchemes":
      if componentKey in oapi.components.securitySchemes:
        let ss = oapi.components.securitySchemes[componentKey]
        if ss.refPath.len > 0:
          return resolveRef(oapi, ss.refPath)
    else:
      discard
  else:
    discard
