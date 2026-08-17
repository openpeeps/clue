# Clue - A cool toolkit for Nim developers
#
# (c) 2026 George Lemon | LGPLv3 License
#          Made by Humans from OpenPeeps
#          https://github.com/openpeeps/clue

import std/[tables, strutils, os]
import pkg/semver
import pkg/sweetsyntax
import pkg/sweetsyntax/tokenizer
import pkg/sweetsyntax/engine/[ast, parser]
import pkg/sweetsyntax/languages/nim as nimHandlersMod
import ./configs
import ./resolver

proc stripQuotes(s: string): string =
  if s.len >= 2 and s[0] == '"' and s[^1] == '"': s[1..^2]
  elif s.len >= 2 and s[0] == '\'' and s[^1] == '\'': s[1..^2]
  else: s

proc normalizeVersion(v: string): string =
  let parts = v.split('.')
  result = v
  for i in parts.len..<3:
    result.add(".0")

proc splitDepParts(s: string): seq[string] =
  ## Split a multi-dependency string on commas, ignoring commas that are
  ## inside `[feature]` brackets. e.g. `"a[f1, f2], b >= 1.0"` → 2 parts.
  var depth = 0
  var current = ""
  for c in s:
    case c
    of '[':
      inc depth
      current.add(c)
    of ']':
      if depth > 0: dec depth
      current.add(c)
    of ',':
      if depth == 0:
        result.add(current)
        current = ""
      else:
        current.add(c)
    else:
      current.add(c)
  if current.strip().len > 0:
    result.add(current)

proc parseFeaturesFrom(arg: var string): seq[string] =
  ## Strip a trailing `[f1, f2]` feature list and return it.
  arg = arg.strip()
  if arg.endsWith("]"):
    let bracketPos = arg.rfind('[')
    if bracketPos >= 0:
      for f in arg[bracketPos+1 .. ^2].split(','):
        let ff = f.strip()
        if ff.len > 0:
          result.add(ff)
      arg = arg[0 ..< bracketPos].strip()

proc parseRequiresArg*(arg: string): NimbleDependency =
  var arg = arg.strip()
  result.features = parseFeaturesFrom(arg)

  # URL deps: `https://...#ref`
  if arg.contains("://"):
    let hashPos = arg.find('#')
    if hashPos >= 0:
      result = NimbleDependency(
        url: arg[0..<hashPos], tag: arg[hashPos+1..^1], features: result.features)
    else:
      let parts = arg.splitWhitespace()
      if parts.len >= 3 and parts[1] in ["==", "=", ">=", ">", "<=", "<", "^", "~>"]:
        let op = if parts[1] == "==": "=" else: parts[1]
        result = NimbleDependency(
          url: parts[0],
          constraint: parseConstraint(op & normalizeVersion(parts[2])),
          features: result.features)
      else:
        result = NimbleDependency(url: arg, constraint:
          VersionConstraint(kind: vcAny, version: newVersion(0, 0, 0)),
          features: result.features)
    return

  # name[#ref] and optional `>= constraint`
  let parts = arg.splitWhitespace()
  var namePart = parts[0]
  var refStr = ""
  let hashPos = namePart.find('#')
  if hashPos >= 0:
    refStr = namePart[hashPos+1..^1].strip()
    namePart = namePart[0..<hashPos].strip()

  result = NimbleDependency(name: namePart, branch: refStr, features: result.features)
  if parts.len >= 3 and parts[1] in ["==", "=", ">=", ">", "<=", "<", "^", "~>"]:
    let op = if parts[1] == "==": "=" else: parts[1]
    result.constraint = parseConstraint(op & normalizeVersion(parts[2]))
  else:
    result.constraint = VersionConstraint(kind: vcAny, version: newVersion(0, 0, 0))
  result.isNim = result.name == "nim"

