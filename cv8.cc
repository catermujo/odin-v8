#include "cv8.h"

#include <algorithm>
#include <cstring>
#include <memory>
#include <string>
#include <utility>
#include <vector>

#include "include/libplatform/libplatform.h"
#include "include/v8.h"

// DUMBAI: Complete opaque C handles with concrete C++ state.
struct cv8_isolate {
    v8::Isolate* isolate = nullptr;
    v8::ArrayBuffer::Allocator* allocator = nullptr;
};

// DUMBAI: Store bound callback pointers in context-owned storage so V8 callback data stays valid.
struct cv8_void_callback_binding {
    cv8_callback_void callback = nullptr;
    void* user_data = nullptr;
};

// DUMBAI: Bool callbacks mirror C ABI `int` return to keep FFI behavior explicit.
struct cv8_bool_callback_binding {
    cv8_callback_bool callback = nullptr;
    void* user_data = nullptr;
};

// DUMBAI: UTF-8 callbacks forward one JS string argument to Odin host code.
struct cv8_utf8_callback_binding {
    cv8_callback_utf8 callback = nullptr;
    void* user_data = nullptr;
};

// DUMBAI: RGBA callbacks forward four floats extracted from JS arguments.
struct cv8_rgba4_callback_binding {
    cv8_callback_rgba4 callback = nullptr;
    void* user_data = nullptr;
};

// DUMBAI: Keep isolate ownership and persistent context handle together.
struct cv8_context {
    cv8_isolate* owner = nullptr;
    v8::Global<v8::Context> context;
    std::vector<std::unique_ptr<cv8_void_callback_binding>> void_callbacks;
    std::vector<std::unique_ptr<cv8_bool_callback_binding>> bool_callbacks;
    std::vector<std::unique_ptr<cv8_utf8_callback_binding>> utf8_callbacks;
    std::vector<std::unique_ptr<cv8_rgba4_callback_binding>> rgba4_callbacks;
};

