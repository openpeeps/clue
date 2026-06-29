// Copyright (c) 2022 PHPER Framework Team
// PHPER is licensed under Mulan PSL v2.
// You can use this software according to the terms and conditions of the Mulan
// PSL v2. You may obtain a copy of Mulan PSL v2 at:
//          http://license.coscl.org.cn/MulanPSL2
// THIS SOFTWARE IS PROVIDED ON AN "AS IS" BASIS, WITHOUT WARRANTIES OF ANY
// KIND, EITHER EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO
// NON-INFRINGEMENT, MERCHANTABILITY OR FIT FOR A PARTICULAR PURPOSE.
// See the Mulan PSL v2 for more details.

// Clue - A toolkit for cool developers
// (c) 2026 George Lemon | Modified from PHPER framework under Mulan PSL v2

#include <stdlib.h>
#include <string.h>
#include <stdarg.h>

#include <stdbool.h>

#include <php.h>
#include <php_ini.h>

#include <ext/standard/info.h>
#include <main/SAPI.h>
#include <zend_exceptions.h>
#include <zend_interfaces.h>

#if PHP_MAJOR_VERSION >= 8
#include <zend_observer.h>
#endif

#if PHP_VERSION_ID >= 80100
#include <zend_enum.h>
#endif

typedef ZEND_INI_MH(php_zend_ini_mh);

typedef zend_class_entry *
php_init_class_entry_handler(zend_class_entry *class_ce, void *argument);

// ==================================================
// BC for older PHP versions:
// ==================================================
#ifndef IS_MIXED
#define IS_MIXED 0x1A
#endif

#ifndef IS_NEVER
#define IS_NEVER 0x1B
#endif

#ifndef IS_ITERABLE
#define IS_ITERABLE 0x1C
#endif

#ifndef IS_VOID
#define IS_VOID 0x1D
#endif

#ifndef ZEND_CALL_MAY_HAVE_UNDEF
#define ZEND_CALL_MAY_HAVE_UNDEF (1 << 26)
#endif

// ==================================================
// zval apis:
// ==================================================

zend_long *php_z_lval_p(zval *zv) {
    return &(Z_LVAL_P(zv));
}

double *php_z_dval_p(zval *zv) {
    return &(Z_DVAL_P(zv));
}

zend_string *php_z_str_p(const zval *zv) {
    return Z_STR_P(zv);
}

char *php_z_strval_p(const zval *v) {
    return Z_STRVAL_P(v);
}

zend_array *php_z_arr_p(const zval *zv) {
    return Z_ARR_P(zv);
}

bool php_z_refcounted_p(zval *zval_ptr) {
    return Z_REFCOUNTED_P(zval_ptr);
}

int php_z_res_handle_p(const zval *val) {
    return Z_RES_HANDLE_P(val);
}

uint32_t php_z_type_info_p(const zval *zv) {
    return Z_TYPE_INFO_P(zv);
}

int php_z_type_p(zval *zv) {
    return Z_TYPE_P(zv);
}

zend_resource *php_z_res_p(const zval *zv) {
    return Z_RES_P(zv);
}

zend_reference *php_z_ref_p(const zval *zv) {
    return Z_REF_P(zv);
}

const zend_object_handlers *php_z_obj_ht_p(const zval *zv) {
    return Z_OBJ_HT_P(zv);
}

zend_object *php_z_obj_p(const zval *zv) {
    return Z_OBJ_P(zv);
}

uint32_t php_z_addref_p(zval *zv) {
    return Z_ADDREF_P(zv);
}

zend_function *php_z_func_p(const zval *zv) {
    return Z_FUNC_P(zv);
}

void *php_z_ptr_p(const zval *zv) {
    return Z_PTR_P(zv);
}

zend_uchar php_zval_get_type(const zval *pz) {
    return zval_get_type(pz);
}

void php_zval_arr(zval *val, zend_array *arr) {
    ZVAL_ARR(val, arr);
}