proc parseRequiresLine(deps: var seq[NimbleDependency], line: string) =
  ## Parse a `requires "a[f], b >= 1.0"` line into dependencies.
  let trimmed = line.strip()
  let quotePos = trimmed.find('"')
  if quotePos >= 0:
    let endPos = trimmed.rfind('"')
    if endPos > quotePos:
      for part in splitDepParts(trimmed[quotePos+1 ..< endPos]):
        deps.add(parseRequiresArg(part.strip()))

proc parseNimbleFileFallback(result: var NimbleFile, code: string) =
  ## Minimal line-based fallback for nimble files that sweetsyntax
  ## cannot parse (conditionals, exotic syntax, etc.). Also used as a
  ## fill-missing pass after sweetsyntax, so it only sets empty fields
  ## and only parses `requires` when none were captured yet.
  for line in code.splitLines():
    let trimmed = line.strip()
    if trimmed.len == 0 or trimmed.startsWith("#"): continue
    if trimmed.startsWith("requires"):
      if result.requires.len == 0:
        try:
          parseRequiresLine(result.requires, trimmed)
        except CatchableError:
          discard # malformed constraint — skip the dep, keep parsing
      continue
    let eq = trimmed.find('=')
    if eq <= 0: continue
    let key = trimmed[0..<eq].strip()
    let value = trimmed[eq+1..^1].strip()
    case key
    of "version", "author", "description", "license", "srcDir", "binDir":
      case key
      of "version":
        if result.version.len == 0: result.version = stripQuotes(value)
      of "author":
        if result.author.len == 0: result.author = stripQuotes(value)
      of "description":
        if result.description.len == 0: result.description = stripQuotes(value)
      of "license":
        if result.license.len == 0: result.license = stripQuotes(value)
      of "srcDir":
        if result.srcDir.len == 0: result.srcDir = stripQuotes(value)
      of "binDir":
        if result.binDir.len == 0: result.binDir = stripQuotes(value)
      else: discard
    of "bin", "installDirs", "installFiles", "installExt",
       "skipDirs", "skipFiles", "skipExt":
      var items: seq[string]
      let content = value.replace("@", "").strip()
      if content.startsWith("["):
        for part in splitDepParts(content[1 .. ^2]):
          items.add(stripQuotes(part.strip()))
      else:
        items.add(stripQuotes(content))
      case key
      of "bin": result.bin = items
      of "installDirs": result.installDirs = items
      of "installFiles": result.installFiles = items
      of "installExt": result.installExt = items
      of "skipDirs": result.skipDirs = items
      of "skipFiles": result.skipFiles = items
      of "skipExt": result.skipExt = items
      else: discard
    else: discard

proc parseFeatureBlocks(result: var NimbleFile, code: string) =
  ## Capture `feature "name":` blocks into `result.features` and the `dev:`
  ## block into `result.dev`.
  var currentFeature = ""
  var inDev = false
  for line in code.splitLines():
    if line.strip().len == 0 or line.strip().startsWith("#"): continue
    let indent = line.len - line.strip(leading = true).len
    let trimmed = line.strip()
    if indent == 0:
      if trimmed.startsWith("feature "):
        inDev = false
        let q1 = trimmed.find('"')
        let q2 = trimmed.rfind('"')
        if q1 >= 0 and q2 > q1:
          currentFeature = trimmed[q1+1 ..< q2]
          if not result.features.hasKey(currentFeature):
            result.features[currentFeature] = @[]
      elif trimmed.startsWith("dev:"):
        inDev = true
        currentFeature = ""
      else:
        inDev = false
        currentFeature = ""
    elif trimmed.startsWith("requires"):
      if inDev:
        try:
          parseRequiresLine(result.dev, trimmed)
        except CatchableError:
          discard # malformed constraint — skip the dep, keep parsing
      elif currentFeature.len > 0:
        try:
          parseRequiresLine(result.features[currentFeature], trimmed)
        except CatchableError:
          discard # malformed constraint — skip the dep, keep parsing