namespace {

// DUMBAI: Keep one process-global platform object because V8 requires singleton lifecycle.
std::unique_ptr<v8::Platform> g_platform;
bool g_v8_initialized = false;
// DUMBAI: Reuse one external-pointer tag because cv8 stores only callback payload pointers in V8 externals.
constexpr v8::ExternalPointerTypeTag k_cv8_external_tag = v8::kExternalPointerTypeTagDefault;

template <size_t N>
void cv8_copy_text(char (&dst)[N], const char* src) {
    if (src == nullptr) {
        dst[0] = '\0';
        return;
    }
    std::strncpy(dst, src, N - 1);
    dst[N - 1] = '\0';
}

void cv8_clear_error(cv8_error* err) {
    if (err == nullptr) {
        return;
    }
    err->has_exception = 0;
    err->line = 0;
    err->column = 0;
    err->message[0] = '\0';
    err->stack[0] = '\0';
}

void cv8_set_error_text(cv8_error* err, const char* text) {
    if (err == nullptr) {
        return;
    }
    err->has_exception = 1;
    cv8_copy_text(err->message, text);
}

void cv8_fill_trycatch_error(cv8_isolate* isolate, cv8_context* context, v8::TryCatch& try_catch, cv8_error* out_error) {
    if (out_error == nullptr || isolate == nullptr || isolate->isolate == nullptr) {
        return;
    }
    cv8_clear_error(out_error);
    out_error->has_exception = 1;

    v8::Isolate* native_isolate = isolate->isolate;
    v8::HandleScope handle_scope(native_isolate);

    v8::String::Utf8Value exception_text(native_isolate, try_catch.Exception());
    cv8_copy_text(out_error->message, *exception_text != nullptr ? *exception_text : "v8 exception");

    if (context == nullptr || context->owner != isolate) {
        return;
    }

    v8::Local<v8::Context> local_context = context->context.Get(native_isolate);
    v8::Local<v8::Message> message = try_catch.Message();
    if (!message.IsEmpty()) {
        out_error->line = message->GetLineNumber(local_context).FromMaybe(0);
        out_error->column = message->GetStartColumn(local_context).FromMaybe(0);
    }

    v8::Local<v8::Value> stack_value;
    if (try_catch.StackTrace(local_context).ToLocal(&stack_value)) {
        v8::String::Utf8Value stack_text(native_isolate, stack_value);
        cv8_copy_text(out_error->stack, *stack_text != nullptr ? *stack_text : "");
    }
}

void cv8_throw_js_error(v8::Isolate* isolate, v8::Local<v8::Value> error) {
    if (isolate == nullptr || error.IsEmpty()) {
        return;
    }
    isolate->ThrowException(error);
}

void cv8_throw_type_error(v8::Isolate* isolate, const char* message) {
    if (isolate == nullptr || message == nullptr) {
        return;
    }
    v8::Local<v8::String> message_string;
    if (!v8::String::NewFromUtf8(isolate, message, v8::NewStringType::kNormal)
             .ToLocal(&message_string)) {
        return;
    }
    cv8_throw_js_error(isolate, v8::Exception::TypeError(message_string));
}

void cv8_throw_error(v8::Isolate* isolate, const char* message) {
    if (isolate == nullptr || message == nullptr) {
        return;
    }
    v8::Local<v8::String> message_string;
    if (!v8::String::NewFromUtf8(isolate, message, v8::NewStringType::kNormal)
             .ToLocal(&message_string)) {
        return;
    }
    cv8_throw_js_error(isolate, v8::Exception::Error(message_string));
}

template <typename T>
T* cv8_get_callback_binding(const v8::FunctionCallbackInfo<v8::Value>& info) {
    if (info.Data().IsEmpty() || !info.Data()->IsExternal()) {
        return nullptr;
    }
    void* value = v8::Local<v8::External>::Cast(info.Data())->Value(k_cv8_external_tag);
    return static_cast<T*>(value);
}

bool cv8_set_global_function(
    v8::Isolate* isolate,
    v8::Local<v8::Context> local_context,
    const char* function_name_utf8,
    v8::FunctionCallback callback,
    v8::Local<v8::Value> callback_data
) {
    if (isolate == nullptr || function_name_utf8 == nullptr || function_name_utf8[0] == '\0') {
        return false;
    }

    v8::Local<v8::String> function_name;
    if (!v8::String::NewFromUtf8(isolate, function_name_utf8, v8::NewStringType::kNormal)
             .ToLocal(&function_name)) {
        return false;
    }

    v8::Local<v8::FunctionTemplate> templ =
        v8::FunctionTemplate::New(isolate, callback, callback_data);
    v8::Local<v8::Function> function;
    if (!templ->GetFunction(local_context).ToLocal(&function)) {
        return false;
    }

    return local_context->Global()->Set(local_context, function_name, function).FromMaybe(false);
}

bool cv8_extract_f32(v8::Local<v8::Context> local_context, v8::Local<v8::Value> value, float* out_value) {
    if (out_value == nullptr || value.IsEmpty()) {
        return false;
    }
    v8::Maybe<double> number = value->NumberValue(local_context);
    if (number.IsNothing()) {
        return false;
    }
    *out_value = static_cast<float>(number.FromJust());
    return true;
}

bool cv8_extract_rgba4(
    const v8::FunctionCallbackInfo<v8::Value>& info,
    v8::Local<v8::Context> local_context,
    float out_rgba[4]
) {
    if (out_rgba == nullptr) {
        return false;
    }

    if (info.Length() == 1 && info[0]->IsArray()) {
        v8::Local<v8::Array> array = v8::Local<v8::Array>::Cast(info[0]);
        if (array->Length() < 4) {
            return false;
        }
        for (uint32_t i = 0; i < 4; ++i) {
            v8::Local<v8::Value> value;
            if (!array->Get(local_context, i).ToLocal(&value)) {
                return false;
            }
            if (!cv8_extract_f32(local_context, value, &out_rgba[i])) {
                return false;
            }
        }
        return true;
    }

    if (info.Length() >= 4) {
        for (int i = 0; i < 4; ++i) {
            if (!cv8_extract_f32(local_context, info[i], &out_rgba[i])) {
                return false;
            }
        }
        return true;
    }

    return false;
}

void cv8_throwing_callback(const v8::FunctionCallbackInfo<v8::Value>& info) {
    v8::Isolate* isolate = info.GetIsolate();
    v8::HandleScope handle_scope(isolate);

    // DUMBAI: Use function name from callback data so generated stubs can share one callback.
    const char* function_name = "<unknown>";
    if (!info.Data().IsEmpty()) {
        v8::String::Utf8Value name_text(isolate, info.Data());
        if (*name_text != nullptr) {
            function_name = *name_text;
        }
    }

    const std::string message =
        std::string("v8 bindgen stub: `") + function_name + "` not implemented";

    cv8_throw_error(isolate, message.c_str());
}

void cv8_void_callback(const v8::FunctionCallbackInfo<v8::Value>& info) {
    v8::Isolate* isolate = info.GetIsolate();
    v8::HandleScope handle_scope(isolate);

    cv8_void_callback_binding* binding = cv8_get_callback_binding<cv8_void_callback_binding>(info);
    if (binding == nullptr || binding->callback == nullptr) {
        cv8_throw_error(isolate, "v8 callback binding unavailable");
        return;
    }

    if (info.Length() != 0) {
        cv8_throw_type_error(isolate, "expected exactly 0 argument(s)");
        return;
    }

    binding->callback(binding->user_data);
}

void cv8_bool_callback(const v8::FunctionCallbackInfo<v8::Value>& info) {
    v8::Isolate* isolate = info.GetIsolate();
    v8::HandleScope handle_scope(isolate);

    cv8_bool_callback_binding* binding = cv8_get_callback_binding<cv8_bool_callback_binding>(info);
    if (binding == nullptr || binding->callback == nullptr) {
        cv8_throw_error(isolate, "v8 callback binding unavailable");
        return;
    }

    if (info.Length() != 0) {
        cv8_throw_type_error(isolate, "expected exactly 0 argument(s)");
        return;
    }

    info.GetReturnValue().Set(binding->callback(binding->user_data) != 0);
}

void cv8_utf8_callback(const v8::FunctionCallbackInfo<v8::Value>& info) {
    v8::Isolate* isolate = info.GetIsolate();
    v8::HandleScope handle_scope(isolate);

    cv8_utf8_callback_binding* binding = cv8_get_callback_binding<cv8_utf8_callback_binding>(info);
    if (binding == nullptr || binding->callback == nullptr) {
        cv8_throw_error(isolate, "v8 callback binding unavailable");
        return;
    }
    if (info.Length() != 1) {
        cv8_throw_type_error(isolate, "expected exactly 1 argument(s)");
        return;
    }

    v8::Local<v8::Context> local_context = isolate->GetCurrentContext();
    v8::Local<v8::String> arg0_string;
    if (!info[0]->ToString(local_context).ToLocal(&arg0_string)) {
        cv8_throw_type_error(isolate, "argument 0 must be string-convertible");
        return;
    }

    v8::String::Utf8Value arg0_utf8(isolate, arg0_string);
    binding->callback(*arg0_utf8 != nullptr ? *arg0_utf8 : "", binding->user_data);
}

void cv8_rgba4_callback(const v8::FunctionCallbackInfo<v8::Value>& info) {
    v8::Isolate* isolate = info.GetIsolate();
    v8::HandleScope handle_scope(isolate);

    cv8_rgba4_callback_binding* binding = cv8_get_callback_binding<cv8_rgba4_callback_binding>(info);
    if (binding == nullptr || binding->callback == nullptr) {
        cv8_throw_error(isolate, "v8 callback binding unavailable");
        return;
    }

    v8::Local<v8::Context> local_context = isolate->GetCurrentContext();
    float rgba[4] = {};
    if (!cv8_extract_rgba4(info, local_context, rgba)) {
        cv8_throw_type_error(isolate, "expected [r,g,b,a] array or four numeric arguments");
        return;
    }

    binding->callback(rgba[0], rgba[1], rgba[2], rgba[3], binding->user_data);
}

}  // namespace

