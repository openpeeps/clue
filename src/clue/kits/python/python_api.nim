# Clue - A cool toolkit for Nim developers
#
# (c) 2026 George Lemon | MIT License
#          Made by Humans from OpenPeeps
#          https://github.com/openpeeps/clue

## Low-level Nim bindings to the Python C API (`Python.h`).
##
## This module provides direct C-style bindings for creating Python native
## extensions in Nim. Real C functions are imported via `{.importc, header}`
## pragmas. C macros are provided as Nim templates with identical names.

{.passC: "-I/opt/local/Library/Frameworks/Python.framework/Versions/3.11/include/python3.11 -I/opt/local/Library/Frameworks/Python.framework/Versions/3.11/include/python3.11".}
{.passL: "-L/opt/local/Library/Frameworks/Python.framework/Versions/3.11/lib/python3.11/config-3.11-darwin -lpython3.11 -ldl -framework CoreFoundation -Wl,-undefined,dynamic_lookup".}

type
  PyObject* {.importc: "PyObject", header: "Python.h", incompleteStruct.} = object
  PyCFunction* = proc(self: ptr PyObject, args: ptr PyObject): ptr PyObject {.cdecl.}

type
  Py_ssize_t* = clong

type
  PyMethodDef* {.importc: "PyMethodDef", header: "Python.h", bycopy.} = object
    ml_name*: cstring
    ml_meth*: PyCFunction
    ml_flags*: cint
    ml_doc*: cstring

type
  PyModuleDef_Base* {.importc: "PyModuleDef_Base", header: "Python.h", bycopy.} = object
    discard

type
  PyModuleDef_Slot* {.importc: "PyModuleDef_Slot", header: "Python.h", bycopy.} = object
    slot*: cint
    value*: pointer

type
  traverseproc* = pointer
  inquiry* = pointer
  freefunc* = pointer

type
  PyModuleDef* {.importc: "PyModuleDef", header: "Python.h", bycopy.} = object
    m_base*: PyModuleDef_Base
    m_name*: cstring
    m_doc*: cstring
    m_size*: Py_ssize_t
    m_methods*: ptr PyMethodDef
    m_slots*: ptr PyModuleDef_Slot
    m_traverse*: traverseproc
    m_clear*: inquiry
    m_free*: freefunc

const
  PYTHON_API_VERSION* = 1013

const
  METH_VARARGS* = 0x0001
  METH_KEYWORDS* = 0x0002
  METH_NOARGS* = 0x0004
  METH_O* = 0x0008

proc Py_IncRef*(obj: ptr PyObject) {.importc, header: "Python.h".}
proc Py_DecRef*(obj: ptr PyObject) {.importc, header: "Python.h".}

proc PyLong_FromLong*(val: clong): ptr PyObject {.importc, header: "Python.h".}
proc PyLong_FromLongLong*(val: clonglong): ptr PyObject {.importc, header: "Python.h".}
proc PyFloat_FromDouble*(val: cdouble): ptr PyObject {.importc, header: "Python.h".}
proc PyBool_FromLong*(val: clong): ptr PyObject {.importc, header: "Python.h".}
proc PyUnicode_FromString*(str: cstring): ptr PyObject {.importc, header: "Python.h".}
proc PyUnicode_FromStringAndSize*(str: cstring, size: Py_ssize_t): ptr PyObject {.importc, header: "Python.h".}
proc PyBytes_FromString*(str: cstring): ptr PyObject {.importc, header: "Python.h".}
proc PyBytes_FromStringAndSize*(str: cstring, size: Py_ssize_t): ptr PyObject {.importc, header: "Python.h".}
proc PyList_New*(size: Py_ssize_t): ptr PyObject {.importc, header: "Python.h".}
proc PyList_SetItem*(list: ptr PyObject, idx: Py_ssize_t, item: ptr PyObject): cint {.importc, header: "Python.h".}
proc PyList_Append*(list: ptr PyObject, item: ptr PyObject): cint {.importc, header: "Python.h".}
proc PyDict_New*(): ptr PyObject {.importc, header: "Python.h".}
proc PyDict_SetItemString*(dict: ptr PyObject, key: cstring, val: ptr PyObject): cint {.importc, header: "Python.h".}
proc PyTuple_New*(size: Py_ssize_t): ptr PyObject {.importc, header: "Python.h".}
proc PyTuple_SetItem*(`tuple`: ptr PyObject, idx: Py_ssize_t, item: ptr PyObject): cint {.importc, header: "Python.h".}

proc PyArg_ParseTuple*(args: ptr PyObject, format: cstring): cint {.importc, header: "Python.h", varargs.}
proc PyArg_ParseTupleAndKeywords*(args: ptr PyObject, kwargs: ptr PyObject, format: cstring, keywords: ptr cstring): cint {.importc, header: "Python.h", varargs.}
proc Py_BuildValue*(format: cstring): ptr PyObject {.importc, header: "Python.h", varargs.}

