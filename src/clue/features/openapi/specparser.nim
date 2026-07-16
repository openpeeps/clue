# Clue - A cool toolkit for Nim developers
#
# (c) 2026 George Lemon | LGPLv3 License
#          Made by Humans from OpenPeeps
#          https://github.com/openpeeps/clue

import std/[tables, json, strformat]
import pkg/semver
import pkg/openparser/json as openjson
from pkg/kapsis/interactive/prompts import displayInfo, displayWarning, displayError
import ./ir, ./refs
import ./parsers/[servers, paths, security, components]

export ir, refs

type
  EnumName = string
  EnumKeyValPairs = (string, string)
  EnumStructure = tuple[fields: seq[EnumKeyValPairs], skipUseGlobal: bool]

  PackageGlobalEnums = OrderedTableRef[EnumName, EnumStructure]

  PackagePreferences* = object
    verbose*: bool = true
    skipComponentSchemas*: bool

  PackageModule* = ref object
    moduleName*, clientName*: string
    description*: string

  Package* = ref object
    id*, author*, description*, license*, url*, outputPath*: string
    version*: semver.Version
    openApiVersion*: string
    oapi*: OpenApi
    enums*: PackageGlobalEnums
    prefs*: PackagePreferences
    preparedSchemas*: OrderedTableRef[string, Schema]

const reservedWords* = ["addr","and","as","asm","bind","block","break","case","cast",
  "concept","const","continue", "converter","defer","discard","distinct","div","do",
  "elif","else","end","enum","except","export","finally","for","from","func","if",
  "import","in","include","interface","is","isnot","iterator","let","macro","method",
  "mixin","mod","nil","not","notin","object","of","or","out","proc","ptr","raise",
  "ref","return","shl","shr","static","template","try","tuple","type","using", "var",
  "when","while","xor","yield"]

proc parseSpecification*(pkg: Package, content: string,
  prefs: PackagePreferences,
  parseAsYaml = false,
  skipPrefixPath = ""
) =
  pkg.prefs = prefs
  pkg.enums = PackageGlobalEnums()
  pkg.preparedSchemas = newOrderedTable[string, Schema]()

  var root: JsonNode
  if parseAsYaml:
    try:
      root = openjson.fromJson(content)
      if root.isNil:
        displayError("Failed to parse YAML spec")
        return
    except:
      displayError("Failed to parse YAML spec: " & getCurrentExceptionMsg())
      return
  else:
    try:
      root = openjson.fromJson(content)
    except:
      displayError("Failed to parse JSON spec: " & getCurrentExceptionMsg())
      return

  if root.isNil or root.kind != JObject:
    displayError("Spec content is empty or not a valid JSON object")
    return

  new(pkg.oapi)

  if root.hasKey("openapi"):
    pkg.oapi.openapi = root["openapi"].getStr
    pkg.openApiVersion = pkg.oapi.openapi

  if root.hasKey("info") and root["info"].kind == JObject:
    let infoNode = root["info"]
    pkg.oapi.info = OpenApiInfo()
    if infoNode.hasKey("title"):
      pkg.oapi.info.title = infoNode["title"].getStr
    if infoNode.hasKey("version"):
      pkg.oapi.info.version = infoNode["version"].getStr
    if infoNode.hasKey("description"):
      pkg.oapi.info.description = infoNode["description"].getStr
    if infoNode.hasKey("termsOfService"):
      pkg.oapi.info.termsOfService = infoNode["termsOfService"].getStr
    if infoNode.hasKey("contact"):
      pkg.oapi.info.contact = infoNode["contact"]
    if infoNode.hasKey("license"):
      pkg.oapi.info.license = infoNode["license"]

  if root.hasKey("servers"):
    pkg.oapi.servers = parseServers(root["servers"])

  if root.hasKey("paths"):
    pkg.oapi.paths = parsePaths(root["paths"])

  if root.hasKey("components"):
    pkg.oapi.components = parseComponents(root["components"])

  if root.hasKey("tags") and root["tags"].kind == JArray:
    for t in root["tags"].elems:
      if t.kind == JObject:
        var tag = Tag()
        if t.hasKey("name"):
          tag.name = t["name"].getStr
        if t.hasKey("description"):
          tag.description = t["description"].getStr
        if t.hasKey("externalDocs") and t["externalDocs"].kind == JObject:
          tag.externalDocs = ExternalDocs()
          if t["externalDocs"].hasKey("url"):
            tag.externalDocs.url = t["externalDocs"]["url"].getStr
          if t["externalDocs"].hasKey("description"):
            tag.externalDocs.description = t["externalDocs"]["description"].getStr
        pkg.oapi.tags.add(tag)

  if root.hasKey("externalDocs") and root["externalDocs"].kind == JObject:
    pkg.oapi.externalDocs = ExternalDocs()
    if root["externalDocs"].hasKey("url"):
      pkg.oapi.externalDocs.url = root["externalDocs"]["url"].getStr
    if root["externalDocs"].hasKey("description"):
      pkg.oapi.externalDocs.description = root["externalDocs"]["description"].getStr

  if root.hasKey("security"):
    pkg.oapi.security = parseSecurityRequirements(root["security"])

  if pkg.oapi.info.title.len > 0:
    displayInfo(&"Parsed spec: {pkg.oapi.info.title} v{pkg.oapi.info.version}")
  else:
    displayInfo(&"Parsed OpenAPI v{pkg.oapi.openapi}")

  for schemaName, spec in pkg.oapi.components.schemas.pairs:
    pkg.preparedSchemas[schemaName] = spec
    if prefs.verbose:
      displayInfo("  schema: " & schemaName)

proc dumpIR*(pkg: Package): string =
  if pkg.oapi.isNil:
    return "{}"
  try:
    let raw = openjson.toJson(pkg.oapi)
    let node = openjson.fromJson(raw)
    pretty(node)
  except:
    openjson.toJson(pkg.oapi)

when isMainModule:
  var pkg = Package(
    id: "hetzner",
    description: "Hetzner Cloud API Client",
    author: "George Lemon",
    license: "MIT",
    outputPath: "./examples/hetzner_client"
  )
  let specContent = readFile("examples/openapi/hetzner.spec.json")
  pkg.parseSpecification(
    specContent,
    prefs = PackagePreferences(verbose: true, skipComponentSchemas: false),
    parseAsYaml = false
  )
  echo dumpIR(pkg)
