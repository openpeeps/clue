# Clue - A cool toolkit for Nim developers
#
# (c) 2026 George Lemon | LGPLv3 License
#          Made by Humans from OpenPeeps
#          https://github.com/openpeeps/clue

import std/[os, osproc, strutils, httpclient]

import pkg/kapsis/runtime
import pkg/kapsis/interactive/prompts
import pkg/openparser/json as openjson

import ../features/openapi/specparser
import ../features/openapi/codegen

proc derivePkgId(pkg: Package): string =
  if pkg.oapi.isNil: return "client"
  let title = pkg.oapi.info.title.toLowerAscii
  var parts = title.split({' ', '/', '-', '_'})
  if parts.len == 0: return "client"
  result = parts[0]

proc openapiCommand*(v: Values) =
  ## Generate a new API client library from OpenAPI spec file
  let outputPath =
    if v.has("--output"):
      v.get("--output").getStr
    else: ""
  let outputDir =
    if v.has("--dir"):
      v.get("--dir").getStr
    else: ""

  let specpath = v.get("spec").getPath.path

  var root: openjson.JsonNode
  if specpath.fileExists:
    if specpath.endsWith(".yml") or specpath.endsWith(".yaml"):
      let content = readFile(specpath)
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
        root = openjson.fromJsonFile(specpath)
      except:
        displayError("Failed to parse JSON spec: " & getCurrentExceptionMsg())
        return
  elif specpath.startsWith("http://") or specpath.startsWith("https://"):
    var httpClient = newHttpClient()
    try:
      let content = httpClient.getContent(specpath)
      try:
        root = openjson.fromJson(content)
      except:
        displayError("Failed to parse spec: " & getCurrentExceptionMsg())
        return
    finally:
      httpClient.close()
  else:
    displayError("Spec file not found: " & specpath)
    return

  try:
    var pkg = Package(
      id: "",
      description: "Awesome Nim client",
      author: "",
      license: "MIT",
    )

    pkg.parseSpecification(
      root,
      prefs = PackagePreferences(
        verbose: outputDir.len == 0 and outputPath.len == 0,
        skipComponentSchemas: v.has("--skipComponentSchemas")
      )
    )

    pkg.id = derivePkgId(pkg)

    if pkg.author.len == 0:
      let (gitName, _) = execCmdEx("git config user.name")
      pkg.author = gitName.strip()

    if outputPath.len > 0:
      writeFile(outputPath, dumpIR(pkg))
      displaySuccess("IR written to " & outputPath)

    if outputDir.len > 0:
      let gen = newGenerator(pkg, outputDir)
      gen.generate()
      displaySuccess("Client package generated at " & outputDir)
    elif outputPath.len == 0:
      displayInfo("Use --dir <path> to generate the client package")

  except CatchableError as e:
    displayError("Failed to parse spec: " & e.msg)
