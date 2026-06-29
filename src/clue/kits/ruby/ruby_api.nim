# Clue - A cool toolkit for Nim developers
#
# (c) 2026 George Lemon | MIT License
#          Made by Humans from OpenPeeps
#          https://github.com/openpeeps/clue

## Low-level Nim bindings to the Ruby C API (`ruby.h`).
##
## This module provides direct C-style bindings for creating Ruby native extensions
## in Nim. Real C functions are imported via `{.importc, header: "ruby.h".}`.
## C macros (like `INT2FIX`, `RSTRING_LEN`) are provided as Nim templates
## with identical names.
##
## Usage
## =====
## ```nim
## import clue/kits/ruby/ruby_api
##
## proc hello_world(self: VALUE): VALUE {.cdecl.} =
##   rb_p(rb_str_new_cstr("Hello from Nim!"))
##   return Qnil
## ```

{.passC: "-I/opt/local/include/ruby-3.0.0 -I/opt/local/include/ruby-3.0.0/x86_64-darwin23".}
{.passL: "-L/opt/local/lib -lruby.3.0 -Wl,-undefined,dynamic_lookup".}

type
  VALUE* = culong
  ID* = culong

const
  Qfalse* = VALUE(0x00)
  Qnil*   = VALUE(0x08)
  Qtrue*  = VALUE(0x14)
  Qundef* = VALUE(0x34)
  FIXNUM_FLAG* = 0x01

const
  T_NONE*    = 0x00
  T_OBJECT*  = 0x01
  T_CLASS*   = 0x02
  T_MODULE*  = 0x03
  T_FLOAT*   = 0x04
  T_STRING*  = 0x05
  T_REGEXP*  = 0x06
  T_ARRAY*   = 0x07
  T_HASH*    = 0x08
  T_STRUCT*  = 0x09
  T_BIGNUM*  = 0x0a
  T_FILE*    = 0x0b
  T_DATA*    = 0x0c
  T_MATCH*   = 0x0d
  T_COMPLEX*  = 0x0e
  T_RATIONAL* = 0x0f
  T_NIL*     = 0x11
  T_TRUE*    = 0x12
  T_FALSE*   = 0x13
  T_SYMBOL*  = 0x14
  T_FIXNUM*  = 0x15
  T_UNDEF*   = 0x16
  T_MASK*    = 0x1f

template INT2FIX*(i: cint): VALUE =
  VALUE((culong(i) shl 1) or VALUE(FIXNUM_FLAG))

template FIX2INT*(x: VALUE): cint =
  cint(clong(x) shr 1)

template FIX2LONG*(x: VALUE): clong =
  clong(x) shr 1

template INT2NUM*(v: cint): VALUE =
  rb_int2num_inline(v)

template LONG2NUM*(v: clong): VALUE =
  rb_long2num_inline(v)

template NUM2INT*(x: VALUE): cint =
  cint(rb_num2int_inline(x))

template NUM2LONG*(x: VALUE): clong =
  rb_num2long_inline(x)

template NUM2DBL*(x: VALUE): cdouble =
  rb_num2dbl(x)

template RB_TYPE_P*(obj: VALUE, typ: cint): bool =
  rb_type(obj) == typ

template RTEST*(v: VALUE): bool =
  (v and not Qnil) != 0

template NIL_P*(v: VALUE): bool =
  v == Qnil

template FIXNUM_P*(v: VALUE): bool =
  (v and VALUE(FIXNUM_FLAG)) != 0

template RB_FIXNUM_P*(v: VALUE): bool =
  FIXNUM_P(v)

proc rb_integer_type_p*(obj: VALUE): bool {.importc, header: "ruby.h".}

template rb_ary_len*(ary: VALUE): clong =
  rb_array_len(ary)

template rb_str_len*(str: VALUE): clong =
  rb_str_len_inline(str)

template rb_ary_entry*(ary: VALUE, idx: clong): VALUE =
  rb_ary_entry_internal(ary, idx)