void php_zval_new_arr(zval *val) {
#if PHP_VERSION_ID < 80100
    ZVAL_NEW_ARR(val);
#else
    array_init(val);
#endif
}

void php_zval_stringl(zval *val, const char *s, size_t len) {
    ZVAL_STRINGL(val, s, len);
}

void php_zval_zval(zval *val, zval *zv, int copy, int dtor) {
    ZVAL_ZVAL(val, zv, copy, dtor);
}

void php_zval_copy(zval *val, const zval *zv) {
    ZVAL_COPY(val, zv);
}

void php_zval_copy_value(zval *val, const zval *zv) {
    ZVAL_COPY_VALUE(val, zv);
}

zend_string *php_zval_get_string(zval *op) {
    return zval_get_string(op);
}

zend_long php_zval_get_long(zval *op) {
    return zval_get_long(op);
}

void php_zval_obj(zval *z, zend_object *o) {
    ZVAL_OBJ(z, o);
}

void php_zval_func(zval *z, zend_function *f) {
    ZVAL_FUNC(z, f);
}

void php_zval_ptr_dtor(zval *zv) {
    ZVAL_PTR_DTOR(zv);
}

void php_zval_ptr_dtor_nogc(zval *zval_ptr) {
    zval_ptr_dtor_nogc(zval_ptr);
}

void php_zval_null(zval *zv) {
    ZVAL_NULL(zv);
}

void php_zval_true(zval *zv) {
    ZVAL_TRUE(zv);
}

void php_zval_false(zval *zv) {
    ZVAL_FALSE(zv);
}

void php_zval_long(zval *zv, zend_long l) {
    ZVAL_LONG(zv, l);
}

void php_zval_double(zval *zv, double d) {
    ZVAL_DOUBLE(zv, d);
}

void php_zval_str(zval *zv, zend_string *s) {
    ZVAL_STR(zv, s);
}

void php_zval_undef(zval *zv) {
    ZVAL_UNDEF(zv);
}

void php_convert_to_long(zval *op) {
    convert_to_long(op);
}

void php_convert_to_string(zval *op) {
    convert_to_string(op);
}

void php_separate_array(zval *zv) {
    SEPARATE_ARRAY(zv);
}



// ---- Extension bootstrap ABI helpers ----

typedef void (*php_zif_handler)(zend_execute_data *execute_data, zval *return_value);
typedef int (*php_startup_func_t)(int type, int module_number);
typedef int (*php_shutdown_func_t)(int type, int module_number);
typedef void (*php_info_func_t)(zend_module_entry *zend_module);

zend_function_entry *php_fe_alloc(size_t count) {
    // +1 for FE_END terminator
    return (zend_function_entry *)calloc(count + 1, sizeof(zend_function_entry));
}

void php_fe_set(
    zend_function_entry *table,
    size_t idx,
    const char *name,
    php_zif_handler handler,
    const zend_internal_arg_info *arg_info,
    uint32_t num_args,
    uint32_t flags
) {
    table[idx].fname = name;
    table[idx].handler = (zif_handler)handler;
    table[idx].arg_info = arg_info;
    table[idx].num_args = num_args;
    table[idx].flags = flags;
}

void php_fe_end(zend_function_entry *table, size_t idx) {
    memset(&table[idx], 0, sizeof(zend_function_entry));
}

zend_module_entry *php_module_alloc(void) {
    return (zend_module_entry *)calloc(1, sizeof(zend_module_entry));
}

