import std/math
import ../../src/clue/clib_export

{.pragma: clue_export, exportc, cdecl.}

type
  Vector* {.clue_export, bycopy.} = object

proc vec_add*(a, b, res: ptr Vector): void {.clue_export, dynlib.} =
  discard

genCHeader(Vector, vec_add)
