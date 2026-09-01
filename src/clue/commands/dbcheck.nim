# Clue - REPL for boogie databases (readonly SQL)
#
# (c) 2026 George Lemon | MIT License
#          Made by Humans from OpenPeeps
#          https://github.com/openpeeps/clue

import std/[os, strutils, terminal, options, json]

import pkg/kapsis/[runtime, interactive/prompts]
import pkg/openparser/sql
import pkg/boogie/stores/rdbms
import pkg/boogie/sqlengine

import ../pkgmanager/configs

type
  ActiveDb = enum
    adbClue, adbVersions

  DbCtx = object
    store: Store
    eng: SqlEngine
    label: string
    path: string

proc dbPathLabel(a: ActiveDb): string =
  case a
  of adbClue: "clue.db"
  of adbVersions: "versions.db"

proc initDbCtx(a: ActiveDb): DbCtx =
  initClue()
  case a
  of adbClue:
    let s = getClueCfg().stores.db
    result = DbCtx(store: s, eng: newSqlEngine(s), label: "clue.db", path: getClueCfg().dbPath())
  of adbVersions:
    let s = getClueCfg().stores.versionsDB
    result = DbCtx(store: s, eng: newSqlEngine(s), label: "versions.db", path: getClueCfg().versionsDBPath())

proc isReadOnlySql(sql: string): tuple[ok: bool, err: string] =
  ## Only SELECT / SELECT DISTINCT (and stmts list of them) is allowed.
  if sql.strip.len == 0:
    return (false, "empty query")
  var root: SqlNode
  try:
    root = parseSql(sql)
  except SqlParseError as e:
    return (false, e.msg)
  except CatchableError as e:
    return (false, e.msg)
  var stmts: seq[SqlNode]
  if root.kind == nkStmtList:
    stmts = root.sons
  else:
    stmts = @[root]
  if stmts.len == 0:
    return (false, "empty query")
  for s in stmts:
    if s.kind notin {nkSelect, nkSelectDistinct}:
      return (false, "read-only: only SELECT is allowed (got " & $s.kind & ")")
  (true, "")

proc extractLimitOffset(sql: string): tuple[limit: int64, offset: int64] =
  ## Best-effort extraction of LIMIT/OFFSET from parsed SQL for client-side
  ## fallback trimming (engine bug workaround for unordered LIMIT).
  result = (-1'i64, 0'i64)
  var root: SqlNode
  try:
    root = parseSql(sql)
  except CatchableError:
    return
  var stmts: seq[SqlNode]
  if root.kind == nkStmtList: stmts = root.sons else: stmts = @[root]
  if stmts.len == 0: return
  let s = stmts[^1]
  if s.kind notin {nkSelect, nkSelectDistinct}: return
  for child in s.sons:
    case child.kind
    of nkLimit:
      if child.len > 0:
        try: result.limit = child[0].strVal.parseBiggestInt
        except: discard
      if child.len > 1:
        try: result.offset = child[1].strVal.parseBiggestInt
        except: discard
    of nkOffset:
      if child.len > 0:
        try: result.offset = child[0].strVal.parseBiggestInt
        except: discard
    else: discard

proc applyLimitFallback(columns: seq[string], rows: seq[seq[string]], sql: string): tuple[cols: seq[string], r: seq[seq[string]]] =
  # Workaround for boogie 0.2.0 unordered LIMIT bug: engine sometimes returns
  # all rows ignoring LIMIT. Offset handling in engine is correct, so only
  # clamp LIMIT here. Do not re-apply OFFSET (would double-trim when engine
  # already handled it).
  let (lim, _) = extractLimitOffset(sql)
  var rr = rows
  if lim >= 0 and rr.len > lim:
    rr = rr[0 ..< int(lim)]
  (columns, rr)

proc listTables(ctx: DbCtx): seq[string] =
  # Store.tables is private; infer via known schema + any dynamic tables
  # Use store API: try known tables first, then probe via engine's store.hasTable?
  # Fallback: enumerate via known names
  const knownClue = ["packages", "installed"]
  const knownVersions = ["versions", "deps"]
  let candidates: seq[string] =
    case ctx.label
    of "clue.db": @knownClue
    of "versions.db": @knownVersions
    else: @[]
  for n in candidates:
    if ctx.store.hasTable(n):
      result.add(n)
  # also discover any extra tables by probing hasTable for all tables in store
  # Since we don't have enumeration, we just return known + any that exec reveals
  # Try to query sqlite_master style fallback: attempt to list via store object inspection
  # If still empty, report none
  discard

