import std/math
import ../../src/clue/wrapper

type Vector* {.exportc, bycopy.} = object
  x*, y*, z*: cdouble

type MathOp* {.exportc.} = enum
  opAdd, opSub, opMul, opDiv

proc vec_add*(a, b, res: ptr Vector): void {.exportc, cdecl, dynlib.} =
  ## Add two vectors, store result in `res`
  res.x = a.x + b.x
  res.y = a.y + b.y
  res.z = a.z + b.z

proc vec_length*(v: ptr Vector): cdouble {.exportc, cdecl, dynlib.} =
  ## Compute the length (magnitude) of a vector
  sqrt(v.x * v.x + v.y * v.y + v.z * v.z)

proc vec_scale*(v: ptr Vector, factor: cdouble): void {.exportc, cdecl, dynlib.} =
  ## Scale a vector in-place by a factor
  v.x = v.x * factor
  v.y = v.y * factor
  v.z = v.z * factor

proc vec_dot*(a, b: ptr Vector): cdouble {.exportc, cdecl, dynlib.} =
  ## Compute the dot product of two vectors
  a.x * b.x + a.y * b.y + a.z * b.z

genCHeader(Vector, MathOp, vec_add, vec_length, vec_scale, vec_dot)
genGoHeader(Vector, MathOp, vec_add, vec_length, vec_scale, vec_dot)
genRustHeader(Vector, MathOp, vec_add, vec_length, vec_scale, vec_dot)
genCrystalHeader(Vector, MathOp, vec_add, vec_length, vec_scale, vec_dot)
