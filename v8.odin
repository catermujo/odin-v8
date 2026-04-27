package v8

import "core:c"
import "core:fmt"
import "core:strings"

Isolate :: distinct rawptr
Context :: distinct rawptr

Error :: struct {
    has_exception: c.int,
    line:          c.int,
    column:        c.int,
    message:       [1024]c.char,
    stack:         [2048]c.char,
}

// DUMBAI: Mirror C callback signatures from cv8.h so Odin can register host functions directly.
Callback_Void :: #type proc "c" (user_data: rawptr)
Callback_Bool :: #type proc "c" (user_data: rawptr) -> c.int
Callback_UTF8 :: #type proc "c" (arg0_utf8: cstring, user_data: rawptr)
Callback_RGBA4 :: #type proc "c" (r, g, b, a: f32, user_data: rawptr)

when ODIN_OS == .Linux {
    when #config(V8_LINK_STATIC, false) {
        // DUMBAI: static mode links staged monolith/support archives from vendor root for reproducible offline builds.
        foreign import cv8 {"libcv8.a", "libv8_monolith.a", "libv8_libbase.a", "libv8_libplatform.a", "system:stdc++", "system:dl", "system:pthread"}
    } else {
        // DUMBAI: shared mode is default so builds avoid carrying the large static monolith in every binary.
        foreign import cv8 "libcv8.so"
    }
} else when ODIN_OS == .Darwin {
    when #config(V8_LINK_STATIC, false) {
        // DUMBAI: static mode links flattened support archives staged by build_cv8.py to avoid Apple ld thin-archive failures.
        foreign import cv8 {"libcv8.a", "libv8_monolith.a", "libv8_libbase.a", "libv8_libplatform.a", "libv8_libcxx.a", "libv8_libcxxabi.a", "system:Foundation.framework", "system:CoreFoundation.framework", "system:Security.framework"}
    } else {
        // DUMBAI: default to dylib linking to cut disk and link pressure while keeping the same Odin API surface.
        foreign import cv8 "libcv8.dylib"
    }
} else when ODIN_OS == .Windows {
    when #config(V8_LINK_STATIC, false) {
        // DUMBAI: static mode links staged .lib artifacts directly and keeps required system libs explicit.
        foreign import cv8 {"cv8.lib", "v8_monolith.lib", "system:dbghelp", "system:winmm"}
    } else {
        // DUMBAI: prefer DLL loading by default so consumers do not link the full static V8 payload.
        foreign import cv8 "cv8.dll"
    }
}

@(default_calling_convention = "c", link_prefix = "cv8_")
foreign cv8 {
    // Process-global V8 lifecycle.
    initialize :: proc(executable_path: cstring, icu_data_path: cstring, startup_data_path: cstring) -> c.int ---
    shutdown :: proc() ---

    // Isolate/context lifecycle.
    isolate_new :: proc() -> Isolate ---
    isolate_dispose :: proc(isolate: Isolate) ---
    context_new :: proc(isolate: Isolate) -> Context ---
    context_dispose :: proc(ctx: Context) ---

    // Compile-run-string pipeline with UTF-8 result extraction.
    run_script_utf8 :: proc(isolate: Isolate, ctx: Context, source_utf8: cstring, source_name_utf8: cstring, out_error: ^Error, out_utf8: [^]c.char, out_utf8_capacity: c.size_t, out_utf8_len: ^c.size_t) -> c.int ---

    // Bind a global stub function that throws when invoked.
    bind_throwing_function_utf8 :: proc(isolate: Isolate, ctx: Context, function_name_utf8: cstring) -> c.int ---
    bind_void_function_utf8 :: proc(isolate: Isolate, ctx: Context, function_name_utf8: cstring, callback: Callback_Void, user_data: rawptr) -> c.int ---
    bind_bool_function_utf8 :: proc(isolate: Isolate, ctx: Context, function_name_utf8: cstring, callback: Callback_Bool, user_data: rawptr) -> c.int ---
    bind_utf8_function_utf8 :: proc(isolate: Isolate, ctx: Context, function_name_utf8: cstring, callback: Callback_UTF8, user_data: rawptr) -> c.int ---
    bind_rgba4_function_utf8 :: proc(isolate: Isolate, ctx: Context, function_name_utf8: cstring, callback: Callback_RGBA4, user_data: rawptr) -> c.int ---

    // Host-controlled microtask pump for promises/jobs.
    perform_microtask_checkpoint :: proc(isolate: Isolate) ---
}

