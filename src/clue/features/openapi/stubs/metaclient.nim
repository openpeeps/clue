# {clue_pkg_name} API client for Nim
#
# Auto-generated from OpenAPI 3.x specification
# using the awesome [Clue CLI Assistant](https://github.com/openpeeps/clue)
#
# Generated at: {clue_pkg_generation_time}
# License: {clue_pkg_license}

import std/[asyncdispatch, httpclient, tables,
        strutils, sequtils, times, uri]

import pkg/openparser/json

export asyncdispatch, httpclient, json, tables, sequtils, times

type
  {clue_client_ident}* = ref object of RootObj
    baseUri*: string
    httpClient*: AsyncHttpClient
    apiKey*: string

  QueryTable* = OrderedTable[string, string]

  {clue_client_ident_error}* = object of CatchableError

proc `$`*(query: QueryTable): string =
  if query.len > 0:
    add result, "?"
    add result, join(query.keys.toSeq.mapIt(it & "=" & query[it]), "&")

proc init{clue_client_ident}*(apiKey: string): {clue_client_ident} =
  new(result)
  result.baseUri = "{clue_base_uri}"
  result.httpClient = newAsyncHttpClient()
  result.httpClient.headers = newHttpHeaders({
    "Accept": "application/json",
    "Authorization": "Bearer " & apiKey
  })
  result.apiKey = apiKey

proc httpGet*(client: {clue_client_ident},
  endpoint: string): Future[AsyncResponse] {.async.} =
  let url = client.baseUri & endpoint
  result = await client.httpClient.get(url)

proc httpGet*(client: {clue_client_ident},
  endpoint: string, query: QueryTable): Future[AsyncResponse] {.async.} =
  let url = client.baseUri & endpoint & $query
  result = await client.httpClient.get(url)

proc httpPost*[T](client: {clue_client_ident},
  endpoint: string, body: T): Future[AsyncResponse] {.async.} =
  let url = client.baseUri & endpoint
  result = await client.httpClient.post(url, toJson(body))

proc httpPost*(client: {clue_client_ident},
  endpoint: string): Future[AsyncResponse] {.async.} =
  let url = client.baseUri & endpoint
  result = await client.httpClient.post(url)

proc httpPost*(client: {clue_client_ident},
  endpoint: string, query: QueryTable): Future[AsyncResponse] {.async.} =
  let url = client.baseUri & endpoint & $query
  result = await client.httpClient.post(url)

proc httpPut*[T](client: {clue_client_ident},
  endpoint: string, body: T): Future[AsyncResponse] {.async.} =
  let url = client.baseUri & endpoint
  result = await client.httpClient.request(url, httpMethod = HttpPut,
    body = toJson(body))

proc httpPut*(client: {clue_client_ident},
  endpoint: string): Future[AsyncResponse] {.async.} =
  let url = client.baseUri & endpoint
  result = await client.httpClient.request(url, httpMethod = HttpPut)

proc httpPut*(client: {clue_client_ident},
  endpoint: string, query: QueryTable): Future[AsyncResponse] {.async.} =
  let url = client.baseUri & endpoint & $query
  result = await client.httpClient.request(url, httpMethod = HttpPut)

proc httpDelete*(client: {clue_client_ident},
  endpoint: string): Future[AsyncResponse] {.async.} =
  let url = client.baseUri & endpoint
  result = await client.httpClient.request(url, httpMethod = HttpDelete)

proc httpDelete*(client: {clue_client_ident},
  endpoint: string, query: QueryTable): Future[AsyncResponse] {.async.} =
  let url = client.baseUri & endpoint & $query
  result = await client.httpClient.request(url, httpMethod = HttpDelete)

proc httpPatch*[T](client: {clue_client_ident},
  endpoint: string, body: T): Future[AsyncResponse] {.async.} =
  let url = client.baseUri & endpoint
  result = await client.httpClient.request(url, httpMethod = HttpPatch,
    body = toJson(body))

proc httpPatch*(client: {clue_client_ident},
  endpoint: string): Future[AsyncResponse] {.async.} =
  let url = client.baseUri & endpoint
  result = await client.httpClient.request(url, httpMethod = HttpPatch)