extern "C" {

int cv8_initialize(const char* executable_path, const char* icu_data_path, const char* startup_data_path) {
    if (g_v8_initialized) {
        return 1;
    }

    // DUMBAI: Keep startup defaults explicit so host can override data search paths.
    const char* exec_path = executable_path != nullptr ? executable_path : "";
    const char* startup_path = startup_data_path != nullptr ? startup_data_path : exec_path;

    v8::V8::InitializeICUDefaultLocation(exec_path, icu_data_path);
    v8::V8::InitializeExternalStartupData(startup_path);

    g_platform = v8::platform::NewDefaultPlatform();
    v8::V8::InitializePlatform(g_platform.get());
    if (!v8::V8::Initialize()) {
        g_platform.reset();
        return 0;
    }

    g_v8_initialized = true;
    return 1;
}

void cv8_shutdown(void) {
    if (!g_v8_initialized) {
        return;
    }

    v8::V8::Dispose();
    v8::V8::DisposePlatform();
    g_platform.reset();
    g_v8_initialized = false;
}

cv8_isolate* cv8_isolate_new(void) {
    if (!g_v8_initialized) {
        return nullptr;
    }

    auto* handle = new cv8_isolate();
    handle->allocator = v8::ArrayBuffer::Allocator::NewDefaultAllocator();

    v8::Isolate::CreateParams params;
    params.array_buffer_allocator = handle->allocator;
    handle->isolate = v8::Isolate::New(params);
    if (handle->isolate == nullptr) {
        delete handle->allocator;
        delete handle;
        return nullptr;
    }
    return handle;
}

void cv8_isolate_dispose(cv8_isolate* isolate) {
    if (isolate == nullptr) {
        return;
    }
    if (isolate->isolate != nullptr) {
        isolate->isolate->Dispose();
    }
    delete isolate->allocator;
    delete isolate;
}

cv8_context* cv8_context_new(cv8_isolate* isolate) {
    if (isolate == nullptr || isolate->isolate == nullptr) {
        return nullptr;
    }

    v8::Isolate* native_isolate = isolate->isolate;
    v8::Isolate::Scope isolate_scope(native_isolate);
    v8::HandleScope handle_scope(native_isolate);

    v8::Local<v8::Context> local_context = v8::Context::New(native_isolate);
    if (local_context.IsEmpty()) {
        return nullptr;
    }

    auto* handle = new cv8_context();
    handle->owner = isolate;
    handle->context.Reset(native_isolate, local_context);
    return handle;
}

void cv8_context_dispose(cv8_context* context) {
    if (context == nullptr) {
        return;
    }
    context->context.Reset();
    delete context;
}

int cv8_run_script_utf8(
    cv8_isolate* isolate,
    cv8_context* context,
    const char* source_utf8,
    const char* source_name_utf8,
    cv8_error* out_error,
    char* out_utf8,
    size_t out_utf8_capacity,
    size_t* out_utf8_len
) {
    cv8_clear_error(out_error);
    if (out_utf8_len != nullptr) {
        *out_utf8_len = 0;
    }
    if (out_utf8 != nullptr && out_utf8_capacity > 0) {
        out_utf8[0] = '\0';
    }

    if (isolate == nullptr || isolate->isolate == nullptr || context == nullptr || context->owner != isolate) {
        cv8_set_error_text(out_error, "invalid isolate/context");
        return 0;
    }
    if (source_utf8 == nullptr) {
        cv8_set_error_text(out_error, "source_utf8 is required");
        return 0;
    }

    v8::Isolate* native_isolate = isolate->isolate;
    v8::Isolate::Scope isolate_scope(native_isolate);
    v8::HandleScope handle_scope(native_isolate);
    v8::Local<v8::Context> local_context = context->context.Get(native_isolate);
    v8::Context::Scope context_scope(local_context);
    v8::TryCatch try_catch(native_isolate);

    v8::Local<v8::String> source;
    if (!v8::String::NewFromUtf8(native_isolate, source_utf8, v8::NewStringType::kNormal).ToLocal(&source)) {
        cv8_set_error_text(out_error, "failed to allocate source string");
        return 0;
    }

    // DUMBAI: Preserve source label for stack traces and debugger output.
    const char* source_name = source_name_utf8 != nullptr ? source_name_utf8 : "<odin>";
    v8::Local<v8::String> source_name_string;
    if (!v8::String::NewFromUtf8(native_isolate, source_name, v8::NewStringType::kNormal).ToLocal(&source_name_string)) {
        cv8_set_error_text(out_error, "failed to allocate source name");
        return 0;
    }
    v8::ScriptOrigin origin(source_name_string);

    v8::Local<v8::Script> script;
    if (!v8::Script::Compile(local_context, source, &origin).ToLocal(&script)) {
        cv8_fill_trycatch_error(isolate, context, try_catch, out_error);
        return 0;
    }

    v8::Local<v8::Value> result;
    if (!script->Run(local_context).ToLocal(&result)) {
        cv8_fill_trycatch_error(isolate, context, try_catch, out_error);
        return 0;
    }

    v8::Local<v8::String> result_string;
    if (!result->ToString(local_context).ToLocal(&result_string)) {
        cv8_fill_trycatch_error(isolate, context, try_catch, out_error);
        return 0;
    }

    v8::String::Utf8Value utf8(native_isolate, result_string);
    const char* text = *utf8 != nullptr ? *utf8 : "";
    const size_t text_len = std::strlen(text);

    if (out_utf8_len != nullptr) {
        *out_utf8_len = text_len;
    }
    if (out_utf8 == nullptr) {
        return 1;
    }
    if (out_utf8_capacity == 0) {
        cv8_set_error_text(out_error, "out_utf8_capacity must be > 0 when out_utf8 is provided");
        return 0;
    }
    if (text_len + 1 > out_utf8_capacity) {
        cv8_set_error_text(out_error, "out_utf8 buffer too small");
        return 0;
    }

    std::copy_n(text, text_len, out_utf8);
    out_utf8[text_len] = '\0';
    return 1;
}

int cv8_bind_throwing_function_utf8(
    cv8_isolate* isolate,
    cv8_context* context,
    const char* function_name_utf8
) {
    if (isolate == nullptr || isolate->isolate == nullptr || context == nullptr || context->owner != isolate) {
        return 0;
    }
    if (function_name_utf8 == nullptr || function_name_utf8[0] == '\0') {
        return 0;
    }

    v8::Isolate* native_isolate = isolate->isolate;
    v8::Isolate::Scope isolate_scope(native_isolate);
    v8::HandleScope handle_scope(native_isolate);
    v8::Local<v8::Context> local_context = context->context.Get(native_isolate);
    v8::Context::Scope context_scope(local_context);

    // DUMBAI: Attach one reusable throw callback for every generated binding entry.
    v8::Local<v8::String> function_name;
    if (!v8::String::NewFromUtf8(native_isolate, function_name_utf8, v8::NewStringType::kNormal)
             .ToLocal(&function_name)) {
        return 0;
    }

    return cv8_set_global_function(
               native_isolate,
               local_context,
               function_name_utf8,
               cv8_throwing_callback,
               function_name
           )
               ? 1
               : 0;
}

int cv8_bind_void_function_utf8(
    cv8_isolate* isolate,
    cv8_context* context,
    const char* function_name_utf8,
    cv8_callback_void callback,
    void* user_data
) {
    if (isolate == nullptr || isolate->isolate == nullptr || context == nullptr || context->owner != isolate) {
        return 0;
    }
    if (function_name_utf8 == nullptr || function_name_utf8[0] == '\0' || callback == nullptr) {
        return 0;
    }

    v8::Isolate* native_isolate = isolate->isolate;
    v8::Isolate::Scope isolate_scope(native_isolate);
    v8::HandleScope handle_scope(native_isolate);
    v8::Local<v8::Context> local_context = context->context.Get(native_isolate);
    v8::Context::Scope context_scope(local_context);

    auto binding = std::make_unique<cv8_void_callback_binding>();
    binding->callback = callback;
    binding->user_data = user_data;
    cv8_void_callback_binding* binding_ptr = binding.get();

    // DUMBAI: Keep callback payload alive in context storage for the entire V8 context lifetime.
    v8::Local<v8::External> callback_data = v8::External::New(native_isolate, binding_ptr, k_cv8_external_tag);
    if (!cv8_set_global_function(native_isolate, local_context, function_name_utf8, cv8_void_callback, callback_data)) {
        return 0;
    }
    context->void_callbacks.push_back(std::move(binding));
    return 1;
}

int cv8_bind_bool_function_utf8(
    cv8_isolate* isolate,
    cv8_context* context,
    const char* function_name_utf8,
    cv8_callback_bool callback,
    void* user_data
) {
    if (isolate == nullptr || isolate->isolate == nullptr || context == nullptr || context->owner != isolate) {
        return 0;
    }
    if (function_name_utf8 == nullptr || function_name_utf8[0] == '\0' || callback == nullptr) {
        return 0;
    }

    v8::Isolate* native_isolate = isolate->isolate;
    v8::Isolate::Scope isolate_scope(native_isolate);
    v8::HandleScope handle_scope(native_isolate);
    v8::Local<v8::Context> local_context = context->context.Get(native_isolate);
    v8::Context::Scope context_scope(local_context);

    auto binding = std::make_unique<cv8_bool_callback_binding>();
    binding->callback = callback;
    binding->user_data = user_data;
    cv8_bool_callback_binding* binding_ptr = binding.get();

    // DUMBAI: Hold bool callback payload by context so rebinding remains safe.
    v8::Local<v8::External> callback_data = v8::External::New(native_isolate, binding_ptr, k_cv8_external_tag);
    if (!cv8_set_global_function(native_isolate, local_context, function_name_utf8, cv8_bool_callback, callback_data)) {
        return 0;
    }
    context->bool_callbacks.push_back(std::move(binding));
    return 1;
}

int cv8_bind_utf8_function_utf8(
    cv8_isolate* isolate,
    cv8_context* context,
    const char* function_name_utf8,
    cv8_callback_utf8 callback,
    void* user_data
) {
    if (isolate == nullptr || isolate->isolate == nullptr || context == nullptr || context->owner != isolate) {
        return 0;
    }
    if (function_name_utf8 == nullptr || function_name_utf8[0] == '\0' || callback == nullptr) {
        return 0;
    }

    v8::Isolate* native_isolate = isolate->isolate;
    v8::Isolate::Scope isolate_scope(native_isolate);
    v8::HandleScope handle_scope(native_isolate);
    v8::Local<v8::Context> local_context = context->context.Get(native_isolate);
    v8::Context::Scope context_scope(local_context);

    auto binding = std::make_unique<cv8_utf8_callback_binding>();
    binding->callback = callback;
    binding->user_data = user_data;
    cv8_utf8_callback_binding* binding_ptr = binding.get();

    // DUMBAI: Store callback context object so UTF-8 callback data remains valid after binding call returns.
    v8::Local<v8::External> callback_data = v8::External::New(native_isolate, binding_ptr, k_cv8_external_tag);
    if (!cv8_set_global_function(native_isolate, local_context, function_name_utf8, cv8_utf8_callback, callback_data)) {
        return 0;
    }
    context->utf8_callbacks.push_back(std::move(binding));
    return 1;
}

int cv8_bind_rgba4_function_utf8(
    cv8_isolate* isolate,
    cv8_context* context,
    const char* function_name_utf8,
    cv8_callback_rgba4 callback,
    void* user_data
) {
    if (isolate == nullptr || isolate->isolate == nullptr || context == nullptr || context->owner != isolate) {
        return 0;
    }
    if (function_name_utf8 == nullptr || function_name_utf8[0] == '\0' || callback == nullptr) {
        return 0;
    }

    v8::Isolate* native_isolate = isolate->isolate;
    v8::Isolate::Scope isolate_scope(native_isolate);
    v8::HandleScope handle_scope(native_isolate);
    v8::Local<v8::Context> local_context = context->context.Get(native_isolate);
    v8::Context::Scope context_scope(local_context);

    auto binding = std::make_unique<cv8_rgba4_callback_binding>();
    binding->callback = callback;
    binding->user_data = user_data;
    cv8_rgba4_callback_binding* binding_ptr = binding.get();

    // DUMBAI: Keep RGBA callback payload alive so JS draw loop can invoke begin_draw every frame.
    v8::Local<v8::External> callback_data = v8::External::New(native_isolate, binding_ptr, k_cv8_external_tag);
    if (!cv8_set_global_function(native_isolate, local_context, function_name_utf8, cv8_rgba4_callback, callback_data)) {
        return 0;
    }
    context->rgba4_callbacks.push_back(std::move(binding));
    return 1;
}

void cv8_perform_microtask_checkpoint(cv8_isolate* isolate) {
    if (isolate == nullptr || isolate->isolate == nullptr) {
        return;
    }
    isolate->isolate->PerformMicrotaskCheckpoint();
}

}  // extern "C"