proc parseNimbleFileSweetsyntax(result: var NimbleFile, path: string, code: string) =
  let syntax = getKnownSyntax(KnownSyntax.nim)
  var p = compile(syntax.spec)
  p.lexer = initLexer(syntax.spec, code)
  nimHandlersMod.nimHandlers(p)
  p.stmtKeywords["requires"] = "requires_handler"
  stmtHandler p, "requires_handler":
    result = newNode(nkCall)
    result.children.add(Node(kind: nkIdent, name: "requires"))
    walk p
    if p.curr.kind == tkPunct and p.curr.value == ":":
      walk p
    while p.curr.kind == tkString:
      result.children.add(Node(kind: nkLitString, valStr: p.curr.value,
                               ln: p.curr.line, col: p.curr.col))
      walk p
  p.curr = p.getToken()
  p.next = p.getToken()
  var program = OpenAstProgram()
  while p.curr.kind != tkEOF:
    program.nodes.add(parseStatement(p))
  for node in program.nodes:
    case node.kind
    of nkInfix:
      if node.children.len == 3 and node.children[0].kind == nkIdent and node.children[0].name == "=":
        let keyNode = node.children[1]
        let valNode = node.children[2]
        if keyNode.kind != nkIdent: continue
        let key = keyNode.name
        case key
        of "version":
          if valNode.kind == nkLitString: result.version = stripQuotes(valNode.valStr)
        of "author":
          if valNode.kind == nkLitString: result.author = stripQuotes(valNode.valStr)
        of "description":
          if valNode.kind == nkLitString: result.description = stripQuotes(valNode.valStr)
        of "license":
          if valNode.kind == nkLitString: result.license = stripQuotes(valNode.valStr)
        of "srcDir":
          if valNode.kind == nkLitString: result.srcDir = stripQuotes(valNode.valStr)
        of "binDir":
          if valNode.kind == nkLitString: result.binDir = stripQuotes(valNode.valStr)
        of "bin", "installDirs", "installFiles", "installExt",
           "skipDirs", "skipFiles", "skipExt":
          var items: seq[string]
          proc extractArrayElems(n: Node, items: var seq[string]) =
            case n.kind
            of nkBracketExpr:
              for child in n.children:
                if child.kind == nkLitString:
                  items.add(stripQuotes(child.valStr))
            of nkPrefix:
              if n.children.len >= 2 and n.children[0].kind == nkIdent and n.children[0].name == "@":
                extractArrayElems(n.children[1], items)
            of nkBlock:
              for child in n.children:
                extractArrayElems(child, items)
            else: discard
          extractArrayElems(valNode, items)
          case key
          of "bin": result.bin = items
          of "installDirs": result.installDirs = items
          of "installFiles": result.installFiles = items
          of "installExt": result.installExt = items
          of "skipDirs": result.skipDirs = items
          of "skipFiles": result.skipFiles = items
          of "skipExt": result.skipExt = items
          else: discard
        else: discard
    of nkCall:
      if node.children.len >= 2 and node.children[0].kind == nkIdent and node.children[0].name == "requires":
        for i in 1..<node.children.len:
          if node.children[i].kind == nkLitString:
            result.requires.add(parseRequiresArg(stripQuotes(node.children[i].valStr)))
    else: discard

proc parseNimbleString*(code: string): NimbleFile =
  ## Parse nimble file contents directly (no filesystem read) — used for fast
  ## `git show <tag>:<nimble>` dependency parsing.
  result = NimbleFile(path: "")
  try:
    parseNimbleFileSweetsyntax(result, "", code)
  except CatchableError:
    result = NimbleFile(path: "")
  # always run the fill-missing pass: sweetsyntax can skip fields like
  # `srcDir` (tokenized as a non-identifier), so capture any that are empty.
  parseNimbleFileFallback(result, code)
  # feature blocks are independent of sweetsyntax's AST handling
  parseFeatureBlocks(result, code)

proc parseNimbleFile*(path: string): NimbleFile =
  result = parseNimbleString(readFile(path))
  result.path = path

proc findNimbleFile*(dir: string): string =
  ## Locate a .nimble file in the given directory.
  for f in walkFiles(dir / "*.nimble"):
    if f.extractFilename != "nim.nimble":
      return f
  ""