# Module / Class
proc rb_define_module*(name: cstring): VALUE {.importc: "rb_define_module", header: "ruby.h".}
proc rb_define_class*(name: cstring, superclass: VALUE): VALUE {.importc: "rb_define_class", header: "ruby.h".}
proc rb_define_module_under*(outer: VALUE, name: cstring): VALUE {.importc: "rb_define_module_under", header: "ruby.h".}
proc rb_define_class_under*(outer: VALUE, name: cstring, superclass: VALUE): VALUE {.importc: "rb_define_class_under", header: "ruby.h".}
proc rb_include_module*(klass: VALUE, `mod`: VALUE) {.importc: "rb_include_module", header: "ruby.h".}
proc rb_extend_object*(obj: VALUE, `mod`: VALUE) {.importc: "rb_extend_object", header: "ruby.h".}
proc rb_prepend_module*(klass: VALUE, `mod`: VALUE) {.importc: "rb_prepend_module", header: "ruby.h".}

# Method definition
proc rb_define_method*(klass: VALUE, name: cstring, `func`: pointer, argc: cint) {.importc, header: "ruby.h".}
proc rb_define_module_function*(`mod`: VALUE, name: cstring, `func`: pointer, argc: cint) {.importc: "rb_define_module_function", header: "ruby.h".}
proc rb_define_singleton_method*(klass: VALUE, name: cstring, `func`: pointer, argc: cint) {.importc, header: "ruby.h".}
proc rb_define_global_function*(name: cstring, `func`: pointer, argc: cint) {.importc, header: "ruby.h".}
proc rb_define_protected_method*(klass: VALUE, name: cstring, `func`: pointer, argc: cint) {.importc, header: "ruby.h".}
proc rb_define_private_method*(klass: VALUE, name: cstring, `func`: pointer, argc: cint) {.importc, header: "ruby.h".}
proc rb_define_attr*(klass: VALUE, name: cstring, read: cint, write: cint) {.importc, header: "ruby.h".}
proc rb_define_alias*(klass: VALUE, newName: cstring, oldName: cstring) {.importc, header: "ruby.h".}
proc rb_undef_method*(klass: VALUE, name: cstring) {.importc, header: "ruby.h".}

# Constants / variables
proc rb_define_const*(klass: VALUE, name: cstring, val: VALUE) {.importc, header: "ruby.h".}
proc rb_const_set*(klass: VALUE, id: ID, val: VALUE) {.importc, header: "ruby.h".}
proc rb_const_get*(klass: VALUE, id: ID): VALUE {.importc, header: "ruby.h".}
proc rb_cv_set*(klass: VALUE, name: cstring, val: VALUE) {.importc, header: "ruby.h".}
proc rb_cv_get*(klass: VALUE, name: cstring): VALUE {.importc, header: "ruby.h".}
proc rb_define_class_variable*(klass: VALUE, name: cstring, val: VALUE) {.importc, header: "ruby.h".}
proc rb_ivar_set*(obj: VALUE, id: ID, val: VALUE): VALUE {.importc, header: "ruby.h".}
proc rb_ivar_get*(obj: VALUE, id: ID): VALUE {.importc, header: "ruby.h".}
proc rb_ivar_defined*(obj: VALUE, id: ID): VALUE {.importc, header: "ruby.h".}