// Boolean wrapper for generated binding registration flow.
bind_throwing_function :: #force_inline proc(isolate: Isolate, ctx: Context, function_name_utf8: cstring) -> bool {
    return bind_throwing_function_utf8(isolate, ctx, function_name_utf8) != 0
}

// DUMBAI: Keep callback bind sites readable by exposing bool-return wrappers beside raw C calls.
bind_void_function :: #force_inline proc(
    isolate: Isolate,
    ctx: Context,
    function_name_utf8: cstring,
    callback: Callback_Void,
    user_data: rawptr = nil,
) -> bool {
    return bind_void_function_utf8(isolate, ctx, function_name_utf8, callback, user_data) != 0
}

bind_bool_function :: #force_inline proc(
    isolate: Isolate,
    ctx: Context,
    function_name_utf8: cstring,
    callback: Callback_Bool,
    user_data: rawptr = nil,
) -> bool {
    return bind_bool_function_utf8(isolate, ctx, function_name_utf8, callback, user_data) != 0
}

bind_utf8_function :: #force_inline proc(
    isolate: Isolate,
    ctx: Context,
    function_name_utf8: cstring,
    callback: Callback_UTF8,
    user_data: rawptr = nil,
) -> bool {
    return bind_utf8_function_utf8(isolate, ctx, function_name_utf8, callback, user_data) != 0
}

bind_rgba4_function :: #force_inline proc(
    isolate: Isolate,
    ctx: Context,
    function_name_utf8: cstring,
    callback: Callback_RGBA4,
    user_data: rawptr = nil,
) -> bool {
    return bind_rgba4_function_utf8(isolate, ctx, function_name_utf8, callback, user_data) != 0
}

v8_quote_js_string_literal :: proc(raw: string) -> string {
    // DUMBAI: escape JS string delimiters so generated namespace bootstrap source stays valid for any proc names.
    escaped, _ := strings.replace_all(raw, "\\", "\\\\", context.temp_allocator)
    escaped, _ = strings.replace_all(escaped, "'", "\\'", context.temp_allocator)
    escaped, _ = strings.replace_all(escaped, "\r", "\\r", context.temp_allocator)
    escaped, _ = strings.replace_all(escaped, "\n", "\\n", context.temp_allocator)
    return fmt.aprintf("'%s'", escaped, allocator = context.temp_allocator)
}

bind_global_functions_into_namespace :: proc(
    isolate: Isolate,
    ctx: Context,
    namespace: string,
    function_names: []string,
) -> bool {
    if len(function_names) == 0 {
        return true
    }

    script := strings.builder_make()
    strings.write_string(&script, "(function(){const __root=globalThis;const __nsPath=")
    strings.write_string(&script, v8_quote_js_string_literal(namespace))
    strings.write_string(
        &script,
        ";const __parts=__nsPath.split('.');let __ns=__root;for(const __part of __parts){if(!__part)continue;const __next=__ns[__part];__ns=(typeof __next==='object'&&__next!==null)?__next:(__ns[__part]=Object.create(null));}",
    )
    for name in function_names {
        name_lit := v8_quote_js_string_literal(name)
        strings.write_string(&script, "if(Object.prototype.hasOwnProperty.call(__root,")
        strings.write_string(&script, name_lit)
        strings.write_string(&script, ")){__ns[")
        strings.write_string(&script, name_lit)
        strings.write_string(&script, "]=__root[")
        strings.write_string(&script, name_lit)
        strings.write_string(&script, "];delete __root[")
        strings.write_string(&script, name_lit)
        strings.write_string(&script, "];}")
    }
    strings.write_string(&script, "})();")

    source := strings.to_string(script)
    source_utf8, cerr := strings.clone_to_cstring(source, context.temp_allocator)
    if cerr != nil {
        return false
    }

    // DUMBAI: run one bootstrap script so generated binders expose only namespaced globals to JS callers.
    source_name := cstring("v8_bindgen_namespace.js")
    err: Error
    if run_script_utf8(isolate, ctx, source_utf8, source_name, &err, nil, 0, nil) == 0 {
        return false
    }
    return true
}