proc PyModule_New*(name: cstring): ptr PyObject {.importc, header: "Python.h".}
proc PyModule_Create2*(def: ptr PyModuleDef, apiver: cint): ptr PyObject {.importc, header: "Python.h".}
proc PyModule_AddFunctions*(`mod`: ptr PyObject, methods: ptr PyMethodDef): cint {.importc, header: "Python.h".}
proc PyModule_AddObject*(`mod`: ptr PyObject, name: cstring, value: ptr PyObject): cint {.importc, header: "Python.h".}
proc PyModule_AddIntConstant*(`mod`: ptr PyObject, name: cstring, value: clong): cint {.importc, header: "Python.h".}
proc PyModule_AddStringConstant*(`mod`: ptr PyObject, name: cstring, value: cstring): cint {.importc, header: "Python.h".}
proc PyModule_AddType*(`mod`: ptr PyObject, `typ`: pointer): cint {.importc, header: "Python.h".}
proc PyModuleDef_Init*(def: ptr PyModuleDef): ptr PyObject {.importc, header: "Python.h".}

proc PyErr_SetString*(exc: ptr PyObject, msg: cstring) {.importc, header: "Python.h".}
proc PyErr_Format*(exc: ptr PyObject, fmt: cstring): ptr PyObject {.importc, header: "Python.h", varargs.}
proc PyErr_Occurred*(): ptr PyObject {.importc, header: "Python.h".}

var PyExc_RuntimeError* {.importc: "PyExc_RuntimeError", header: "Python.h".}: ptr PyObject
var PyExc_TypeError* {.importc: "PyExc_TypeError", header: "Python.h".}: ptr PyObject
var PyExc_ValueError* {.importc: "PyExc_ValueError", header: "Python.h".}: ptr PyObject

proc PyObject_Str*(obj: ptr PyObject): ptr PyObject {.importc, header: "Python.h".}
proc PyObject_Repr*(obj: ptr PyObject): ptr PyObject {.importc, header: "Python.h".}
proc PyObject_GetAttrString*(obj: ptr PyObject, name: cstring): ptr PyObject {.importc, header: "Python.h".}
proc PyObject_SetAttrString*(obj: ptr PyObject, name: cstring, value: ptr PyObject): cint {.importc, header: "Python.h".}
proc PyObject_Type*(obj: ptr PyObject): ptr PyObject {.importc, header: "Python.h".}
proc PyObject_IsInstance*(obj: ptr PyObject, typ: ptr PyObject): cint {.importc, header: "Python.h".}
proc PyObject_IsSubclass*(derived: ptr PyObject, parent: ptr PyObject): cint {.importc, header: "Python.h".}
proc PyObject_Not*(obj: ptr PyObject): cint {.importc, header: "Python.h".}
proc PyObject_IsTrue*(obj: ptr PyObject): cint {.importc, header: "Python.h".}
proc PyObject_Length*(obj: ptr PyObject): Py_ssize_t {.importc, header: "Python.h".}
proc PyObject_Hash*(obj: ptr PyObject): Py_ssize_t {.importc, header: "Python.h".}

proc PyLong_AsLong*(obj: ptr PyObject): clong {.importc, header: "Python.h".}
proc PyLong_AsLongLong*(obj: ptr PyObject): clonglong {.importc, header: "Python.h".}
proc PyFloat_AsDouble*(obj: ptr PyObject): cdouble {.importc, header: "Python.h".}
proc PyUnicode_AsUTF8*(obj: ptr PyObject): cstring {.importc, header: "Python.h".}
proc PyUnicode_AsUTF8String*(obj: ptr PyObject): ptr PyObject {.importc, header: "Python.h".}

proc getPyNone*(): ptr PyObject =
  {.emit: "`result` = Py_None;".}

proc getPyTrue*(): ptr PyObject =
  {.emit: "`result` = Py_True;".}

proc getPyFalse*(): ptr PyObject =
  {.emit: "`result` = Py_False;".}

template Py_None*(): ptr PyObject = getPyNone()
template Py_True*(): ptr PyObject = getPyTrue()
template Py_False*(): ptr PyObject = getPyFalse()

template Py_NewRef*(obj: ptr PyObject): ptr PyObject =
  Py_IncRef(obj)
  obj

template Py_RETURN_NONE* =
  return Py_NewRef(getPyNone())

template Py_RETURN_TRUE* =
  return Py_NewRef(getPyTrue())

template Py_RETURN_FALSE* =
  return Py_NewRef(getPyFalse())

template PyModule_Create*(def: ptr PyModuleDef): ptr PyObject =
  PyModule_Create2(def, PYTHON_API_VERSION)

proc toPyString*(s: string): ptr PyObject =
  PyUnicode_FromString(cstring(s))

proc toPyInt*(n: int): ptr PyObject =
  PyLong_FromLong(clong(n))

proc toPyFloat*(n: float): ptr PyObject =
  PyFloat_FromDouble(cdouble(n))

proc toPyBool*(b: bool): ptr PyObject =
  PyBool_FromLong(clong(b))

proc toPyList*(): ptr PyObject =
  PyList_New(0)

proc toPyDict*(): ptr PyObject =
  PyDict_New()

proc toPyNone*(): ptr PyObject =
  Py_NewRef(getPyNone())
