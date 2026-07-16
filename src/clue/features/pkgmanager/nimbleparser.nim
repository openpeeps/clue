# Clue - A cool toolkit for Nim developers
#
# (c) 2026 George Lemon | LGPLv3 License
#          Made by Humans from OpenPeeps
#          https://github.com/openpeeps/clue

import std/[tables, strutils]
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

proc parseRequiresArg(arg: string): NimbleDependency =
  if arg.contains("://"):
    let hashPos = arg.find('#')
    if hashPos >= 0:
      result = NimbleDependency(
        url: arg[0..<hashPos], tag: arg[hashPos+1..^1])
    else:
      let parts = arg.splitWhitespace()
      if parts.len >= 3 and parts[1] in ["==", ">=", ">", "<=", "<", "^", "~>"]:
        let op = if parts[1] == "==": "=" else: parts[1]
        result = NimbleDependency(
          url: parts[0],
          constraint: parseConstraint(op & normalizeVersion(parts[2])))
      else:
        result = NimbleDependency(url: arg)
    return
  let hashPos = arg.find('#')
  if hashPos >= 0:
    let name = arg[0..<hashPos].strip()
    let refStr = arg[hashPos+1..^1].strip()
    result = NimbleDependency(name: name, branch: refStr)
    return
  let parts = arg.splitWhitespace()
  result = NimbleDependency(name: parts[0])
  if parts.len >= 3 and parts[1] in ["==", ">=", ">", "<=", "<", "^", "~>"]:
    let op = if parts[1] == "==": "=" else: parts[1]
    result.constraint = parseConstraint(op & normalizeVersion(parts[2]))
  else:
    result.constraint = VersionConstraint(kind: vcAny, version: newVersion(0, 0, 0))
  result.isNim = result.name == "nim"

proc parseNimbleFile*(path: string): NimbleFile =
  result = NimbleFile(path: path)
  let code = readFile(path)
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
        of "bin", "installDirs", "installFiles", "installExt":
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
          else: discard
        else: discard
    of nkCall:
      if node.children.len >= 2 and node.children[0].kind == nkIdent and node.children[0].name == "requires":
        for i in 1..<node.children.len:
          if node.children[i].kind == nkLitString:
            result.requires.add(parseRequiresArg(stripQuotes(node.children[i].valStr)))
    else: discard
