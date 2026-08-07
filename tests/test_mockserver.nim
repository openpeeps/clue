import std/[strutils, sequtils, asyncdispatch, httpclient]
import unittest
import pkg/openparser/json as openjson

import clue/features/openapi/mockserver

proc mockSpec(): openjson.JsonNode =
  %*{
    "openapi": "3.0.3",
    "info": {"title": "Mock API", "version": "1.0.0"},
    "paths": {
      "/api/health": {
        "get": {
          "responses": {
            "200": {
              "description": "ok",
              "content": {
                "application/json": {
                  "schema": {
                    "type": "object",
                    "properties": {
                      "status": {"type": "string"},
                      "uptime": {"type": "number"}
                    }
                  }
                }
              }
            }
          }
        }
      },
      "/api/pets": {
        "get": {
          "responses": {
            "200": {
              "description": "list",
              "content": {
                "application/json": {
                  "schema": {
                    "type": "array",
                    "items": {"$ref": "#/components/schemas/Pet"}
                  }
                }
              }
            }
          }
        },
        "post": {
          "responses": {
            "201": {
              "description": "created",
              "content": {
                "application/json": {
                  "schema": {"$ref": "#/components/schemas/Pet"}
                }
              }
            }
          }
        }
      },
      "/api/pets/{petId}": {
        "get": {
          "responses": {
            "200": {
              "description": "a pet",
              "content": {
                "application/json": {
                  "schema": {"$ref": "#/components/schemas/Pet"}
                }
              }
            }
          }
        }
      }
    },
    "components": {
      "schemas": {
        "Pet": {
          "type": "object",
          "properties": {
            "id": {"type": "integer"},
            "name": {"type": "string"},
            "tag": {"type": "string", "enum": ["dog", "cat"]},
            "owner": {
              "type": "object",
              "properties": {"name": {"type": "string"}}
            }
          }
        },
        "Message": {
          "type": "object",
          "properties": {
            "text": {"type": "string", "example": "hello world"}
          }
        }
      }
    }
  }

suite "sampleJson":
  test "object with properties":
    let spec = mockSpec()
    let sample = sampleJson(spec, spec["components"]["schemas"]["Pet"])
    check sample.kind == JObject
    check sample["id"] == %1
    check sample["name"] == %"string"
    check sample["tag"] == %"dog"
    check sample["owner"]["name"] == %"string"

  test "string enum picks first value":
    let spec = mockSpec()
    let sample = sampleJson(spec, %*{"type": "string", "enum": ["a", "b", "c"]})
    check sample == %"a"

  test "array with items":
    let spec = mockSpec()
    let sample = sampleJson(spec, %*{"type": "array", "items": {"type": "integer"}})
    check sample.kind == JArray
    check sample.len == 1
    check sample[0] == %1

  test "example wins over generated value":
    let spec = mockSpec()
    let sample = sampleJson(spec, spec["components"]["schemas"]["Message"])
    check sample["text"] == %"hello world"

  test "default used when no example":
    let spec = mockSpec()
    let sample = sampleJson(spec, %*{"type": "string", "default": "fallback"})
    check sample == %"fallback"

  test "$ref resolution":
    let spec = mockSpec()
    let sample = sampleJson(spec, %*{"$ref": "#/components/schemas/Pet"})
    check sample.kind == JObject
    check sample["name"] == %"string"

  test "allOf merges properties":
    let spec = mockSpec()
    let sample = sampleJson(spec, %*{
      "allOf": [
        {"type": "object", "properties": {"a": {"type": "integer"}}},
        {"type": "object", "properties": {"b": {"type": "string"}}}
      ]
    })
    check sample["a"] == %1
    check sample["b"] == %"string"

  test "oneOf samples an empty object (matches generated type)":
    let spec = mockSpec()
    let sample = sampleJson(spec, %*{"oneOf": [{"type": "string"}, {"type": "integer"}]})
    check sample == %*{}

  test "anyOf samples an empty object (matches generated type)":
    let spec = mockSpec()
    let sample = sampleJson(spec, %*{"anyOf": [{"type": "string"}, {"type": "object", "properties": {"a": {"type": "integer"}}}]})
    check sample == %*{}

  test "integer uses minimum":
    let spec = mockSpec()
    let sample = sampleJson(spec, %*{"type": "integer", "minimum": 42})
    check sample == %42

suite "buildRoutes":
  test "builds a route per path and method":
    let routes = buildRoutes(mockSpec())
    check routes.len == 4
    check (routes[0].httpMethod, routes[0].path) == ("GET", "/api/health")
    check (routes[2].httpMethod, routes[2].path) == ("POST", "/api/pets")
    check (routes[3].httpMethod, routes[3].path) == ("GET", "/api/pets/{petId}")

  test "uses 2xx status code":
    let routes = buildRoutes(mockSpec())
    let post = routes.filterIt(it.httpMethod == "POST" and it.path == "/api/pets")[0]
    check post.statusCode == 201
    check post.reasonPhrase == "Created"

  test "resolves $ref schemas into response body":
    let routes = buildRoutes(mockSpec())
    let getPets = routes.filterIt(it.httpMethod == "GET" and it.path == "/api/pets")[0]
    check getPets.body.kind == JArray
    check getPets.body[0]["name"] == %"string"

proc fetch(port: Port, meth, path: string): Future[tuple[status: int, body: string]] {.async.} =
  let client = newAsyncHttpClient()
  defer: client.close()
  let resp = await client.request("http://127.0.0.1:" & $int(port) & path, parseEnum[HttpMethod](meth))
  result = (int(resp.code), await resp.body)

suite "mock server http":
  test "responds 200 with JSON body for a GET route":
    let server = newMockServer(mockSpec(), "127.0.0.1", Port(0))
    waitFor server.open()
    asyncCheck server.serve()
    let (status, body) = waitFor fetch(server.port, "GET", "/api/health")
    check status == 200
    check openjson.fromJson(body)["status"].getStr == "string"
    server.close()

  test "responds 201 for a POST route":
    let server = newMockServer(mockSpec(), "127.0.0.1", Port(0))
    waitFor server.open()
    asyncCheck server.serve()
    let (status, body) = waitFor fetch(server.port, "POST", "/api/pets")
    check status == 201
    check openjson.fromJson(body)["id"] == %1
    server.close()

  test "responds 404 for an unknown path":
    let server = newMockServer(mockSpec(), "127.0.0.1", Port(0))
    waitFor server.open()
    asyncCheck server.serve()
    let (status, body) = waitFor fetch(server.port, "GET", "/api/nope")
    check status == 404
    check openjson.fromJson(body)["error"].getStr == "Not Found"
    server.close()

  test "responds 405 for a wrong method on a known path":
    let server = newMockServer(mockSpec(), "127.0.0.1", Port(0))
    waitFor server.open()
    asyncCheck server.serve()
    let (status, _) = waitFor fetch(server.port, "DELETE", "/api/health")
    check status == 405

  test "responds with a route index at the root":
    let server = newMockServer(mockSpec(), "127.0.0.1", Port(0))
    waitFor server.open()
    asyncCheck server.serve()
    let (status, body) = waitFor fetch(server.port, "GET", "/")
    check status == 200
    let index = openjson.fromJson(body)
    check index["/api/health"]["get"] == %200
    check index["/api/pets"]["get"] == %200
    check index["/api/pets"]["post"] == %201
    check index["/api/pets/{petId}"]["get"] == %200
    server.close()
    server.close()