# Strings
proc rb_str_new*(`ptr`: cstring, len: clong): VALUE {.importc, header: "ruby.h".}
proc rb_str_new_cstr*(str: cstring): VALUE {.importc, header: "ruby.h".}
proc rb_str_new_static*(`ptr`: cstring, len: clong): VALUE {.importc, header: "ruby.h".}
proc rb_str_new_shared*(str: VALUE): VALUE {.importc, header: "ruby.h".}
proc rb_str_new_frozen*(str: VALUE): VALUE {.importc, header: "ruby.h".}
proc rb_str_buf_new*(capacity: clong): VALUE {.importc, header: "ruby.h".}
proc rb_str_buf_cat*(str: VALUE, `ptr`: cstring, len: clong): VALUE {.importc, header: "ruby.h".}
proc rb_str_buf_cat2*(str: VALUE, `ptr`: cstring): VALUE {.importc, header: "ruby.h".}
proc rb_str_cat*(str: VALUE, `ptr`: cstring, len: clong): VALUE {.importc, header: "ruby.h".}
proc rb_str_cat_cstr*(str: VALUE, `ptr`: cstring): VALUE {.importc, header: "ruby.h".}
proc rb_str_append*(str: VALUE, other: VALUE): VALUE {.importc, header: "ruby.h".}
proc rb_str_dup*(str: VALUE): VALUE {.importc, header: "ruby.h".}
proc rb_str_resize*(str: VALUE, len: clong): VALUE {.importc, header: "ruby.h".}
proc rb_str_intern*(str: VALUE): VALUE {.importc, header: "ruby.h".}
proc rb_str_to_str*(str: VALUE): VALUE {.importc, header: "ruby.h".}
proc rb_utf8_str_new*(`ptr`: cstring, len: clong): VALUE {.importc, header: "ruby.h".}
proc rb_utf8_str_new_cstr*(str: cstring): VALUE {.importc, header: "ruby.h".}
proc rb_usascii_str_new*(`ptr`: cstring, len: clong): VALUE {.importc, header: "ruby.h".}
proc rb_usascii_str_new_cstr*(str: cstring): VALUE {.importc, header: "ruby.h".}
proc rb_str_substr*(str: VALUE, beg: clong, len: clong): VALUE {.importc, header: "ruby.h".}
proc rb_str_plus*(str1: VALUE, str2: VALUE): VALUE {.importc, header: "ruby.h".}
proc rb_str_times*(str: VALUE, times: VALUE): VALUE {.importc, header: "ruby.h".}
proc rb_str_to_interned_str*(str: VALUE): VALUE {.importc, header: "ruby.h".}
proc rb_str_hash*(str: VALUE): culong {.importc, header: "ruby.h".}
proc rb_str_cmp*(str1: VALUE, str2: VALUE): cint {.importc, header: "ruby.h".}
proc rb_str_equal*(str1: VALUE, str2: VALUE): VALUE {.importc, header: "ruby.h".}

# String C string helpers
proc rb_string_value*(`ptr`: ptr VALUE): cstring {.importc, header: "ruby.h".}
proc rb_string_value_ptr*(`ptr`: ptr VALUE): cstring {.importc, header: "ruby.h".}
proc rb_string_value_cstr*(`ptr`: ptr VALUE): cstring {.importc, header: "ruby.h".}
proc rb_str_len_inline*(str: VALUE): clong {.importc, header: "ruby.h".}

# Numeric
proc rb_float_new*(d: cdouble): VALUE {.importc, header: "ruby.h".}
proc rb_num2long*(val: VALUE): clong {.importc, header: "ruby.h".}
proc rb_num2ulong*(val: VALUE): culong {.importc, header: "ruby.h".}
proc rb_num2int*(val: VALUE): clong {.importc, header: "ruby.h".}
proc rb_num2dbl*(val: VALUE): cdouble {.importc, header: "ruby.h".}
proc rb_long2num_inline*(v: clong): VALUE {.importc, header: "ruby.h".}
proc rb_int2num_inline*(v: cint): VALUE {.importc, header: "ruby.h".}
proc rb_num2int_inline*(x: VALUE): clong {.importc, header: "ruby.h".}
proc rb_num2long_inline*(x: VALUE): clong {.importc, header: "ruby.h".}
proc rb_ulong2num_inline*(v: culong): VALUE {.importc, header: "ruby.h".}
proc rb_int2big*(v: clong): VALUE {.importc, header: "ruby.h".}
proc rb_uint2big*(v: culong): VALUE {.importc, header: "ruby.h".}
proc rb_dbl_cmp*(a: cdouble, b: cdouble): VALUE {.importc, header: "ruby.h".}
proc rb_num_coerce_bin*(x: VALUE, y: VALUE, op: ID): VALUE {.importc, header: "ruby.h".}
proc rb_num_coerce_cmp*(x: VALUE, y: VALUE, op: ID): VALUE {.importc, header: "ruby.h".}

