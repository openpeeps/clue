# Clue - A cool toolkit for Nim developers
#
# (c) 2026 George Lemon | MIT License
#          Made by Humans from OpenPeeps
#          https://github.com/openpeeps/clue

import std/[tables, strutils, sequtils,
        macros, os, times, wordwrap, hashes]

import pkg/semver
import pkg/kapsis/interactive/prompts
import pkg/openparser/[json, yaml]

from std/httpcore import HttpMethod, HttpCode, `$`

## OpenAPI specification parser and intermediary representation for fast code generation
## and pretty easy to work with.
## 
## The intermediary representation is using auto mapping from the JSON/YAML specification
## to Nim objects and JsonNode (where flexibility is needed). Once we have the IR structures
## we can then use it to generate the client code in the generator module.

type
  # OpenAPI Specification Types, most of these are JSON objects for flexibility
  # and to avoid overcomplicating the intermediary representation, since the generator
  # primarily needs to access specific fields and values rather than having a strict
  # type structure for the entire specification
  OpenApiSchema = JsonNode
    # https://github.com/OAI/OpenAPI-Specification/blob/main/versions/3.0.3.md#reference-object
    # https://github.com/OAI/OpenAPI-Specification/blob/main/versions/3.0.3.md#reference-object
  OpenApiParameter = JsonNode
  OpenApiRoutePath = string
  OpenApiMethod = string
  OpenApiPaths = JsonNode
  OpenApiSecuritySchemes = JsonNode

  OpenApiComponents* = object
    ## Components object representation, used to store reusable components
    ## # defined in the OpenAPI specification
    parameters*: OrderedTable[string, OpenApiParameter]
      ## A table of reusable parameters that can be referenced in path definitions.
    schemas*: OrderedTable[string, OpenApiSchema]
      ## A table of reusable schemas that can be referenced in path definitions.
    securitySchemes*: OpenApiSecuritySchemes
      ## A table of reusable security schemes that can be referenced in path definitions.
  
  OpenApiInfo* = tuple
    title: string
    version: string
    description: string

  OpenApi* = ref object
    ## OpenAPI Specification object representation,
    ## used as an intermediary representation for the generator
    openapi*: string # version
      ## The OpenAPI Specification version.
    info: OpenApiInfo
    components*: OpenApiComponents
      ## The components section of the OpenAPI specification, containing reusable components

#
# OpenAPI Package and Module Representation
#
type
  SchemaType* = enum
    ## The `SchemaType` enum represents the different
    ## types of data structures
    typeObject = "object"
    typeArray = "array"
    typeString = "string"
    typeInteger = "integer"
    typeNumber = "number"
    typeFloat = "float64"
    typeBool = "boolean"

  NumberFormat* = enum
    ## The `numberAny` format represents any number type without
    ## a specific size constraint.
    numberAny = "-"           # any float numbers
    numberFloat = "float"     # floating-point numbers
    numberDouble = "double"   # floating-point numbers with double precision
  
  IntegerFormat* = enum
    ## The `integerAny` format represents any integer
    ## type without a specific size constraint. It can be
    ## used when the OpenAPI specification does not specify
    ## a particular integer format or when the generator
    ## should not enforce a specific size for integer values.
    integerAny = "-"
    integer32 = "int32"
    integer64 = "int64"

  Schema {.acyclic.} = ref object
    name*: string
      ## The `name` field represents the name of the spec,
      ## which can be used for reference and documentation purposes in the generated code.
    description*: string
      ## The `description` field provides a textual description
      ## of the spec, which can be used to generate documentation comments in the generated code, giving context and information about the spec's purpose and usage.
    nullable*: bool
      ## The `nullable` field indicates whether the spec
      ## allows null values.
    required*: seq[string] # used by array/object schemas
      ## A sequence of required field names for array or
      ## object schemas, indicating
    case fieldType*: SchemaType
    of typeObject:
      properties*: OrderedTable[string, Schema]
        ## The `properties` field is a table of property names and their
        ## corresponding `Schema` definitions for object types, allowing the generator to understand the structure of objects defined in the OpenAPI specification
        ## and generate appropriate code to represent them.
    of typeString:
      stringFormat*: string
        ## The `stringFormat` field provides additional information
        ## about the format of string types, which can be used to generate more specific code for handling different string formats defined in the OpenAPI specification.
    of typeArray:
      arrayItems: seq[Schema]
        ## The `arrayItems` field is a sequence of `Schema`
        ## definitions for the items in an array type, allowing the generator to understand the structure of arrays defined in the OpenAPI specification and generate appropriate code to represent them.
    of typeInteger:
      integerFormat: IntegerFormat
        ## The `integerFormat` field provides additional information
        ## about the format of integer types, which can be used to generate more specific code for handling different integer formats defined in the OpenAPI specification.
    of typeNumber:
      numberFormat: NumberFormat
        ## The `numberFormat` field provides additional information about the format of number types, which can be used to generate more specific code for handling different number formats
        ## defined in the OpenAPI specification.
    else: discard

