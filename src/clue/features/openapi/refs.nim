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

proc resolveParameterRef*(param: Parameter, components: Components) =
  ## Resolve a `$ref` parameter (`#/components/parameters/<key>`) in place,
  ## copying the referenced definition's fields onto `param`.
  if param.isNil or param.refPath.len == 0:
    return
  let parts = param.refPath.split("/")
  if parts.len < 3 or parts[^2] != "parameters":
    return
  let key = parts[^1]
  if components.parameters.isNil or not components.parameters.hasKey(key):
    return
  let t = components.parameters[key]
  param.name = t.name
  param.description = t.description
  param.kind = t.kind
  param.required = t.required
  param.deprecated = t.deprecated
  param.allowEmptyValue = t.allowEmptyValue
  param.schema = t.schema
  param.example = t.example

proc resolveRequestBodyRef*(op: Operation, components: Components) =
  ## Resolve a `$ref` requestBody (`#/components/requestBodies/<key>`) in place.
  if op.isNil or op.requestBody.isNil or op.requestBody.refPath.len == 0:
    return
  let rb = op.requestBody
  let parts = rb.refPath.split("/")
  if parts.len < 3 or parts[^2] != "requestBodies":
    return
  let key = parts[^1]
  if components.requestBodies.isNil or not components.requestBodies.hasKey(key):
    return
  let t = components.requestBodies[key]
  rb.description = t.description
  rb.required = t.required
  rb.content = t.content

proc resolveResponseRefs*(op: Operation, components: Components) =
  ## Resolve `$ref` responses (`#/components/responses/<key>`) in place.
  if op.isNil or op.responses.isNil:
    return
  for code, resp in op.responses.pairs:
    if resp.isNil or resp.refPath.len == 0:
      continue
    let parts = resp.refPath.split("/")
    if parts.len < 3 or parts[^2] != "responses":
      continue
    let key = parts[^1]
    if components.responses.isNil or not components.responses.hasKey(key):
      continue
    let t = components.responses[key]
    resp.description = t.description
    resp.headers = t.headers
    resp.content = t.content

proc resolveOperationRefs*(oapi: OpenApi) =
  ## Resolve `$ref` parameters / requestBodies / responses across every path
  ## item and operation against the parsed components.
  if oapi.isNil or oapi.paths.isNil:
    return
  let components = oapi.components
  for pathItem in oapi.paths.values:
    if pathItem.isNil:
      continue
    for p in pathItem.parameters.mitems:
      resolveParameterRef(p, components)
    for op in [pathItem.get, pathItem.put, pathItem.post, pathItem.delete,
               pathItem.patch, pathItem.options, pathItem.head, pathItem.trace]:
      if op.isNil:
        continue
      for p in op.parameters.mitems:
        resolveParameterRef(p, components)
      resolveRequestBodyRef(op, components)
      resolveResponseRefs(op, components)
