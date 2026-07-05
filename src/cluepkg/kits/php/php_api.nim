# Clue - A toolkit for cool developers
#
# (c) 2026 George Lemon | LGPL-v3 License
#          Made by Humans from OpenPeeps
#          https://github.com/openpeeps/clue

# this should be passed to the dev plugin to be included
{.passC: "-I/opt/local/include/php83/php -I/opt/local/include/php83/php/main -I/opt/local/include/php83/php/TSRM -I/opt/local/include/php83/php/Zend -I/opt/local/include/php83/php/ext -I/opt/local/include/php83/php/ext/date/lib -I/opt/local/include".}
{.passL: "-Wl,-undefined,dynamic_lookup".}

## This module provides the low-level C API bindings to PHP API, which can be used to implement
## higher-level wrappers and DSLs for defining PHP extensions in Nim

type
  zend_uchar* = cuchar
  zend_long* = clong
  zend_ulong* = culong

# zval is passed by pointer almost everywhere; keep it ABI-stable as a blob.
# PHP 8.x zval is 16 bytes on mainstream builds.
type
  zval* {.bycopy.} = object
    storage*: array[16, byte]

# Opaque Zend structs
type
  zend_string* {.importc: "zend_string", header: "Zend/zend_types.h", incompleteStruct.} = object
  zend_array* {.importc: "zend_array", header: "Zend/zend_types.h", incompleteStruct.} = object
  zend_resource* {.importc: "zend_resource", header: "Zend/zend_types.h", incompleteStruct.} = object
  zend_reference* {.importc: "zend_reference", header: "Zend/zend_types.h", incompleteStruct.} = object
  zend_object_handlers* {.importc: "zend_object_handlers", header: "Zend/zend_object_handlers.h", incompleteStruct.} = object
  zend_object* {.importc: "zend_object", header: "Zend/zend_types.h", incompleteStruct.} = object
  zend_function* {.importc: "zend_function", header: "Zend/zend_compile.h", incompleteStruct.} = object
  zend_execute_data* {.importc: "zend_execute_data", header: "Zend/zend_compile.h", incompleteStruct.} = object
  zend_class_entry* {.importc: "zend_class_entry", header: "Zend/zend.h", incompleteStruct.} = object
  ZendHashTable* {.importc: "HashTable", header: "Zend/zend_types.h", incompleteStruct.} = object
  
  # a simplified version of zend_internal_arg_info
  zend_internal_arg_info* {.importc: "zend_internal_arg_info", header: "Zend/zend_API.h", incompleteStruct.} = object

{.compile: "php_api.c".}

#
#  PHP Extension API Wrappers
#
type
  zend_function_entry* {.importc: "zend_function_entry", header: "Zend/zend_API.h", incompleteStruct.} = object
  zend_module_entry* {.importc: "zend_module_entry", header: "Zend/zend_modules.h", incompleteStruct.} = object

  php_zif_handler* = proc(execute_data: ptr zend_execute_data, return_value: ptr zval) {.cdecl.}
  php_startup_func_t* = proc(typ: cint, module_number: cint): cint {.cdecl.}
  php_shutdown_func_t* = proc(typ: cint, module_number: cint): cint {.cdecl.}
  php_info_func_t* = proc(module: ptr zend_module_entry) {.cdecl.}

{.push importc.}
proc php_fe_alloc*(count: csize_t): ptr zend_function_entry
proc php_fe_set*(
  table: ptr zend_function_entry,
  idx: csize_t,
  name: cstring,
  handler: php_zif_handler,
  arg_info: ptr zend_internal_arg_info,
  num_args: uint32,
  flags: uint32
)
proc php_fe_end*(table: ptr zend_function_entry, idx: csize_t)

proc php_module_alloc*(): ptr zend_module_entry
proc php_module_init*(
  m: ptr zend_module_entry,
  name: cstring,
  version: cstring,
  functions: ptr zend_function_entry,
  minit: php_startup_func_t,
  mshutdown: php_shutdown_func_t,
  rinit: php_startup_func_t,
  rshutdown: php_shutdown_func_t,
  minfo: php_info_func_t
)


