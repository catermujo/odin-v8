#ifndef CV8_H_
#define CV8_H_

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

// DUMBAI: Keep all V8 C++ objects opaque so Odin only sees stable C pointers.
typedef struct cv8_isolate cv8_isolate;
typedef struct cv8_context cv8_context;

// DUMBAI: Fixed-size buffers avoid allocator ownership crossing FFI boundary.
typedef struct cv8_error {
    int has_exception;
    int line;
    int column;
    char message[1024];
    char stack[2048];
} cv8_error;

// DUMBAI: Minimal host-callback signatures used by Odin examples that need real V8-executed behavior.
typedef void (*cv8_callback_void)(void* user_data);
typedef int (*cv8_callback_bool)(void* user_data);
typedef void (*cv8_callback_utf8)(const char* arg0_utf8, void* user_data);
typedef void (*cv8_callback_rgba4)(float r, float g, float b, float a, void* user_data);

// DUMBAI: Initialize process-global V8 state once before creating isolates.
int cv8_initialize(const char* executable_path, const char* icu_data_path, const char* startup_data_path);

// DUMBAI: Shutdown process-global V8 state after all isolates are disposed.
void cv8_shutdown(void);

// DUMBAI: Create isolate with default array-buffer allocator owned by shim.
cv8_isolate* cv8_isolate_new(void);

// DUMBAI: Dispose isolate and its allocator in one call to keep ownership simple.
void cv8_isolate_dispose(cv8_isolate* isolate);

// DUMBAI: Create one JS context bound to isolate.
cv8_context* cv8_context_new(cv8_isolate* isolate);

// DUMBAI: Dispose persistent context handle allocated by shim.
void cv8_context_dispose(cv8_context* context);

// DUMBAI: Compile+run UTF-8 script and stringify result into caller buffer.
int cv8_run_script_utf8(
    cv8_isolate* isolate,
    cv8_context* context,
    const char* source_utf8,
    const char* source_name_utf8,
    cv8_error* out_error,
    char* out_utf8,
    size_t out_utf8_capacity,
    size_t* out_utf8_len
);

// DUMBAI: Bind a global function that throws a standard "not implemented" error when called.
int cv8_bind_throwing_function_utf8(
    cv8_isolate* isolate,
    cv8_context* context,
    const char* function_name_utf8
);

// DUMBAI: Bind no-argument callback returning undefined.
int cv8_bind_void_function_utf8(
    cv8_isolate* isolate,
    cv8_context* context,
    const char* function_name_utf8,
    cv8_callback_void callback,
    void* user_data
);

// DUMBAI: Bind no-argument callback returning JS boolean.
int cv8_bind_bool_function_utf8(
    cv8_isolate* isolate,
    cv8_context* context,
    const char* function_name_utf8,
    cv8_callback_bool callback,
    void* user_data
);

// DUMBAI: Bind single-string-argument callback returning undefined.
int cv8_bind_utf8_function_utf8(
    cv8_isolate* isolate,
    cv8_context* context,
    const char* function_name_utf8,
    cv8_callback_utf8 callback,
    void* user_data
);

// DUMBAI: Bind RGBA callback accepting either one `[r,g,b,a]` array or four numeric args.
int cv8_bind_rgba4_function_utf8(
    cv8_isolate* isolate,
    cv8_context* context,
    const char* function_name_utf8,
    cv8_callback_rgba4 callback,
    void* user_data
);

// DUMBAI: Expose explicit microtask pump for host-driven runtimes.
void cv8_perform_microtask_checkpoint(cv8_isolate* isolate);

#ifdef __cplusplus
}
#endif

#endif  // CV8_H_