void php_module_init(
    zend_module_entry *m,
    const char *name,
    const char *version,
    const zend_function_entry *functions,
    php_startup_func_t minit,
    php_shutdown_func_t mshutdown,
    php_startup_func_t rinit,
    php_shutdown_func_t rshutdown,
    php_info_func_t minfo
) {
    m->size = sizeof(zend_module_entry);
    m->zend_api = ZEND_MODULE_API_NO;
    m->zend_debug = ZEND_DEBUG;
    m->zts = USING_ZTS;
    m->ini_entry = NULL;
    m->deps = NULL;

    m->name = name;
    m->functions = functions;
    m->module_startup_func = (zend_result (*)(INIT_FUNC_ARGS))minit;
    m->module_shutdown_func = (zend_result (*)(SHUTDOWN_FUNC_ARGS))mshutdown;
    m->request_startup_func = (zend_result (*)(INIT_FUNC_ARGS))rinit;
    m->request_shutdown_func = (zend_result (*)(SHUTDOWN_FUNC_ARGS))rshutdown;
    m->info_func = (void (*)(ZEND_MODULE_INFO_FUNC_ARGS))minfo;

    m->version = version;
    m->globals_size = 0;
    m->globals_ptr = NULL;
    m->globals_ctor = NULL;
    m->globals_dtor = NULL;
    m->post_deactivate_func = NULL;
    m->module_started = 0;
    m->type = 0;
    m->handle = NULL;
    m->module_number = 0;
    m->build_id = ZEND_MODULE_BUILD_ID;
}

// Nim must export this exact symbol.
extern zend_module_entry *php_nim_module_entry(void);

// PHP loader entrypoint.
ZEND_DLEXPORT zend_module_entry *get_module(void) {
    return php_nim_module_entry();
}

ZEND_BEGIN_ARG_WITH_RETURN_TYPE_INFO_EX(arginfo_cage_hello_php_function, 0, 0, IS_STRING, 0)
ZEND_END_ARG_INFO()

const zend_internal_arg_info* php_arginfo_cage_hello_php_function(void) {
    return arginfo_cage_hello_php_function;
}


// ==================================================
// string apis:
// ==================================================

zend_string *php_zend_new_interned_string(zend_string *str) {
    return zend_new_interned_string(str);
}

zend_string *php_zend_string_init(const char *str, size_t len,
                                    int persistent) {
    return zend_string_init(str, len, persistent);
}

zend_string *php_zend_string_alloc(size_t len, int persistent) {
    return zend_string_alloc(len, persistent);
}

void php_zend_string_release(zend_string *s) {
    return zend_string_release(s);
}

#if PHP_VERSION_ID < 80000
static zend_string *php_zend_string_concat3(const char *str1, size_t str1_len,
                                              const char *str2, size_t str2_len,
                                              const char *str3,
                                              size_t str3_len) {
    size_t len = str1_len + str2_len + str3_len;
    zend_string *res = zend_string_alloc(len, 0);

    memcpy(ZSTR_VAL(res), str1, str1_len);
    memcpy(ZSTR_VAL(res) + str1_len, str2, str2_len);
    memcpy(ZSTR_VAL(res) + str1_len + str2_len, str3, str3_len);
    ZSTR_VAL(res)
    [len] = '\0';

    return res;
}
#endif

int php_zstr_len(const zend_string *s) {
    return ZSTR_LEN(s);
}

const char *php_zstr_val(const zend_string *s) {
    return ZSTR_VAL(s);
}

void php_separate_string(zval *zv) {
    SEPARATE_STRING(zv);
}

zend_string *php_zend_string_copy(zend_string *s) {
    return zend_string_copy(s);
}

// ==================================================
// array apis:
// ==================================================

zval *php_zend_hash_str_update(HashTable *ht, const char *key, size_t len,
                                 zval *pData) {
    return zend_hash_str_update(ht, key, len, pData);
}

zval *php_zend_hash_index_update(HashTable *ht, zend_ulong h, zval *pData) {
    return zend_hash_index_update(ht, h, pData);
}

zval *php_zend_hash_next_index_insert(HashTable *ht, zval *pData) {
    return zend_hash_next_index_insert(ht, pData);
}

void php_array_init(zval *arg) {
    array_init(arg);
}

void *php_zend_hash_str_find_ptr(const HashTable *ht, const char *str,
                                   size_t len) {
    return zend_hash_str_find_ptr(ht, str, len);
}

bool php_zend_hash_str_exists(const HashTable *ht, const char *str,
                                size_t len) {
    return zend_hash_str_exists(ht, str, len) != 0;
}