proc php_z_lval_p*(zv: ptr zval): ptr zend_long
proc php_z_dval_p*(zv: ptr zval): ptr cdouble
proc php_z_str_p*(zv: ptr zval): ptr zend_string
proc php_z_strval_p*(v: ptr zval): cstring
proc php_z_arr_p*(zv: ptr zval): ptr zend_array
proc php_z_refcounted_p*(zval_ptr: ptr zval): bool
proc php_z_res_handle_p*(val: ptr zval): cint
proc php_z_type_info_p*(zv: ptr zval): uint32
proc php_z_type_p*(zv: ptr zval): cint
proc php_z_res_p*(zv: ptr zval): ptr zend_resource
proc php_z_ref_p*(zv: ptr zval): ptr zend_reference
proc php_z_obj_ht_p*(zv: ptr zval): ptr zend_object_handlers
proc php_z_obj_p*(zv: ptr zval): ptr zend_object
proc php_z_addref_p*(zv: ptr zval): uint32
proc php_z_func_p*(zv: ptr zval): ptr zend_function
proc php_z_ptr_p*(zv: ptr zval): pointer
proc php_zval_get_type*(pz: ptr zval): zend_uchar
proc php_zval_arr*(val: ptr zval, arr: ptr zend_array)
proc php_zval_new_arr*(val: ptr zval)
proc php_zval_stringl*(val: ptr zval, s: cstring, len: csize_t)
proc php_zval_zval*(val, zv: ptr zval, copy, dtor: cint)
proc php_zval_copy*(val: ptr zval, zv: ptr zval)
proc php_zval_copy_value*(val: ptr zval, zv: ptr zval)
proc php_zval_get_string*(op: ptr zval): ptr zend_string
proc php_zval_get_long*(op: ptr zval): zend_long
proc php_zval_obj*(z: ptr zval, o: ptr zend_object)
proc php_zval_func*(z: ptr zval, f: ptr zend_function)
proc php_zval_ptr_dtor*(zv: ptr zval)
proc php_zval_ptr_dtor_nogc*(zval_ptr: ptr zval)
proc php_zval_null*(zv: ptr zval)
proc php_zval_true*(zv: ptr zval)
proc php_zval_false*(zv: ptr zval)
proc php_zval_long*(zv: ptr zval, l: zend_long)
proc php_zval_double*(zv: ptr zval, d: cdouble)
proc php_zval_str*(zv: ptr zval, s: ptr zend_string)
proc php_zval_undef*(zv: ptr zval)
proc php_convert_to_long*(op: ptr zval)
proc php_convert_to_string*(op: ptr zval)
proc php_separate_array*(zv: ptr zval)

#
# String API
#
proc php_zend_new_interned_string*(str: ptr zend_string): ptr zend_string
proc php_zend_string_init*(str: cstring, len: csize_t, persistent: cint): ptr zend_string
proc php_zend_string_alloc*(len: csize_t, persistent: cint): ptr zend_string
proc php_zend_string_release*(s: ptr zend_string)
when not defined(php83):
  proc php_zend_string_concat3*(str1: cstring, str1_len: csize_t, str2: cstring, str2_len: csize_t, str3: cstring, str3_len: csize_t): ptr zend_string
proc php_zstr_len*(s: ptr zend_string): cint
proc php_zstr_val*(s: ptr zend_string): cstring
proc php_separate_string*(zv: ptr zval)
proc php_zend_string_copy*(s: ptr zend_string): ptr zend_string

#
# ZendHashTable and array related APIs
#
proc php_zend_hash_str_update*(ht: ptr ZendHashTable, key: cstring, len: csize_t, pData: ptr zval): ptr zval
proc php_zend_hash_index_update*(ht: ptr ZendHashTable, h: zend_ulong, pData: ptr zval): ptr zval
proc php_zend_hash_next_index_insert*(ht: ptr ZendHashTable, pData: ptr zval): ptr zval
proc php_array_init*(arg: ptr zval)
proc php_zend_hash_str_find_ptr*(ht: ptr ZendHashTable, str: cstring, len: csize_t): pointer
proc php_zend_hash_str_exists*(ht: ptr ZendHashTable, str: cstring, len: csize_t): bool
proc php_zend_hash_index_exists*(ht: ptr ZendHashTable, h: zend_ulong): bool
proc php_zend_new_array*(size: uint32): ptr zend_array
proc php_zend_array_dup*(source: ptr zend_array): ptr zend_array
proc php_zend_hash_index_find*(ht: ptr ZendHashTable, h: zend_ulong): ptr zval
proc php_zend_hash_index_del*(ht: ptr ZendHashTable, h: zend_ulong): bool
proc php_zend_symtable_str_update*(ht: ptr ZendHashTable, str: cstring, len: csize_t, pData: ptr zval): ptr zval
proc php_zend_symtable_str_del*(ht: ptr ZendHashTable, str: cstring, len: csize_t): bool
proc php_zend_symtable_str_find*(ht: ptr ZendHashTable, str: cstring, len: csize_t): ptr zval
proc php_zend_symtable_str_exists*(ht: ptr ZendHashTable, str: cstring, len: csize_t): bool

#
# Object and class related APIs
#
proc php_get_this*(execute_data: ptr zend_execute_data): ptr zval
proc php_get_called_scope*(execute_data: ptr zend_execute_data): ptr zend_class_entry
proc php_zend_object_properties_size*(ce: ptr zend_class_entry): csize_t
proc php_zend_object_alloc*(obj_size: csize_t, ce: ptr zend_class_entry): pointer
proc php_get_create_object*(ce: ptr zend_class_entry): pointer
proc php_object_init_ex*(arg: ptr zval, class_type: ptr zend_class_entry): bool
proc php_zend_object_release*(obj: ptr zend_object)
proc php_zend_object_gc_refcount*(obj: ptr zend_object): uint32