proc renderTable(columns: seq[string], rows: seq[seq[string]]) =
  if rows.len == 0:
    displayInfo("0 rows")
    return
  for idx, r in rows:
    for i, col in columns:
      let cell = if i < r.len: r[i] else: ""
      echo col & ": " & cell
    if idx < rows.len - 1:
      echo "-------"

proc renderJson(columns: seq[string], rows: seq[seq[string]]) =
  var arr = newJArray()
  for r in rows:
    var obj = newJObject()
    for i, c in columns:
      let v = if i < r.len: r[i] else: ""
      obj[c] = newJString(v)
    arr.add(obj)
  echo pretty(%*{"columns": %columns, "rows": arr, "count": rows.len})

proc renderDotHelp() =
  echo ""
  echo "Dot commands:"
  echo "  .help              Show this help"
  echo "  .tables            List tables"
  echo "  .schema [table]    Show CREATE TABLE / columns"
  echo "  .databases         Show attached databases"
  echo "  .quit  .exit       Leave REPL"
  echo ""
  echo "SQL: read-only SELECT only. End statements with ;"
  echo "  SELECT * FROM packages LIMIT 5;"
  echo "  SELECT name, url FROM packages WHERE name='semver';"
  echo ""

proc renderDatabases(clueCtx, versionsCtx: DbCtx, active: ActiveDb) =
  echo ""
  let cur = dbPathLabel(active)
  echo "Attached databases:"
  for ctx in [clueCtx, versionsCtx]:
    let marker = if ctx.label == cur: " * " else: "   "
    let exists = if fileExists(ctx.path): "" else: " (not found)"
    echo marker & ctx.label & "  ->  " & ctx.path & exists
  echo ""

proc renderSchema(ctx: DbCtx, tableName: string) =
  if tableName.len == 0:
    # list all
    for t in listTables(ctx):
      renderSchema(ctx, t)
    return
  let tOpt = ctx.store.getTable(tableName)
  if tOpt.isNone:
    displayError("no such table: " & tableName)
    return
  let t = tOpt.get()
  echo ""
  echo "Table: " & t.name & " (PK: " & t.primaryKey & ")"
  echo "Columns:"
  for c in t.columns:
    let nn = if not c.nullable: " NOT NULL" else: ""
    let def = if c.defaultValue.len > 0: " DEFAULT " & c.defaultValue else: ""
    echo "  " & c.name & "  " & $c.kind & nn & def
  # row count
  var cnt = 0
  for _ in t.allRows(): inc cnt
  echo "Rows: " & $cnt
  echo ""

proc execAndRender(ctx: DbCtx, sql: string, asJson: bool) =
  let check = isReadOnlySql(sql)
  if not check.ok:
    displayError(check.err)
    return
  try:
    let res = ctx.eng.execSql(sql)
    let (cols, rr) = applyLimitFallback(res.columns, res.rows, sql)
    if asJson:
      renderJson(cols, rr)
    else:
      renderTable(cols, rr)
  except SqlEngineError as e:
    displayError(e.msg)
  except SqlParseError as e:
    displayError(e.msg)
  except CatchableError as e:
    displayError(e.msg)