bool php_zend_hash_index_exists(const HashTable *ht, zend_ulong h) {
    return zend_hash_index_exists(ht, h) != 0;
}

zend_array *php_zend_new_array(uint32_t size) {
#if PHP_VERSION_ID >= 70300
    return zend_new_array(size);
#else
    HashTable *ht = emalloc(sizeof(HashTable));
    zend_hash_init(ht, size, NULL, ZVAL_PTR_DTOR, 0);
    return ht;
#endif
}

zend_array *php_zend_array_dup(zend_array *source) {
    return zend_array_dup(source);
}

zval *php_zend_hash_index_find(const HashTable *ht, zend_ulong h) {
    return zend_hash_index_find(ht, h);
}

bool php_zend_hash_index_del(HashTable *ht, zend_ulong h) {
    return zend_hash_index_del(ht, h) == SUCCESS;
}

zval *php_zend_symtable_str_update(HashTable *ht, const char *str, size_t len,
                                     zval *pData) {
    return zend_symtable_str_update(ht, str, len, pData);
}

bool php_zend_symtable_str_del(HashTable *ht, const char *str, size_t len) {
    return zend_symtable_str_del(ht, str, len) == SUCCESS;
}

zval *php_zend_symtable_str_find(HashTable *ht, const char *str, size_t len) {
    return zend_symtable_str_find(ht, str, len);
}

bool php_zend_symtable_str_exists(HashTable *ht, const char *str,
                                    size_t len) {
    return zend_symtable_str_exists(ht, str, len) != 0;
}

// ==================================================
// object apis:
// ==================================================

zval *php_get_this(zend_execute_data *execute_data) {
    return getThis();
}

zend_class_entry *php_get_called_scope(zend_execute_data *execute_data) {
    return zend_get_called_scope(execute_data);
}

size_t php_zend_object_properties_size(zend_class_entry *ce) {
    return zend_object_properties_size(ce);
}

void *php_zend_object_alloc(size_t obj_size, zend_class_entry *ce) {
#if PHP_VERSION_ID >= 70300
    return zend_object_alloc(obj_size, ce);
#else
    void *obj = emalloc(obj_size + zend_object_properties_size(ce));
    memset(obj, 0, obj_size - sizeof(zval));
    return obj;
#endif
}

zend_object *(**php_get_create_object(zend_class_entry *ce))(
    zend_class_entry *class_type) {
    return &ce->create_object;
}

bool php_object_init_ex(zval *arg, zend_class_entry *class_type) {
    return object_init_ex(arg, class_type) == SUCCESS;
}

void php_zend_object_release(zend_object *obj) {
    zend_object_release(obj);
}

uint32_t php_zend_object_gc_refcount(const zend_object *obj) {
    return GC_REFCOUNT(obj);
}

// ==================================================
// class apis:
// ==================================================

zend_class_entry *
php_init_class_entry_ex(const char *class_name, size_t class_name_len,
                          const zend_function_entry *functions,
                          php_init_class_entry_handler handler,
                          void *argument) {
    zend_class_entry class_ce;
    INIT_CLASS_ENTRY_EX(class_ce, class_name, class_name_len, functions);
    return handler(&class_ce, argument);
}

bool php_instanceof_function(const zend_class_entry *instance_ce,
                               const zend_class_entry *ce) {
    return instanceof_function(instance_ce, ce) != 0;
}

zend_class_entry *php_get_parent_class(zend_class_entry *ce) {
    return ce->parent;
}

// ==================================================
// function apis:
// ==================================================

zend_string *php_get_function_or_method_name(const zend_function *func) {
#if PHP_VERSION_ID >= 80000
    return get_function_or_method_name(func);
#else
    if (func->common.scope) {
        return php_zend_string_concat3(ZSTR_VAL(func->common.scope->name),
                                         ZSTR_LEN(func->common.scope->name),
                                         "::", sizeof("::") - 1,
                                         ZSTR_VAL(func->common.function_name),
                                         ZSTR_LEN(func->common.function_name));
    }
    return func->common.function_name
               ? zend_string_copy(func->common.function_name)
               : zend_string_init("main", sizeof("main") - 1, 0);
#endif
}

