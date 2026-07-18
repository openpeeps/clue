import std/json
import pkg/openparser/yaml

type
  PreFilters* = object
    routePrefix*: string

  ClueOpenApiSettings* = object
    prefilters*: PreFilters

proc parseClueSettings*(yamlContent: string): ClueOpenApiSettings =
  result = parseYAML(yamlContent, ClueOpenApiSettings)

proc dumpDefaultSettings*(): YAML =
  let root = %*{
    "prefilters": {
      "routePrefix": ""
    }
  }
  result = dump(root)