# Array
proc rb_ary_new*(): VALUE {.importc, header: "ruby.h".}
proc rb_ary_new_capa*(capacity: clong): VALUE {.importc, header: "ruby.h".}
proc rb_ary_new_from_values*(n: clong, elts: ptr VALUE): VALUE {.importc, header: "ruby.h".}
proc rb_ary_push*(ary: VALUE, item: VALUE): VALUE {.importc, header: "ruby.h".}
proc rb_ary_pop*(ary: VALUE): VALUE {.importc, header: "ruby.h".}
proc rb_ary_shift*(ary: VALUE): VALUE {.importc, header: "ruby.h".}
proc rb_ary_unshift*(ary: VALUE, item: VALUE): VALUE {.importc, header: "ruby.h".}
proc rb_ary_store*(ary: VALUE, idx: clong, val: VALUE) {.importc, header: "ruby.h".}
proc rb_ary_entry_internal*(ary: VALUE, idx: clong): VALUE {.importc, header: "ruby.h".}
proc rb_ary_dup*(ary: VALUE): VALUE {.importc, header: "ruby.h".}
proc rb_ary_clear*(ary: VALUE): VALUE {.importc, header: "ruby.h".}
proc rb_ary_join*(ary: VALUE, sep: VALUE): VALUE {.importc, header: "ruby.h".}
proc rb_ary_reverse*(ary: VALUE): VALUE {.importc, header: "ruby.h".}
proc rb_ary_sort*(ary: VALUE): VALUE {.importc, header: "ruby.h".}
proc rb_ary_sort_bang*(ary: VALUE): VALUE {.importc, header: "ruby.h".}
proc rb_ary_concat*(ary: VALUE, other: VALUE): VALUE {.importc, header: "ruby.h".}
proc rb_ary_plus*(ary: VALUE, other: VALUE): VALUE {.importc, header: "ruby.h".}
proc rb_ary_to_ary*(ary: VALUE): VALUE {.importc, header: "ruby.h".}
proc rb_ary_subseq*(ary: VALUE, beg: clong, len: clong): VALUE {.importc, header: "ruby.h".}
proc rb_ary_replace*(copy: VALUE, orig: VALUE): VALUE {.importc, header: "ruby.h".}
proc rb_ary_aref*(argc: cint, argv: ptr VALUE, ary: VALUE): VALUE {.importc, header: "ruby.h".}
proc rb_ary_resize*(ary: VALUE, len: clong): VALUE {.importc, header: "ruby.h".}
proc rb_ary_new_frozen*(ary: VALUE): VALUE {.importc, header: "ruby.h".}
proc rb_assoc_new*(key: VALUE, val: VALUE): VALUE {.importc, header: "ruby.h".}

# Array internal helpers
proc rb_array_len*(arr: VALUE): clong {.importc, header: "ruby.h".}
proc rb_array_const_ptr*(arr: VALUE): ptr VALUE {.importc, header: "ruby.h".}

# Hash
proc rb_hash_new*(): VALUE {.importc, header: "ruby.h".}
proc rb_hash_aset*(hash: VALUE, key: VALUE, val: VALUE): VALUE {.importc, header: "ruby.h".}
proc rb_hash_aref*(hash: VALUE, key: VALUE): VALUE {.importc, header: "ruby.h".}
proc rb_hash_lookup*(hash: VALUE, key: VALUE): VALUE {.importc, header: "ruby.h".}
proc rb_hash_lookup2*(hash: VALUE, key: VALUE, default: VALUE): VALUE {.importc, header: "ruby.h".}
proc rb_hash_fetch*(hash: VALUE, key: VALUE): VALUE {.importc, header: "ruby.h".}
proc rb_hash_delete*(hash: VALUE, key: VALUE): VALUE {.importc, header: "ruby.h".}
proc rb_hash_dup*(hash: VALUE): VALUE {.importc, header: "ruby.h".}
proc rb_hash_clear*(hash: VALUE): VALUE {.importc, header: "ruby.h".}
proc rb_hash_size*(hash: VALUE): VALUE {.importc, header: "ruby.h".}
proc rb_hash_freeze*(hash: VALUE): VALUE {.importc, header: "ruby.h".}
proc rb_hash_foreach*(hash: VALUE, `func`: pointer, arg: VALUE) {.importc, header: "ruby.h".}
proc rb_hash_new_capa*(capacity: clong): VALUE {.importc, header: "ruby.h".}
proc rb_hash_bulk_insert*(len: clong, arr: ptr VALUE, hash: VALUE) {.importc, header: "ruby.h".}