zend_string *php_get_function_name(const zend_function *func) {
    return func->common.function_name;
}

bool php_call_user_function(HashTable *function_table, zval *object,
                              zval *function_name, zval *retval_ptr,
                              uint32_t param_count, zval params[]) {
    (void)function_table; // suppress "unused parameter" warnings.
    return call_user_function(function_table, object, function_name, retval_ptr,
                              param_count, params) == SUCCESS;
}

zval *php_zend_call_var_num(zend_execute_data *execute_data, int index) {
    return ZEND_CALL_VAR_NUM(execute_data, index);
}

zval *php_zend_call_arg(zend_execute_data *execute_data, int index) {
    return ZEND_CALL_ARG(execute_data, index);
}

uint32_t php_zend_num_args(const zend_execute_data *execute_data) {
    return ZEND_NUM_ARGS();
}

uint32_t php_zend_call_num_args(const zend_execute_data *execute_data) {
    return ZEND_CALL_NUM_ARGS(execute_data);
}

void php_zend_set_call_num_args(zend_execute_data *execute_data, uint32_t num) {
    ZEND_CALL_NUM_ARGS(execute_data) = num;
}

uint32_t php_zend_call_info(zend_execute_data *execute_data) {
    return ZEND_CALL_INFO(execute_data);
}

void php_zend_add_call_flag(zend_execute_data *execute_data, uint32_t flag) {
    ZEND_ADD_CALL_FLAG(execute_data, flag);
}

bool php_zend_get_parameters_array_ex(uint32_t param_count,
                                        zval *argument_array) {
    return zend_get_parameters_array_ex(param_count, argument_array) == SUCCESS;
}

// int php_zend_parse_parameters(zend_execute_data *execute_data, const char *format, char **str, size_t *str_len) {
//     return zend_parse_parameters(ZEND_NUM_ARGS(), format, str, str_len);
// }

// Variadic, format-driven parser that reads actual zvals via zend_get_parameters_array_ex
int php_zend_parse_parameters(zend_execute_data *execute_data, const char *format, ...) {
    (void)execute_data;
    uint32_t num_args = ZEND_NUM_ARGS();
    uint32_t format_len = (uint32_t)strlen(format);

    /* allocate array for zvals */
    zval *args = NULL;
    if (num_args) {
        args = (zval *)emalloc(sizeof(zval) * num_args);
        if (!args) {
            return FAILURE;
        }
        if (zend_get_parameters_array_ex(num_args, args) != SUCCESS) {
            efree(args);
            return FAILURE;
        }
    }

    va_list ap;
    va_start(ap, format);

    uint32_t ai = 0;
    int rc = FAILURE; /* default failure */

    for (uint32_t fi = 0; fi < format_len; ++fi) {
        char fc = format[fi];
        if (ai >= num_args) {
            rc = FAILURE;
            goto cleanup;
        }
        zval *arg = &args[ai++];

        switch (fc) {
            case 's': {
                char **outstr = va_arg(ap, char **);
                size_t *outlen = va_arg(ap, size_t *);
                /* accept string or coerce */
                if (Z_TYPE_P(arg) != IS_STRING) {
                    /* try to coerce in-place to string (this mutates the original param) */
                    convert_to_string(arg);
                    if (Z_TYPE_P(arg) != IS_STRING) { rc = FAILURE; goto cleanup; }
                }
                *outstr = Z_STRVAL_P(arg);
                *outlen = Z_STRLEN_P(arg);
                break;
            }
            case 'l': {
                zend_long *out = va_arg(ap, zend_long *);
                *out = zval_get_long(arg);
                break;
            }
            case 'd': {
                double *out = va_arg(ap, double *);
                *out = zval_get_double(arg);
                break;
            }
            case 'b': {
                zend_bool *out = va_arg(ap, zend_bool *);
                *out = zval_is_true(arg);
                break;
            }
            case 'a': {
                zval **out = va_arg(ap, zval **);
                if (Z_TYPE_P(arg) != IS_ARRAY) { rc = FAILURE; goto cleanup; }
                *out = arg;
                break;
            }
            case 'o': {
                zval **out = va_arg(ap, zval **);
                if (Z_TYPE_P(arg) != IS_OBJECT) { rc = FAILURE; goto cleanup; }
                *out = arg;
                break;
            }
            case 'O': {
                zval **out = va_arg(ap, zval **);
                zend_class_entry *ce = va_arg(ap, zend_class_entry *);
                if (Z_TYPE_P(arg) != IS_OBJECT) { rc = FAILURE; goto cleanup; }
                if (!instanceof_function(Z_OBJCE_P(arg), ce)) { rc = FAILURE; goto cleanup; }
                *out = arg;
                break;
            }
            default:
                rc = FAILURE;
                goto cleanup;
        }
    }

    /* all matched */
    rc = SUCCESS;

cleanup:
    va_end(ap);
    if (args) efree(args);
    return rc;
}