#
# Package Module API
#
type
  PackageModuleType = enum
    mtModule
    mtModuleEnums
    mtMeta

  PackageModule {.acyclic.} = ref object
    moduleName*, clientName*: string
      # The name of the module and the client class to be generated,
      # used to organize the generated code into modules and classes
    description*: string
      ## Used to create document-based comments for the module
      ## and its contents in the generated code, providing context and information

  OpenApiError* = object of CatchableError

#
# Package API
#
type
  EnumName = string # enum identifier name
  EnumKeyValPairs = (string, string)
  EnumStructure = tuple[fields: seq[EnumKeyValPairs], skipUseGlobal: bool]

  PackageGlobalEnums = OrderedTableRef[EnumName, EnumStructure]

  PackagePreferences* = object
    ## Preferences for package generation, used to control
    ## the behavior of the generator
    verbose*: bool = true
      ## The `verbose` preference enables detailed logging during the generation
      ## process, which can be helpful for debugging and understanding the steps
      ## taken by the generator.
    skipComponentSchemas*: bool
      ## A preference to skip generating code for component schemas defined in the
      ## OpenAPI specification, which can be useful if the user only wants to generate
      ## code for the paths and operations without including the component schemas
      ## in the generated code.
  
  Package* = ref object
    ## The `Package` type represents the overall package being generated
    ## from the OpenAPI specification, containing metadata, preferences, and
    ## intermediary representations of the specification for use during code generation.
    id*, author*, description*,
      license*, url*, outputPath*: string
    version*: semver.Version
      ## The `version` field represents the version of the package being generated,
      ## which can be used for versioning the generated code and for documentation purposes
    openApiVersion*: string
      ## The version of the OpenAPI specification used in the input spec file,
      ## stored for reference and potential use during generation
    oapi*: OpenApi
      ## The `oapi` field holds the intermediary representation of the OpenAPI specification,
      ## which is used as the primary source of data for generating the client code.
    enums*: PackageGlobalEnums
      ## Global enums extracted from the OpenAPI specification,
      ## used to generate global enum definitions in the
      ## generated code
    prefs*: PackagePreferences
      ## The `prefs` field holds the preferences for package generation,
      ## allowing the generator to adjust its behavior based on user-defined settings
    preparedSchemas*: OrderedTable[string, Schema]
      ## A table of prepared schemas that have been parsed and processed from the OpenAPI specification,
      ## used to store intermediary representations of schemas for easier access during code generation

const reservedWords* = ["addr","and","as","asm","bind","block","break","case","cast",
  "concept","const","continue", "converter","defer","discard","distinct","div","do",
  "elif","else","end","enum","except","export","finally","for","from","func","if",
  "import","in","include","interface","is","isnot","iterator","let","macro","method",
  "mixin","mod","nil","not","notin","object","of","or","out","proc","ptr","raise",
  "ref","return","shl","shr","static","template","try","tuple","type","using", "var",
  "when","while","xor","yield"]
  ## A list of reserved words in Nim that cannot be used as identifiers without
  ## escaping using the backticks syntax `addr`, `and`, `out`.

#
# Dumps Objects to JSON
#
proc `$`*(x: PackageModule): string = pretty(fromJson(x.toJson()))
# proc `$`*(x: Verb): string = x.toJson()
proc `$`*(x: JsonNode): string = pretty(x)
proc `$`*(x: OpenApi): string = pretty(fromJson(x.toJson()))
proc `$`*(x: Schema): string = pretty(fromJson(x.toJson()))

