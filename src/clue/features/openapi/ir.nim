# Clue - A cool toolkit for Nim developers
#
# (c) 2026 George Lemon | LGPLv3 License
#          Made by Humans from OpenPeeps
#          https://github.com/openpeeps/clue

import std/[tables, json]
export json

type
  ServerVariable* = object
    default*: string
    description*: string
    `enum`*: seq[string]

  Server* = object
    url*: string
    description*: string
    variables*: OrderedTableRef[string, ServerVariable]

  OpenApiInfo* = object
    title*: string
    version*: string
    description*: string
    termsOfService*: string
    contact*: JsonNode
    license*: JsonNode

  SchemaType* = enum
    stObject = "object"
    stArray = "array"
    stString = "string"
    stInteger = "integer"
    stNumber = "number"
    stBoolean = "boolean"

  IntegerFormat* = enum
    ifAny = "-"
    int32 = "int32"
    int64 = "int64"

  NumberFormat* = enum
    nfAny = "-"
    nfFloat = "float"
    nfDouble = "double"

  Schema* = ref object
    refPath*: string
    name*: string
    title*: string
    description*: string
    nullable*: bool
    readOnly*: bool
    writeOnly*: bool
    deprecated*: bool
    fieldType*: SchemaType
    enumValues*: seq[string]
    default*: JsonNode
    example*: JsonNode
    properties*: OrderedTableRef[string, Schema]
    required*: seq[string]
    allOf*: seq[Schema]
    oneOf*: seq[Schema]
    anyOf*: seq[Schema]
    items*: Schema
    minItems*, maxItems*: int64
    stringFormat*: string
    pattern*: string
    minLength*, maxLength*: int64
    integerFormat*: IntegerFormat
    intMin*, intMax*: int64
    numberFormat*: NumberFormat
    floatMin*, floatMax*: float64

  ParameterIn* = enum
    pinQuery = "query"
    pinHeader = "header"
    pinPath = "path"
    pinCookie = "cookie"

  Parameter* = ref object
    refPath*: string
    name*: string
    description*: string
    kind*: ParameterIn
    required*: bool
    deprecated*: bool
    allowEmptyValue*: bool
    schema*: Schema
    example*: JsonNode

  MediaType* = object
    schema*: Schema
    example*: JsonNode

  RequestBody* = ref object
    refPath*: string
    description*: string
    required*: bool
    content*: OrderedTableRef[string, MediaType]

  Response* = ref object
    refPath*: string
    description*: string
    headers*: OrderedTableRef[string, Parameter]
    content*: OrderedTableRef[string, MediaType]

  Operation* = ref object
    tags*: seq[string]
    summary*: string
    description*: string
    operationId*: string
    parameters*: seq[Parameter]
    requestBody*: RequestBody
    responses*: OrderedTableRef[string, Response]
    deprecated*: bool
    security*: seq[SecurityRequirement]
    servers*: seq[Server]

  PathItem* = ref object
    summary*: string
    description*: string
    parameters*: seq[Parameter]
    get*: Operation
    put*: Operation
    post*: Operation
    delete*: Operation
    options*: Operation
    head*: Operation
    patch*: Operation
    trace*: Operation

  SecuritySchemeType* = enum
    sstApiKey = "apiKey"
    sstHttp = "http"
    sstOAuth2 = "oauth2"
    sstOpenIdConnect = "openIdConnect"

  SecurityScheme* = ref object
    refPath*: string
    schemeType*: SecuritySchemeType
    description*: string
    name*: string
    location*: string
    scheme*: string
    bearerFormat*: string
    flows*: JsonNode
    openIdConnectUrl*: string

  SecurityRequirement* = OrderedTableRef[string, seq[string]]

  Components* = object
    schemas*: OrderedTableRef[string, Schema]
    parameters*: OrderedTableRef[string, Parameter]
    requestBodies*: OrderedTableRef[string, RequestBody]
    responses*: OrderedTableRef[string, Response]
    securitySchemes*: OrderedTableRef[string, SecurityScheme]
    headers*: OrderedTableRef[string, Parameter]

  ExternalDocs* = object
    description*: string
    url*: string

  Tag* = object
    name*: string
    description*: string
    externalDocs*: ExternalDocs

  OpenApi* = ref object
    openapi*: string
    info*: OpenApiInfo
    servers*: seq[Server]
    paths*: OrderedTableRef[string, PathItem]
    components*: Components
    tags*: seq[Tag]
    security*: seq[SecurityRequirement]
    externalDocs*: ExternalDocs

  OpenApiError* = object of CatchableError