proc repl(active: ActiveDb, asJson: bool) =
  let clueCtx = initDbCtx(adbClue)
  let versionsCtx = initDbCtx(adbVersions)
  var curActive = active
  proc curCtx(): DbCtx =
    if curActive == adbClue: clueCtx else: versionsCtx

  if not fileExists(curCtx().path):
    displayWarning(curCtx().label & " not found at " & curCtx().path & " — tables will be empty")

  echo ""
  echo "clue dbcheck — read-only SQL REPL (boogie/openparser/sql)"
  echo "  DB: " & curCtx().label & "  " & curCtx().path
  echo "  Type .help for dot-commands, .quit to exit. Only SELECT is allowed."
  echo ""

  var buffer = ""
  while true:
    let promptStr =
      if buffer.len == 0: "clue:" & curCtx().label & "> "
      else: "   ...> "
    stdout.write(promptStr)
    stdout.flushFile()
    var line: string
    try:
      if not stdin.readLine(line):
        echo ""
        break
    except EOFError:
      echo ""
      break
    let trimmed = line.strip()
    if buffer.len == 0 and trimmed.len == 0:
      continue
    # dot-commands only when buffer empty and line starts with .
    if buffer.len == 0 and trimmed.startsWith("."):
      let parts = trimmed.splitWhitespace()
      let cmd = parts[0].toLowerAscii()
      case cmd
      of ".help", ".h":
        renderDotHelp()
      of ".tables":
        let tables = curCtx().listTables()
        if tables.len == 0:
          displayInfo("no tables")
        else:
          for t in tables:
            echo "  " & t
      of ".schema":
        let arg = if parts.len > 1: parts[1] else: ""
        renderSchema(curCtx(), arg)
      of ".databases", ".dbs", ".db":
        renderDatabases(clueCtx, versionsCtx, curActive)
      of ".quit", ".exit", ".q":
        break
      of ".use":
        if parts.len < 2:
          displayError("usage: .use <clue|versions>")
        else:
          let target = parts[1].toLowerAscii()
          if target in ["clue", "clue.db"]:
            curActive = adbClue
            echo "Switched to clue.db (" & clueCtx.path & ")"
          elif target in ["versions", "versions.db"]:
            curActive = adbVersions
            echo "Switched to versions.db (" & versionsCtx.path & ")"
          else:
            displayError("unknown database: " & parts[1] & " (use clue or versions)")
      else:
        displayError("unknown dot-command: " & cmd & " — try .help")
      continue

    # accumulate SQL
    if buffer.len > 0:
      buffer.add(" " & line)
    else:
      buffer = line

    # execute when ends with ;
    if buffer.strip.endsWith(";"):
      let sql = buffer
      buffer = ""
      # skip empty
      if sql.strip == ";":
        continue
      execAndRender(curCtx(), sql, asJson)
    else:
      # also allow executing on empty line? no — keep buffering
      # If buffer contains a dot-command-like but we already handled, continue
      discard
    # if buffer without ; and user pressed enter twice? keep buffering until ;
    # Provide hint if buffer long and no ;
    if buffer.len > 0 and buffer.len > 4096 and not buffer.contains(";"):
      discard

proc oneShot(active: ActiveDb, sql: string, asJson: bool) =
  let ctx = initDbCtx(active)
  if not fileExists(ctx.path):
    displayWarning(ctx.label & " not found at " & ctx.path)
  let check = isReadOnlySql(sql)
  if not check.ok:
    displayError(check.err, quitProcess = true)
  try:
    let res = ctx.eng.execSql(sql)
    let (cols, rr) = applyLimitFallback(res.columns, res.rows, sql)
    if asJson:
      renderJson(cols, rr)
    else:
      renderTable(cols, rr)
  except SqlEngineError as e:
    displayError(e.msg, quitProcess = true)
  except SqlParseError as e:
    displayError(e.msg, quitProcess = true)
  except CatchableError as e:
    displayError(e.msg, quitProcess = true)

proc collectQuery(v: Values): string =
  # Prefer raw command line tail to preserve single quotes.
  # kapsis splits on inner quotes, so Values.get("query") is often truncated.
  let raw = commandLineParams()
  var tail: seq[string] = @[]
  var seenDb = false
  var seenVersionsSub = false
  for p in raw:
    if not seenDb:
      if p == "dbcheck" or p == "dbcheck.versions":
        seenDb = true
        continue
      # handle `clue dbcheck versions ...` split form
      if p == "dbcheck":
        seenDb = true
        continue
      continue
    # after dbcheck, handle optional `versions` subcommand token
    if not seenVersionsSub and p == "versions":
      seenVersionsSub = true
      continue
    if p == "--json" or p.startsWith("--json"):
      continue
    tail.add(p)
  if tail.len > 0:
    return tail.join(" ").strip()
  # fallback to Values
  var parts: seq[string] = @[]
  if v.has("query"):
    let q = v.get("query").getStr
    if q.strip.len > 0:
      parts.add(q)
  if extras.len > 0:
    parts.add(extras.join(" "))
  if parts.len > 0:
    return parts.join(" ").strip()
  ""

proc dbcheckCommand*(v: Values) =
  let asJson = v.has("--json")
  let q = collectQuery(v)
  if q.len > 0:
    oneShot(adbClue, q, asJson)
    return
  repl(adbClue, asJson)

proc dbcheckVersionsCommand*(v: Values) =
  let asJson = v.has("--json")
  let q = collectQuery(v)
  if q.len > 0:
    oneShot(adbVersions, q, asJson)
    return
  repl(adbVersions, asJson)