proc parseFieldSpec*(pkg: Package, fieldName: string, spec: JsonNode): Schema {.discardable.} =
  ## Parse a field specification from the OpenAPI spec and add it to the package
  ## as a global enum or other reusable component, depending on the spec definition
  case spec.kind
  of JObject:
    if spec.hasKey"type":
      let typ = spec["type"].getStr
      let fieldDesc = 
        if spec.hasKey"description":
          spec["description"].str
        else: newStringOfCap(0)
      let schemaType = parseEnum[SchemaType](spec["type"].str)
      case schemaType
      of typeArray:
        discard
      of typeObject:
        # handle object spec, extract properties and required fields
        if spec.hasKey"properties":
          let requiredFields =
            if spec.hasKey("required"):
              spec["required"].elems.mapIt(it.getStr)
            else: @[]

          var propTable = initOrderedTable[string, Schema]()
          # recursively parse the property schema and add it to the propTable
          # this allows us to handle nested objects and arrays in the OpenAPI spec
          for propName, propSchema in spec["properties"]:
            propTable[propName] = pkg.parseFieldSpec(propName, propSchema)

          # collect metadata for object fields, including the properties and required fields
          let fieldName = 
            if spec.hasKey"title":
              spec["title"].getStr
            else: fieldName
          result = Schema(
            name: fieldName,
            description: if spec.hasKey("description"): spec["description"].getStr else: "",
            nullable: if spec.hasKey("nullable"): spec["nullable"].getBool else: false,
            required: requiredFields,
            fieldType: SchemaType.typeObject,
            properties: propTable
          )
          # echo result
      of typeInteger:
        # Collect metadata for `typeInteger` fields
        let integerFormat = 
          if spec.hasKey"format":
            parseEnum[IntegerFormat](spec["format"].str)
          else: integerAny
        result = Schema(fieldType: typeInteger, name: fieldName, description: fieldDesc, integerFormat: integerFormat)
      of typeNumber:
        # Collect metadata for `typeNumber` fields
        let numberFormat =
          if spec.hasKey"format":
            parseEnum[NumberFormat](spec["format"].str)
          else: numberAny
        result = Schema(fieldType: typeNumber, name: fieldName, description: fieldDesc, numberFormat: numberFormat)
      of typeString:
        result = Schema(fieldType: typeString, name: fieldName, description: fieldDesc)
      else: discard
    else:
      discard
  else:
    echo "Unhandled spec type for field: ", fieldName

proc parseSpecification*(pkg: Package, specPath: string,
  prefs: PackagePreferences, parseAsYaml = false,
  skipPrefixPath: string = newStringOfCap(0)
) =
  ## Parses the OpenAPI specification content and populates the package object
  ## with the relevant data and intermediary representation for code generation.
  display("📚 Reading OpenAPI specification...")
  let gentime = now()

  # Initialize the package with the provided metadata and preferences  
  pkg.enums = PackageGlobalEnums()
  pkg.prefs = prefs

  # Parse the OpenAPI specification content into the intermediary representation
  # from either YAML or JSON format, depending on the input
  # if parseAsYaml: pkg.oapi = parseYAML(content, OpenApi)
  
  pkg.oapi = fromJson(readFile(specPath), OpenApi)
  pkg.openApiVersion = pkg.oapi.openapi

  echo pkg.oapi.info

  # now that we have the first intermediary representation
  # we can start parsing specific sections of the OAPI spec
  for schemaName, spec in pkg.oapi.components.schemas:
    let parsedField = pkg.parseFieldSpec(schemaName, spec)
    pkg.preparedSchemas[schemaName] = parsedField

when isMainModule:
  var pkg = Package(
    id: "hetzner",
    description: "AWS Certificate Manager Private Certificate Authority Client",
    author: "George Lemon",
    license: "MIT",
    outputPath: "./examples/aws_cert_manager_pca_client",
  )
  
  pkg.parseSpecification(
    "examples/openapi/aws.spec.json",
    prefs = PackagePreferences(
      verbose: true,
      skipComponentSchemas: false
    ),
    parseAsYaml = false
  )