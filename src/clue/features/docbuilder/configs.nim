import std/[os, options]

import pkg/boogie/stores/rdbms
import pkg/kapsis/interactive/prompts

export rdbms

const
  clueBasePath* = getHomeDir() / ".clue"
  clueDocsPath* = clueBasePath / "docs"
  clueDocsDBPath* = clueBasePath / "docs.db"

var clueDocsDB*: Store

proc getDocsTable*(): DbTable =
  clueDocsDB.getTable("docs").get()

proc initDocsDB*() =
  discard existsOrCreateDir(clueBasePath)
  discard existsOrCreateDir(clueDocsPath)
  var hasDatabase = fileExists(clueDocsDBPath)
  clueDocsDB = newStore(clueDocsDBPath, StorageMode.smDisk,
                    enableWal = true, walFlushEveryOps = 100'u32)
  if not hasDatabase:
    displayInfo("Initializing Clue docs database...")
    clueDocsDB.createTable(newTable(
      name = "docs",
      primaryKey = "id",
      columns = [
        newColumn("id", dtInt, false),
        newColumn("name", dtText, false),
        newColumn("version", dtText, false),
        newColumn("description", dtText, false),
        newColumn("built_at", dtText, false),
        newColumn("path", dtText, false),
        newColumn("mainfile", dtText, false),
      ]
    ))
    clueDocsDB.checkpoint()

template withDocsDB*(stmt) =
  initDocsDB()
  stmt