# Object
proc rb_obj_alloc*(klass: VALUE): VALUE {.importc, header: "ruby.h".}
proc rb_obj_dup*(obj: VALUE): VALUE {.importc, header: "ruby.h".}
proc rb_obj_clone*(obj: VALUE): VALUE {.importc, header: "ruby.h".}
proc rb_obj_freeze*(obj: VALUE): VALUE {.importc, header: "ruby.h".}
proc rb_obj_frozen_p*(obj: VALUE): VALUE {.importc, header: "ruby.h".}
proc rb_obj_id*(obj: VALUE): VALUE {.importc, header: "ruby.h".}
proc rb_obj_class*(obj: VALUE): VALUE {.importc, header: "ruby.h".}
proc rb_class_of*(obj: VALUE): VALUE {.importc, header: "ruby.h".}
proc rb_obj_is_kind_of*(obj: VALUE, klass: VALUE): VALUE {.importc, header: "ruby.h".}
proc rb_obj_is_instance_of*(obj: VALUE, klass: VALUE): VALUE {.importc, header: "ruby.h".}
proc rb_obj_classname*(obj: VALUE): cstring {.importc, header: "ruby.h".}
proc rb_obj_as_string*(obj: VALUE): VALUE {.importc, header: "ruby.h".}
proc rb_obj_taint*(obj: VALUE): VALUE {.importc, header: "ruby.h".}
proc rb_obj_untaint*(obj: VALUE): VALUE {.importc, header: "ruby.h".}
proc rb_obj_trust*(obj: VALUE): VALUE {.importc, header: "ruby.h".}
proc rb_obj_untrust*(obj: VALUE): VALUE {.importc, header: "ruby.h".}
proc rb_obj_init_copy*(obj: VALUE, orig: VALUE): VALUE {.importc, header: "ruby.h".}
proc rb_any_to_s*(obj: VALUE): VALUE {.importc, header: "ruby.h".}
proc rb_inspect*(obj: VALUE): VALUE {.importc, header: "ruby.h".}
proc rb_convert_type*(obj: VALUE, typ: cint, typeName: cstring, `method`: cstring): VALUE {.importc, header: "ruby.h".}
proc rb_check_convert_type*(obj: VALUE, typ: cint, typeName: cstring, `method`: cstring): VALUE {.importc, header: "ruby.h".}
proc rb_check_to_int*(obj: VALUE): VALUE {.importc, header: "ruby.h".}
proc rb_check_to_float*(obj: VALUE): VALUE {.importc, header: "ruby.h".}
proc rb_to_int*(obj: VALUE): VALUE {.importc, header: "ruby.h".}
proc rb_Integer*(obj: VALUE): VALUE {.importc, header: "ruby.h".}
proc rb_Float*(obj: VALUE): VALUE {.importc, header: "ruby.h".}
proc rb_String*(obj: VALUE): VALUE {.importc, header: "ruby.h".}
proc rb_Array*(obj: VALUE): VALUE {.importc, header: "ruby.h".}
proc rb_Hash*(obj: VALUE): VALUE {.importc, header: "ruby.h".}

