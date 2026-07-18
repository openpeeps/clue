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
import ../features/openapi/cluesettings

proc derivePkgId(pkg: Package): string =
  if pkg.oapi.isNil: return "client"
  let title = pkg.oapi.info.title.toLowerAscii
  var parts = title.split({' ', '/', '-', '_'})
  if parts.len == 0: return "client"
  result = parts[0]

proc openapiCommand*(v: Values) =
  ## Generate a new API client library from OpenAPI spec file
  let specpath = v.get("spec").getPath.path
  let outputDir = v.get("output").getStr

  if dirExists(outputDir):
    if v.has("-y"):
      removeDir(outputDir)
    else:
      displayWarning("Output directory already exists: " & outputDir)
      if not promptConfirm("Overwrite existing directory?"):
        displayInfo("Aborted")
        return
      removeDir(outputDir)

  var skipPrefixPath = ""
  if v.has("--config"):
    let configPath = v.get("--config").getStr
    if fileExists(configPath):
      let configContent = readFile(configPath)
      try:
        let settings = parseClueSettings(configContent)
        skipPrefixPath = settings.prefilters.routePrefix
      except CatchableError as e:
        displayWarning("Failed to parse config, using defaults: " & e.msg)

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
        verbose: false,
        skipComponentSchemas: v.has("--skipComponentSchemas")
      ),
      skipPrefixPath = skipPrefixPath
    )

    pkg.id = derivePkgId(pkg)

    if pkg.author.len == 0:
      let (gitName, _) = execCmdEx("git config user.name")
      pkg.author = gitName.strip()

    let gen = newGenerator(pkg, outputDir, skipPrefixPath)
    gen.generate()
    displaySuccess("Client package generated at " & outputDir)

  except CatchableError as e:
    displayError("Failed to parse spec: " & e.msg)

proc oapiInitCommand*(v: Values) =
  ## Initialize a default clue.openapi.config.yaml file
  let configPath = "clue.openapi.config.yaml"
  if fileExists(configPath):
    displayWarning("Config file already exists: " & configPath)
    if not promptConfirm("Overwrite existing file?"):
      displayInfo("Aborted")
      return
  let content = dumpDefaultSettings()
  writeFile(configPath, content)
  displaySuccess("Created " & configPath)