proc php_init_class_entry_ex*(class_name: cstring, class_name_len: csize_t, functions: pointer, handler: pointer, argument: pointer): ptr zend_class_entry
proc php_instanceof_function*(instance_ce: ptr zend_class_entry, ce: ptr zend_class_entry): bool
proc php_get_parent_class*(ce: ptr zend_class_entry): ptr zend_class_entry

#
# Function call related APIs
#
proc php_get_function_or_method_name*(fn: ptr zend_function): ptr zend_string
proc php_get_function_name*(fn: ptr zend_function): ptr zend_string
proc php_call_user_function*(function_table: ptr ZendHashTable, obj: ptr zval, function_name: ptr zval, retval_ptr: ptr zval, param_count: uint32, params: ptr zval): bool
proc php_zend_call_var_num*(execute_data: ptr zend_execute_data, index: cint): ptr zval
proc php_zend_call_arg*(execute_data: ptr zend_execute_data, index: cint): ptr zval
proc php_zend_num_args*(execute_data: ptr zend_execute_data): uint32
proc php_zend_call_num_args*(execute_data: ptr zend_execute_data): uint32
proc php_zend_set_call_num_args*(execute_data: ptr zend_execute_data, num: uint32)
proc php_zend_call_info*(execute_data: ptr zend_execute_data): uint32
proc php_zend_add_call_flag*(execute_data: ptr zend_execute_data, flag: uint32)
proc php_zend_get_parameters_array_ex*(param_count: uint32, argument_array: ptr zval): bool
proc php_zend_parse_parameters*(execute_data: ptr zend_execute_data, format: cstring): cint {.cdecl, importc, varargs.}
proc php_zend_call_may_have_undef*(): uint32
proc php_zend_result_success*(): cint
proc php_zend_result_failure*(): cint

#
# Memory management APIs
#
proc php_emalloc*(size: csize_t): pointer
proc php_efree*(pt: pointer)

#
# Other APIs
#
proc php_get_zend_module_build_id*(): cstring
proc php_zend_begin_arg_info_ex*(return_reference: bool, required_num_args: culong): zend_internal_arg_info
proc php_zend_begin_arg_with_return_type_info_ex*(return_reference: bool, required_num_args: culong, typ: uint32, allow_null: bool): zend_internal_arg_info
proc php_zend_begin_arg_with_return_obj_info_ex*(return_reference: bool, required_num_args: culong, class_name: cstring, allow_null: bool): zend_internal_arg_info
proc php_zend_arg_info*(pass_by_ref: bool, name: cstring): zend_internal_arg_info
proc php_zend_arg_info_with_type*(pass_by_ref: bool, name: cstring, type_hint: uint32, allow_null: bool, default_value: cstring): zend_internal_arg_info
proc php_zend_arg_obj_info*(pass_by_ref: bool, name: cstring, class_name: cstring, allow_null: bool): zend_internal_arg_info

proc php_arginfo_alloc*(argc: csize_t): ptr zend_internal_arg_info
proc php_arginfo_set_typed*(
  info: ptr zend_internal_arg_info,
  idx: csize_t,
  pass_by_ref: bool,
  name: cstring,
  type_hint: uint32,
  allow_null: bool
)
proc php_arginfo_finalize*(
  info: ptr zend_internal_arg_info,
  argc: csize_t
): ptr zend_internal_arg_info

# Exception handling APIs
proc php_throw_exception*(msg: cstring) {.cdecl, importc.}
proc php_throw_type_error*(msg: cstring) {.cdecl, importc.}

proc php_get_IS_STRING*(): uint32 {.cdecl, importc.}
proc php_get_IS_LONG*(): uint32 {.cdecl, importc.}
proc php_get_IS_ARRAY*(): uint32 {.cdecl, importc.}
proc php_get_IS_OBJECT*(): uint32 {.cdecl, importc.}
proc php_get_IS_DOUBLE*(): uint32 {.cdecl, importc.}
{.pop.}

proc toPhpString*(retTy: ptr zval, s: string) =
  php_zval_stringl(retTy, cstring(s), csize_t(s.len))

proc toPhpInt*(retTy: ptr zval, n: int) =
  php_zval_long(retTy, zend_long(n))

proc toPhpFloat*(retTy: ptr zval, n: float) =
  php_zval_double(retTy, cdouble(n))

proc toPhpBool*(retTy: ptr zval, b: bool) =
  if b: php_zval_true(retTy)
  else: php_zval_false(retTy)