# Type checking
proc rb_type*(obj: VALUE): cint {.importc, header: "ruby.h".}
proc rb_special_const_p*(obj: VALUE): VALUE {.importc, header: "ruby.h".}
proc rb_check_type*(obj: VALUE, typ: cint) {.importc, header: "ruby.h".}
proc rb_check_string_type*(str: VALUE): VALUE {.importc, header: "ruby.h".}
proc rb_check_array_type*(arr: VALUE): VALUE {.importc, header: "ruby.h".}
proc rb_check_hash_type*(hash: VALUE): VALUE {.importc, header: "ruby.h".}
proc rb_check_integer_type*(obj: VALUE): VALUE {.importc, header: "ruby.h".}

# Symbol / ID
proc rb_intern*(name: cstring): ID {.importc, header: "ruby.h".}
proc rb_intern_str*(str: VALUE): ID {.importc, header: "ruby.h".}
proc rb_interned_str*(`ptr`: cstring, len: clong): VALUE {.importc, header: "ruby.h".}
proc rb_id2name*(id: ID): cstring {.importc, header: "ruby.h".}
proc rb_sym2str*(sym: VALUE): VALUE {.importc, header: "ruby.h".}
proc rb_to_id*(val: VALUE): ID {.importc, header: "ruby.h".}
proc rb_check_symbol*(val: VALUE): VALUE {.importc, header: "ruby.h".}
proc rb_check_id*(val: VALUE): ID {.importc, header: "ruby.h".}

# Function calls
proc rb_funcallv*(recv: VALUE, mid: ID, argc: cint, argv: ptr VALUE): VALUE {.importc, header: "ruby.h".}
proc rb_funcallv_public*(recv: VALUE, mid: ID, argc: cint, argv: ptr VALUE): VALUE {.importc, header: "ruby.h".}
proc rb_funcallv_kw*(recv: VALUE, mid: ID, argc: cint, argv: ptr VALUE, kw_splat: cint): VALUE {.importc, header: "ruby.h".}
proc rb_call_super*(argc: cint, argv: ptr VALUE): VALUE {.importc, header: "ruby.h".}
proc rb_class_new_instance*(argc: cint, argv: ptr VALUE, klass: VALUE): VALUE {.importc, header: "ruby.h".}
proc rb_class_new_instance_pass_kw*(argc: cint, argv: ptr VALUE, klass: VALUE): VALUE {.importc, header: "ruby.h".}
proc rb_block_given_p*(): cint {.importc, header: "ruby.h".}

# Yielding
proc rb_yield*(val: VALUE): VALUE {.importc, header: "ruby.h".}
proc rb_yield_splat*(args: VALUE): VALUE {.importc, header: "ruby.h".}
proc rb_yield_values2*(argc: cint, argv: ptr VALUE): VALUE {.importc, header: "ruby.h".}
proc rb_block_proc*(): VALUE {.importc, header: "ruby.h".}
proc rb_block_param_proc*(): VALUE {.importc, header: "ruby.h".}

# Execution / eval
proc rb_eval_string*(str: cstring): VALUE {.importc, header: "ruby.h".}
proc rb_eval_string_protect*(str: cstring, state: ptr cint): VALUE {.importc, header: "ruby.h".}
proc rb_require*(fname: cstring): VALUE {.importc, header: "ruby.h".}
proc rb_protect*(`func`: pointer, data: VALUE, state: ptr cint): VALUE {.importc, header: "ruby.h".}
proc rb_rescue*(`func`: pointer, arg: VALUE, rescue: pointer, arg2: VALUE): VALUE {.importc, header: "ruby.h".}
proc rb_ensure*(`func`: pointer, arg: VALUE, ensureFunc: pointer, arg2: VALUE): VALUE {.importc, header: "ruby.h".}
proc rb_jump_env*(env: pointer) {.importc, header: "ruby.h".}
proc rb_error_arity*(argc: cint, min: cint, max: cint) {.importc, header: "ruby.h".}