uint32_t php_zend_call_may_have_undef() {
    return ZEND_CALL_MAY_HAVE_UNDEF;
}

int php_zend_result_success() {
    return SUCCESS;
}

int php_zend_result_failure() {
    return FAILURE;
}

// ==================================================
// memory apis:
// ==================================================

void *php_emalloc(size_t size) {
    return emalloc(size);
}

void php_efree(void *ptr) {
    return efree(ptr);
}

// ==================================================
// module apis:
// ==================================================

const char *php_get_zend_module_build_id() {
    return ZEND_MODULE_BUILD_ID;
}

zend_internal_arg_info
php_zend_begin_arg_info_ex(bool return_reference,
                             uintptr_t required_num_args) {
#define static
#define const
    ZEND_BEGIN_ARG_INFO_EX(info, 0, return_reference, required_num_args)
    ZEND_END_ARG_INFO()
    return info[0];
#undef static
#undef const
}

zend_internal_arg_info
php_zend_begin_arg_with_return_type_info_ex(bool return_reference,
                                              uintptr_t required_num_args,
                                              uint32_t typ, bool allow_null) {
(void)typ;
(void)allow_null;
#define static
#define const
#if PHP_VERSION_ID >= 70400
    ZEND_BEGIN_ARG_WITH_RETURN_TYPE_INFO_EX(info, return_reference, required_num_args, typ, allow_null)
#elif PHP_VERSION_ID >= 70200
    ZEND_BEGIN_ARG_WITH_RETURN_TYPE_INFO_EX(info, return_reference, required_num_args, typ, allow_null)
#else
    ZEND_BEGIN_ARG_INFO_EX(info, 0, return_reference, required_num_args)
#endif
    ZEND_END_ARG_INFO()
    return info[0];
#undef static
#undef const
}


zend_internal_arg_info
php_zend_begin_arg_with_return_obj_info_ex(bool return_reference,
                                             uintptr_t required_num_args,
                                             const char* class_name,
                                             bool allow_null) {
(void)class_name;
(void)allow_null;
#define static
#define const
#if PHP_VERSION_ID >= 80000
    zend_string *zstr = zend_string_init(class_name, strlen(class_name), /*persistent*/ 1);
    //this macro uses class_name as a literal, so we overwrite it immediately
    ZEND_BEGIN_ARG_WITH_RETURN_OBJ_INFO_EX(infos, return_reference, required_num_args, class_name, allow_null)
    ZEND_END_ARG_INFO()
    zend_internal_arg_info info = infos[0];
    #if PHP_VERSION_ID >= 80300
        info.type.ptr = zstr;
    #else
        info.type.ptr = ZSTR_VAL(zstr);
    #endif
    info.type.type_mask = _ZEND_TYPE_NAME_BIT | (allow_null ? MAY_BE_NULL : 0);
    return info;
#else
    ZEND_BEGIN_ARG_INFO_EX(info, 0, return_reference, required_num_args)
    ZEND_END_ARG_INFO()
    return info[0];
#endif

#undef static
#undef const
}