# Exception handling
proc rb_exc_new*(exc: VALUE, `ptr`: cstring, len: clong): VALUE {.importc, header: "ruby.h".}
proc rb_exc_new_cstr*(exc: VALUE, str: cstring): VALUE {.importc, header: "ruby.h".}
proc rb_exc_new_str*(exc: VALUE, str: VALUE): VALUE {.importc, header: "ruby.h".}
proc rb_exc_raise*(exc: VALUE) {.importc, header: "ruby.h".}
proc rb_raise*(exc: VALUE, fmt: cstring) {.importc, header: "ruby.h", varargs.}
proc rb_fatal*(fmt: cstring) {.importc, header: "ruby.h", varargs.}
proc rb_warn*(fmt: cstring) {.importc, header: "ruby.h", varargs.}
proc rb_warning*(fmt: cstring) {.importc, header: "ruby.h", varargs.}
proc rb_notify*(fmt: cstring) {.importc, header: "ruby.h", varargs.}

# I/O / misc
proc rb_p*(obj: VALUE) {.importc, header: "ruby.h".}
proc rb_sprintf*(fmt: cstring): VALUE {.importc, header: "ruby.h", varargs.}
proc rb_vsprintf*(fmt: cstring, ap: ptr pointer): VALUE {.importc, header: "ruby.h".}

# GC
proc rb_gc_mark*(obj: VALUE) {.importc, header: "ruby.h".}
proc rb_gc_register_mark_object*(obj: VALUE) {.importc, header: "ruby.h".}
proc rb_gc_mark_maybe*(obj: VALUE) {.importc, header: "ruby.h".}
proc rb_gc_unregister_address*(`addr`: ptr VALUE) {.importc, header: "ruby.h".}
proc rb_gc_register_address*(`addr`: ptr VALUE) {.importc, header: "ruby.h".}
proc rb_obj_gc_flags*(obj: VALUE, flags: ptr VALUE): cint {.importc, header: "ruby.h".}

# Ractor
proc rb_ractor_shared_p*(obj: VALUE): bool {.importc, header: "ruby.h".}
proc rb_ractor_make_shared_copy*(obj: VALUE): VALUE {.importc, header: "ruby.h".}

# Encoding
proc rb_enc_str_new*(`ptr`: cstring, len: clong, enc: pointer): VALUE {.importc, header: "ruby.h".}
proc rb_default_encoding*(): pointer {.importc, header: "ruby.h".}
proc rb_utf8_encoding*(): pointer {.importc, header: "ruby.h".}
proc rb_usascii_encoding*(): pointer {.importc, header: "ruby.h".}
proc rb_ascii8bit_encoding*(): pointer {.importc, header: "ruby.h".}
proc rb_enc_get_index*(obj: VALUE): cint {.importc, header: "ruby.h".}
proc rb_enc_set_index*(obj: VALUE, idx: cint): VALUE {.importc, header: "ruby.h".}
proc rb_enc_find_index*(name: cstring): cint {.importc, header: "ruby.h".}
proc rb_enc_find*(name: cstring): pointer {.importc, header: "ruby.h".}
proc rb_enc_name*(enc: pointer): cstring {.importc, header: "ruby.h".}

# Thread
proc rb_thread_call_without_gvl*(`func`: pointer, data1: pointer, unblockFunc: pointer, data2: pointer): pointer {.importc, header: "ruby.h".}
proc rb_thread_call_with_gvl*(`func`: pointer, data1: pointer): pointer {.importc, header: "ruby.h".}
proc rb_thread_current*(): VALUE {.importc, header: "ruby.h".}

# rb_scan_args — variadic
proc rb_scan_args_kw*(kw_flag: cint, argc: cint, argv: ptr VALUE, fmt: cstring): cint {.importc, header: "ruby.h", varargs.}

# rb_define_alloc_func / rb_undef_alloc_func
proc rb_define_alloc_func*(klass: VALUE, `func`: pointer) {.importc, header: "ruby.h".}
proc rb_undef_alloc_func*(klass: VALUE) {.importc, header: "ruby.h".}

# Data types (for wrapping C structs in Ruby)
proc rb_data_typed_object_wrap*(klass: VALUE, datap: pointer, dataType: pointer): VALUE {.importc, header: "ruby.h".}
proc rb_data_typed_object_zalloc*(klass: VALUE, size: clong, dataType: pointer): VALUE {.importc, header: "ruby.h".}

# Constants like rb_cObject, rb_eStandardError, etc.
var rb_cObject* {.importc, header: "ruby.h".}: VALUE
var rb_cModule* {.importc, header: "ruby.h".}: VALUE
var rb_cClass* {.importc, header: "ruby.h".}: VALUE
var rb_cString* {.importc, header: "ruby.h".}: VALUE
var rb_cInteger* {.importc, header: "ruby.h".}: VALUE
var rb_cFloat* {.importc, header: "ruby.h".}: VALUE
var rb_cArray* {.importc, header: "ruby.h".}: VALUE
var rb_cHash* {.importc, header: "ruby.h".}: VALUE
var rb_cSymbol* {.importc, header: "ruby.h".}: VALUE
var rb_cData* {.importc, header: "ruby.h".}: VALUE
var rb_cTrueClass* {.importc, header: "ruby.h".}: VALUE
var rb_cFalseClass* {.importc, header: "ruby.h".}: VALUE
var rb_cNilClass* {.importc, header: "ruby.h".}: VALUE
var rb_cProc* {.importc, header: "ruby.h".}: VALUE
var rb_cBinding* {.importc, header: "ruby.h".}: VALUE
var rb_cMethod* {.importc, header: "ruby.h".}: VALUE
var rb_cRange* {.importc, header: "ruby.h".}: VALUE
var rb_cTime* {.importc, header: "ruby.h".}: VALUE
var rb_cRegexp* {.importc, header: "ruby.h".}: VALUE
var rb_cMatch* {.importc, header: "ruby.h".}: VALUE
var rb_cIO* {.importc, header: "ruby.h".}: VALUE
var rb_cFile* {.importc, header: "ruby.h".}: VALUE
var rb_cDir* {.importc, header: "ruby.h".}: VALUE

# Exception classes
var rb_eException* {.importc, header: "ruby.h".}: VALUE
var rb_eStandardError* {.importc, header: "ruby.h".}: VALUE
var rb_eRuntimeError* {.importc, header: "ruby.h".}: VALUE
var rb_eTypeError* {.importc, header: "ruby.h".}: VALUE
var rb_eArgumentError* {.importc, header: "ruby.h".}: VALUE
var rb_eIndexError* {.importc, header: "ruby.h".}: VALUE
var rb_eKeyError* {.importc, header: "ruby.h".}: VALUE
var rb_eRangeError* {.importc, header: "ruby.h".}: VALUE
var rb_eNameError* {.importc, header: "ruby.h".}: VALUE
var rb_eNoMethodError* {.importc, header: "ruby.h".}: VALUE
var rb_eZeroDivError* {.importc, header: "ruby.h".}: VALUE
var rb_eFloatDomainError* {.importc, header: "ruby.h".}: VALUE
var rb_eEOFError* {.importc, header: "ruby.h".}: VALUE
var rb_eScriptError* {.importc, header: "ruby.h".}: VALUE
var rb_eSyntaxError* {.importc, header: "ruby.h".}: VALUE
var rb_eLoadError* {.importc, header: "ruby.h".}: VALUE
var rb_eFrozenError* {.importc, header: "ruby.h".}: VALUE
var rb_eSystemCallError* {.importc, header: "ruby.h".}: VALUE

template rb_funcall*(recv: VALUE, mid: ID, args: varargs[VALUE]): VALUE =
  rb_funcallv(recv, mid, cint(args.len), args.base())

template rb_str_new2*(str: cstring): VALUE =
  rb_str_new_cstr(str)

proc toRbString*(s: string): VALUE =
  rb_str_new_cstr(cstring(s))

proc toRbInt*(n: int): VALUE =
  INT2NUM(cint(n))

proc toRbFloat*(n: float): VALUE =
  rb_float_new(cdouble(n))

proc toRbBool*(b: bool): VALUE =
  if b: Qtrue else: Qfalse

proc toRbArray*(): VALUE =
  rb_ary_new()

proc toRbHash*(): VALUE =
  rb_hash_new()