zend_internal_arg_info php_zend_arg_info(bool pass_by_ref, const char *name) {
    zend_internal_arg_info info[] = {ZEND_ARG_INFO(pass_by_ref, )};
    info[0].name = name;
    return info[0];
}

zend_internal_arg_info php_zend_arg_info_with_type(bool pass_by_ref,
                                                    const char *name,
                                                    uint32_t type_hint,
                                                    bool allow_null,
                                                    const char *default_value) {
(void)default_value;
#if PHP_VERSION_ID >= 80000
    zend_internal_arg_info info[] = {
        ZEND_ARG_TYPE_INFO_WITH_DEFAULT_VALUE(pass_by_ref, name, type_hint, allow_null, default_value)
    };
#elif PHP_VERSION_ID >= 70000
    zend_internal_arg_info info[] = {
        ZEND_ARG_TYPE_INFO(pass_by_ref, name, type_hint, allow_null)
    };
#endif
    info[0].name = name;
    return info[0];
}

zend_internal_arg_info php_zend_arg_obj_info(bool pass_by_ref,
                                               const char *name,
                                               const char *class_name,
                                               bool allow_null) {
// suppress "unused parameter" warnings.
(void)name;
(void)class_name;
(void)allow_null;
#if PHP_VERSION_ID >= 80000
    zend_string *zstr = zend_string_init(class_name, strlen(class_name), /*persistent*/ 1);
    //this macro uses name and class_name as literals, so we overwrite them immediately
    zend_internal_arg_info infos[] = {
        ZEND_ARG_OBJ_INFO(pass_by_ref, name, class_name, allow_null)
    };
    zend_internal_arg_info info = infos[0];
    info.name = name;
    #if PHP_VERSION_ID >= 80300
        info.type.ptr = zstr;
    #else
        info.type.ptr = ZSTR_VAL(zstr);
    #endif
    info.type.type_mask = _ZEND_TYPE_NAME_BIT | (allow_null ? MAY_BE_NULL : 0);
    return info;
#elif PHP_VERSION_ID >= 70200
    zend_internal_arg_info info = {
        .name = name,
        .type = 0, // can't encode class type
        .pass_by_reference = pass_by_ref,
        .is_variadic = 0
    };
    return info;
#else
    zend_internal_arg_info info = {
        .name = name,
        .pass_by_reference = pass_by_ref,
    };
    return info;
#endif
}


zend_internal_arg_info *php_arginfo_alloc(size_t argc) {
    // +1 terminator
    return (zend_internal_arg_info *)calloc(argc + 1, sizeof(zend_internal_arg_info));
}

void php_arginfo_set_typed(
    zend_internal_arg_info *info,
    size_t idx,
    bool pass_by_ref,
    const char *name,
    uint32_t type_hint,
    bool allow_null
) {
    info[idx] = php_zend_arg_info_with_type(pass_by_ref, name, type_hint, allow_null, NULL);
}

const zend_internal_arg_info *php_arginfo_finalize(zend_internal_arg_info *info, size_t argc) {
    memset(&info[argc], 0, sizeof(zend_internal_arg_info)); // terminator
    return info;
}

// Exceptions
void php_throw_exception(const char *msg) {
    zend_throw_exception(zend_ce_exception, (char *)msg, 0);
}

void php_throw_type_error(const char *msg) {
    zend_throw_exception(zend_ce_type_error, (char *)msg, 0);
}

uint32_t php_get_IS_STRING() { return IS_STRING; }
uint32_t php_get_IS_LONG()   { return IS_LONG; }
uint32_t php_get_IS_ARRAY()  { return IS_ARRAY; }
uint32_t php_get_IS_OBJECT() { return IS_OBJECT; }
uint32_t php_get_IS_DOUBLE() { return IS_DOUBLE; }