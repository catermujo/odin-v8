package main

import "core:fmt"
import ast "core:odin/ast"
import parser "core:odin/parser"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"

GEN_FILE_NAME :: "v8_bindings.generated.odin"
GEN_DTS_FILE_NAME :: "v8_bindings.generated.d.ts"
SPEC_FILE_NAME :: "v8_bindgen.spec"

Binding_Mode :: enum u8 {
    stub,
    void,
    bool,
    utf8,
    rgba4,
}

Proc_Info :: struct {
    symbol:      string,
    params:      []Param_Info,
    results:     []Result_Info,
    diverging:   bool,
    generic:     bool,
    invalid:     bool,
    invalid_msg: string,
}

Param_Info :: struct {
    name:            string,
    odin_type:       string,
    runtime_exposed: bool,
    has_default:     bool,
    unsupported:     bool,
    unsupported_msg: string,
}

Result_Info :: struct {
    odin_type:       string,
    unsupported:     bool,
    unsupported_msg: string,
}

Specialize_Directive :: struct {
    symbol:   string,
    js_name:  string,
    bindings: map[string]string,
    line:     int,
}

Spec_Config :: struct {
    target_import_alias: string,
    excludes:            map[string]bool,
    renames:             map[string]string,
    specializes:         [dynamic]Specialize_Directive,
}

Named_Type_Kind :: enum u8 {
    Alias,
    Struct,
    Enum,
    Bit_Set,
}

Named_Type_Field :: struct {
    name:      string,
    odin_type: string,
}

Named_Type_Def :: struct {
    name:      string,
    kind:      Named_Type_Kind,
    odin_type: string,
    fields:    []Named_Type_Field,
}

TS_Render_Context :: struct {
    named_defs:       map[string]Named_Type_Def,
    named_ts_exprs:   map[string]string,
    named_alias_name: map[string]string,
    resolving_named:  map[string]bool,
}

Binding_Info :: struct {
    symbol:             string,
    js_name:            string,
    wrapper_name:       string,
    mode:               Binding_Mode,
    params:             []Param_Info,
    results:            []Result_Info,
    diverging:          bool,
    supported:          bool,
    unsupported_reason: string,
}

print_usage :: proc() {
    fmt.eprintln("Usage: odin run bindgen.odin -file -- <lib-name-or-path>")
    fmt.eprintln("Example: odin run bindgen.odin -file -- ./path/to/module")
    fmt.eprintln("Example: odin run bindgen.odin -file -- ../game/runtime")
}

is_ascii_letter :: proc(c: byte) -> bool {
    return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')
}

is_ascii_digit :: proc(c: byte) -> bool {
    return c >= '0' && c <= '9'
}

sanitize_identifier :: proc(raw: string) -> string {
    if len(raw) == 0 do return "sym"
    out := make([dynamic]byte, 0, len(raw) + 1)
    for i := 0; i < len(raw); i += 1 {
        c := raw[i]
        if !is_ascii_letter(c) && !is_ascii_digit(c) && c != '_' {
            c = '_'
        }
        if i == 0 && is_ascii_digit(c) {
            append(&out, '_')
        }
        append(&out, c)
    }
    if len(out) == 0 {
        append(&out, 's', 'y', 'm')
    }
    return string(out[:])
}

mode_suffix :: proc(mode: Binding_Mode) -> string {
    switch mode {
    case .stub:
        return "stub"
    case .void:
        return "void"
    case .bool:
        return "bool"
    case .utf8:
        return "utf8"
    case .rgba4:
        return "rgba4"
    }
    return "stub"
}

quote_odin_string :: proc(raw: string) -> string {
    escaped, _ := strings.replace_all(raw, "\\", "\\\\", context.allocator)
    escaped, _ = strings.replace_all(escaped, "\"", "\\\"", context.allocator)
    return fmt.aprintf("\"%s\"", escaped, allocator = context.allocator)
}

quote_ts_string :: proc(raw: string) -> string {
    escaped, _ := strings.replace_all(raw, "\\", "\\\\", context.allocator)
    escaped, _ = strings.replace_all(escaped, "\"", "\\\"", context.allocator)
    return fmt.aprintf("\"%s\"", escaped, allocator = context.allocator)
}

to_pascal_identifier :: proc(raw: string) -> string {
    clean := sanitize_identifier(raw)
    if len(clean) == 0 {
        return "Bindings"
    }
    out := make([dynamic]byte, 0, len(clean))
    for i := 0; i < len(clean); i += 1 {
        c := clean[i]
        if i == 0 && c >= 'a' && c <= 'z' {
            append(&out, c - ('a' - 'A'))
            continue
        }
        append(&out, c)
    }
    return string(out[:])
}

join2 :: proc(a, b: string) -> (string, bool) {
    parts := [2]string{a, b}
    joined, err := filepath.join(parts[:])
    if err != nil {
        return "", false
    }
    return joined, true
}

resolve_module_path :: proc(lib_arg: string) -> (module_abs, module_name: string, ok: bool) {
    resolved_abs, abs_err := os.get_absolute_path(lib_arg, context.allocator)
    if abs_err != nil {
        fmt.eprintf("v8_bindgen: failed to resolve path '%s': %v\n", lib_arg, abs_err)
        return
    }
    module_abs = resolved_abs
    if !os.exists(module_abs) || !os.is_directory(module_abs) {
        fmt.eprintf("v8_bindgen: module path does not exist or is not a directory: %s\n", module_abs)
        return
    }
    module_name = filepath.base(module_abs)
    ok = true
    return
}

derive_default_namespace_root :: proc(module_abs: string) -> string {
    // DUMBAI: infer namespace root from module parent folder to keep bindgen independent from monorepo naming.
    parent_dir := filepath.dir(module_abs)
    root := sanitize_identifier(filepath.base(parent_dir))
    if root == "" {
        root = "bindings"
    }
    return root
}

resolve_generator_v8_root :: proc(loc := #caller_location) -> (v8_root_abs: string, ok: bool) {
    source_file_abs, abs_err := os.get_absolute_path(loc.file_path, context.allocator)
    if abs_err != nil {
        fmt.eprintf("v8_bindgen: failed to resolve generator source path '%s': %v\n", loc.file_path, abs_err)
        return
    }

    scripts_dir := filepath.dir(source_file_abs)
    v8_root_abs = filepath.dir(scripts_dir)
    if !os.exists(v8_root_abs) || !os.is_directory(v8_root_abs) {
        fmt.eprintf("v8_bindgen: resolved V8 root is not a directory: %s\n", v8_root_abs)
        return
    }

    ok = true
    return
}

resolve_v8_import :: proc(module_abs: string, v8_root_abs: string) -> (v8_import: string, ok: bool) {
    rel_path, rel_err := filepath.rel(module_abs, v8_root_abs, context.allocator)
    if rel_err != .None {
        fmt.eprintf("v8_bindgen: failed to compute import path from %s to %s\n", module_abs, v8_root_abs)
        return
    }
    normalized, _ := strings.replace_all(rel_path, "\\", "/", context.allocator)
    v8_import = normalized
    ok = true
    return
}

is_generated_source_file :: proc(name: string) -> bool {
    return strings.has_suffix(name, ".generated.odin")
}

extract_expr_text :: proc(src: string, expr: ^ast.Expr) -> string {
    if expr == nil do return ""
    start := clamp(expr.pos.offset, 0, len(src))
    end := clamp(expr.end.offset, start, len(src))
    return strings.trim_space(src[start:end])
}

extract_attribute_text :: proc(src: string, attribute: ^ast.Attribute) -> string {
    if attribute == nil do return ""
    start := clamp(attribute.pos.offset, 0, len(src))
    end := clamp(attribute.end.offset, start, len(src))
    return strings.trim_space(src[start:end])
}

compact_type_text :: proc(type_text: string) -> string {
    out := make([dynamic]byte, 0, len(type_text))
    for i := 0; i < len(type_text); i += 1 {
        if i + 1 < len(type_text) && type_text[i] == '/' && type_text[i + 1] == '/' {
            i += 2
            for i < len(type_text) && type_text[i] != '\n' {
                i += 1
            }
            i -= 1
            continue
        }
        if i + 1 < len(type_text) && type_text[i] == '/' && type_text[i + 1] == '*' {
            i += 2
            for i + 1 < len(type_text) {
                if type_text[i] == '*' && type_text[i + 1] == '/' {
                    i += 1
                    break
                }
                i += 1
            }
            continue
        }

        c := type_text[i]
        if c == ' ' || c == '\t' || c == '\n' || c == '\r' {
            continue
        }
        append(&out, c)
    }
    return string(out[:])
}

count_field_instances :: proc(field: ^ast.Field) -> int {
    if field == nil do return 0
    if len(field.names) == 0 do return 1
    return len(field.names)
}

field_instance_name :: proc(field: ^ast.Field, idx, fallback_idx: int) -> string {
    if field != nil && idx < len(field.names) {
        if name, ok := extract_ident_name(field.names[idx]); ok {
            return name
        }
    }
    return fmt.aprintf("p%d", fallback_idx, allocator = context.allocator)
}

field_is_comptime :: proc(src: string, field: ^ast.Field) -> bool {
    if field == nil {
        return false
    }
    if .Typeid_Token in field.flags {
        return true
    }
    if field.type != nil {
        if _, is_poly := field.type.derived.(^ast.Poly_Type); is_poly {
            return true
        }
    }
    for name_expr in field.names {
        if name_expr == nil {
            continue
        }
        ident, is_ident := name_expr.derived.(^ast.Ident)
        if is_ident && ident != nil && strings.has_prefix(ident.name, "$") {
            return true
        }
        if _, is_poly := name_expr.derived.(^ast.Poly_Type); is_poly {
            return true
        }
    }

    if field.type != nil {
        start := clamp(field.pos.offset, 0, len(src))
        finish := clamp(field.type.pos.offset, start, len(src))
        prefix := src[start:finish]
        if strings.contains(prefix, "$") {
            return true
        }
    }
    return false
}

is_implicit_default :: proc(default_expr: string) -> bool {
    if default_expr == "" {
        return false
    }
    if strings.contains(default_expr, "#caller_location") {
        return true
    }
    if strings.contains(default_expr, "context.") && strings.contains(default_expr, "allocator") {
        return true
    }
    return false
}

contains_unmappable_text :: proc(type_text: string) -> (bool, string) {
    t := compact_type_text(type_text)
    if strings.contains(t, "$") {
        return true, "polymorphic types require explicit specialization"
    }
    if strings.has_prefix(t, "proc") {
        return true, "procedure types are not auto-bindable"
    }
    if strings.has_prefix(t, "map[") {
        return true, "map types are not auto-bindable"
    }
    if strings.has_prefix(t, "union") {
        return true, "union types are not auto-bindable"
    }
    return false, ""
}

decl_has_private_attribute :: proc(file: ^ast.File, decl: ^ast.Value_Decl) -> bool {
    if decl == nil {
        return false
    }
    for attribute in decl.attributes {
        if attribute == nil {
            continue
        }
        attribute_text := extract_attribute_text(file.src, attribute)
        if strings.contains(attribute_text, "private") {
            return true
        }
    }
    return false
}

analyze_params :: proc(
    file: ^ast.File,
    proc_type: ^ast.Proc_Type,
) -> (
    params: []Param_Info,
    invalid: bool,
    invalid_msg: string,
) {
    params_dyn := make([dynamic]Param_Info)
    if proc_type == nil || proc_type.params == nil {
        return params_dyn[:], false, ""
    }

    auto_idx := 0
    for field in proc_type.params.list {
        if field == nil {
            continue
        }

        if .Ellipsis in field.flags || .C_Vararg in field.flags {
            invalid = true
            invalid_msg = "variadic parameters are not supported"
        }

        if field.type == nil {
            has_default := field.default_value != nil
            default_expr := strings.trim_space(extract_expr_text(file.src, field.default_value))
            implicit := has_default && is_implicit_default(default_expr)
            if implicit {
                repeats := count_field_instances(field)
                for i := 0; i < repeats; i += 1 {
                    raw_name := field_instance_name(field, i, auto_idx)
                    // DUMBAI: implicit call-site defaults (e.g. `loc := #caller_location`) stay hidden from JS signatures.
                    append(
                        &params_dyn,
                        Param_Info {
                            name = raw_name,
                            odin_type = "",
                            runtime_exposed = false,
                            has_default = true,
                            unsupported = false,
                            unsupported_msg = "",
                        },
                    )
                    auto_idx += 1
                }
                continue
            }
            invalid = true
            invalid_msg = "parameter missing type"
            continue
        }

        type_text := compact_type_text(extract_expr_text(file.src, field.type))
        if strings.has_prefix(type_text, "..") {
            invalid = true
            invalid_msg = "variadic parameters are not supported"
        }
        if field.type != nil {
            prefix_start := clamp(field.pos.offset, 0, len(file.src))
            prefix_end := clamp(field.type.pos.offset, prefix_start, len(file.src))
            if strings.contains(file.src[prefix_start:prefix_end], "..") {
                invalid = true
                invalid_msg = "variadic parameters are not supported"
            }
        }
        has_default := field.default_value != nil
        default_expr := strings.trim_space(extract_expr_text(file.src, field.default_value))
        implicit := has_default && is_implicit_default(default_expr)
        comptime := field_is_comptime(file.src, field)
        unsupported_type, unsupported_msg := contains_unmappable_text(type_text)

        repeats := count_field_instances(field)
        for i := 0; i < repeats; i += 1 {
            raw_name := field_instance_name(field, i, auto_idx)
            runtime_exposed := !comptime && !implicit
            append(
                &params_dyn,
                Param_Info {
                    name = raw_name,
                    odin_type = type_text,
                    runtime_exposed = runtime_exposed,
                    has_default = has_default,
                    unsupported = unsupported_type,
                    unsupported_msg = unsupported_msg,
                },
            )
            auto_idx += 1
        }
    }
    params = params_dyn[:]
    return
}

analyze_results :: proc(
    file: ^ast.File,
    proc_type: ^ast.Proc_Type,
) -> (
    results: []Result_Info,
    invalid: bool,
    invalid_msg: string,
) {
    results_dyn := make([dynamic]Result_Info)
    if proc_type == nil || proc_type.results == nil {
        return results_dyn[:], false, ""
    }

    for field in proc_type.results.list {
        if field == nil {
            continue
        }
        if field.type == nil {
            invalid = true
            invalid_msg = "result missing type"
            continue
        }

        type_text := compact_type_text(extract_expr_text(file.src, field.type))
        unsupported_type, unsupported_msg := contains_unmappable_text(type_text)
        repeats := count_field_instances(field)
        for _ in 0 ..< repeats {
            append(
                &results_dyn,
                Result_Info{odin_type = type_text, unsupported = unsupported_type, unsupported_msg = unsupported_msg},
            )
        }
    }
    results = results_dyn[:]
    return
}

is_ts_identifier :: proc(raw: string) -> bool {
    if len(raw) == 0 do return false
    first := raw[0]
    if !(is_ascii_letter(first) || first == '_' || first == '$') {
        return false
    }
    for i := 1; i < len(raw); i += 1 {
        c := raw[i]
        if !(is_ascii_letter(c) || is_ascii_digit(c) || c == '_' || c == '$') {
            return false
        }
    }
    return true
}

ts_param_name :: proc(raw: string, fallback: string) -> string {
    cleaned := raw
    if strings.has_prefix(cleaned, "$") {
        cleaned = cleaned[1:]
    }
    out := sanitize_identifier(cleaned)
    if out == "" || out == "_" || !is_ts_identifier(out) {
        out = sanitize_identifier(fallback)
    }
    if out == "" || out == "_" || !is_ts_identifier(out) {
        out = "arg"
    }
    return out
}

contains_substring :: proc(text, needle: string) -> bool {
    if len(needle) == 0 do return true
    if len(needle) > len(text) do return false
    for i := 0; i + len(needle) <= len(text); i += 1 {
        if text[i:i + len(needle)] == needle {
            return true
        }
    }
    return false
}

parse_odin_fixed_array_type :: proc(text: string) -> (count_text, elem: string, ok: bool) {
    if len(text) < 3 || text[0] != '[' {
        return
    }

    close_idx := -1
    for i := 1; i < len(text); i += 1 {
        if text[i] == ']' {
            close_idx = i
            break
        }
    }
    if close_idx < 0 || close_idx + 1 >= len(text) {
        return
    }

    count_text = strings.trim_space(text[1:close_idx])
    elem = strings.trim_space(text[close_idx + 1:])
    ok = count_text != "" && elem != ""
    return
}

parse_odin_matrix_type :: proc(text: string) -> (rows_text, cols_text, elem: string, ok: bool) {
    if !strings.has_prefix(text, "matrix[") {
        return
    }

    start := len("matrix[")
    close_idx := -1
    for i := start; i < len(text); i += 1 {
        if text[i] == ']' {
            close_idx = i
            break
        }
    }
    if close_idx < 0 || close_idx + 1 >= len(text) {
        return
    }

    dims := strings.trim_space(text[start:close_idx])
    comma := strings.index(dims, ",")
    if comma <= 0 || comma >= len(dims) - 1 {
        return
    }

    rows_text = strings.trim_space(dims[:comma])
    cols_text = strings.trim_space(dims[comma + 1:])
    elem = strings.trim_space(text[close_idx + 1:])
    ok = rows_text != "" && cols_text != "" && elem != ""
    return
}

parse_decimal_int :: proc(text: string) -> (value: int, ok: bool) {
    t := strings.trim_space(text)
    if t == "" {
        return
    }
    for i := 0; i < len(t); i += 1 {
        c := t[i]
        if !is_ascii_digit(c) {
            return
        }
        value = value * 10 + int(c - '0')
    }
    ok = true
    return
}

ts_tuple_type :: proc(elem_ts: string, count: int) -> string {
    if count <= 0 {
        return "[]"
    }
    if count > 32 {
        // DUMBAI: TypeScript tuple literals beyond 32 items are noisy; degrade large fixed arrays to Array<T>.
        return fmt.aprintf("Array<%s>", elem_ts, allocator = context.allocator)
    }
    parts := make([dynamic]string, 0, count)
    for _ in 0 ..< count {
        append(&parts, elem_ts)
    }
    return fmt.aprintf("[%s]", join_csv(parts[:]), allocator = context.allocator)
}

is_odin_identifier :: proc(raw: string) -> bool {
    if len(raw) == 0 {
        return false
    }
    first := raw[0]
    if !(is_ascii_letter(first) || first == '_') {
        return false
    }
    for i := 1; i < len(raw); i += 1 {
        c := raw[i]
        if !(is_ascii_letter(c) || is_ascii_digit(c) || c == '_') {
            return false
        }
    }
    return true
}

ts_alias_name_for_odin :: proc(name: string, ts_ctx: ^TS_Render_Context) -> string {
    if ts_ctx == nil {
        return name
    }
    if alias, ok := ts_ctx.named_alias_name[name]; ok {
        return alias
    }

    alias := name
    if !is_ts_identifier(alias) {
        alias = sanitize_identifier(alias)
    }
    if alias == "" || !is_ts_identifier(alias) {
        alias = fmt.aprintf("Odin_%s", sanitize_identifier(name), allocator = context.allocator)
    }
    ts_ctx.named_alias_name[name] = alias
    return alias
}

ts_guess_named_type :: proc(name: string) -> (ts: string, ok: bool) {
    if strings.has_suffix(name, "vec2") || name == "vec2" {
        return "[number, number]", true
    }
    if strings.has_suffix(name, "vec3") || name == "vec3" {
        return "[number, number, number]", true
    }
    if strings.has_suffix(name, "vec4") || name == "vec4" {
        return "[number, number, number, number]", true
    }
    if strings.has_suffix(name, "mat2") || name == "mat2" {
        return "[number, number, number, number]", true
    }
    if strings.has_suffix(name, "mat3") || name == "mat3" {
        return "[number, number, number, number, number, number, number, number, number]", true
    }
    if strings.has_suffix(name, "mat4") || name == "mat4" {
        return "[number, number, number, number, number, number, number, number, number, number, number, number, number, number, number, number]",
            true
    }
    if name == "Color" || strings.has_suffix(name, "Color") {
        return "[number, number, number, number]", true
    }
    if name == "Rect" || strings.has_suffix(name, "Rect") {
        return "{ pos: [number, number]; size: [number, number] }", true
    }
    return "", false
}

ensure_named_ts_type :: proc(name: string, ts_ctx: ^TS_Render_Context) -> string {
    if ts_ctx == nil {
        if guessed, ok := ts_guess_named_type(name); ok {
            return guessed
        }
        return "JscObject"
    }

    alias_name := ts_alias_name_for_odin(name, ts_ctx)
    if _, exists := ts_ctx.named_ts_exprs[alias_name]; exists {
        return alias_name
    }

    if resolving, exists := ts_ctx.resolving_named[name]; exists && resolving {
        // DUMBAI: break recursive aliases by degrading the cycle edge to unknown.
        ts_ctx.named_ts_exprs[alias_name] = "unknown"
        return alias_name
    }
    ts_ctx.resolving_named[name] = true

    expr := ""
    if guessed, ok := ts_guess_named_type(name); ok {
        expr = guessed
    } else if def, ok := ts_ctx.named_defs[name]; ok {
        switch def.kind {
        case .Enum, .Bit_Set:
            expr = "number"

        case .Struct:
            if len(def.fields) == 0 {
                expr = "JscObject"
            } else {
                fields := make([dynamic]string)
                for field in def.fields {
                    field_name := field.name
                    if !is_ts_identifier(field_name) {
                        field_name = quote_odin_string(field_name)
                    }
                    field_type := map_odin_type_to_ts(field.odin_type, ts_ctx)
                    append(&fields, fmt.aprintf("%s: %s", field_name, field_type, allocator = context.allocator))
                }
                expr_builder := strings.builder_make()
                // DUMBAI: avoid formatter brace parsing edge-cases when emitting TS object literal types.
                strings.write_string(&expr_builder, "{ ")
                strings.write_string(&expr_builder, join_csv(fields[:]))
                strings.write_string(&expr_builder, " }")
                expr = strings.to_string(expr_builder)
            }

        case .Alias:
            expr = map_odin_type_to_ts(def.odin_type, ts_ctx)
            if expr == alias_name {
                expr = "unknown"
            }
        }
    } else {
        expr = "JscObject"
    }

    if expr == "" {
        expr = "unknown"
    }

    ts_ctx.named_ts_exprs[alias_name] = expr
    ts_ctx.resolving_named[name] = false
    return alias_name
}

map_odin_type_to_ts :: proc(odin_type: string, ts_ctx: ^TS_Render_Context) -> string {
    t := compact_type_text(strings.trim_space(odin_type))
    if t == "" {
        return "unknown"
    }

    if strings.has_prefix(t, "distinct") {
        rest := strings.trim_space(t[len("distinct"):])
        if rest != "" {
            return map_odin_type_to_ts(rest, ts_ctx)
        }
    }

    if t == "bool" do return "boolean"
    if t == "string" || t == "cstring" do return "string"
    if t == "rawptr" do return "JscOpaqueHandle<\"rawptr\"> | null"

    if t == "byte" ||
       t == "rune" ||
       t == "i8" ||
       t == "i16" ||
       t == "i32" ||
       t == "i64" ||
       t == "i128" ||
       t == "int" ||
       t == "u8" ||
       t == "u16" ||
       t == "u32" ||
       t == "u64" ||
       t == "u128" ||
       t == "uint" ||
       t == "uintptr" ||
       t == "f16" ||
       t == "f32" ||
       t == "f64" ||
       t == "complex64" ||
       t == "complex128" ||
       t == "quaternion128" ||
       t == "quaternion256" {
        return "number"
    }

    if strings.has_prefix(t, "^") {
        pointee := strings.trim_space(t[1:])
        if pointee == "" {
            pointee = "rawptr"
        }
        return fmt.aprintf("JscOpaqueHandle<%s> | null", quote_odin_string(pointee), allocator = context.allocator)
    }
    if strings.has_prefix(t, "[^]") {
        pointee := strings.trim_space(t[len("[^]"):])
        if pointee == "" {
            pointee = "rawptr"
        }
        return fmt.aprintf("JscOpaqueHandle<%s> | null", quote_odin_string(pointee), allocator = context.allocator)
    }

    if strings.has_prefix(t, "[]u8") {
        return "Uint8Array | number[]"
    }
    if strings.has_prefix(t, "[]") {
        elem_ts := map_odin_type_to_ts(strings.trim_space(t[2:]), ts_ctx)
        return fmt.aprintf("Array<%s>", elem_ts, allocator = context.allocator)
    }

    if count_text, elem, ok := parse_odin_fixed_array_type(t); ok {
        elem_ts := map_odin_type_to_ts(elem, ts_ctx)
        if count, is_numeric := parse_decimal_int(count_text); is_numeric {
            return ts_tuple_type(elem_ts, count)
        }
        return fmt.aprintf("Array<%s>", elem_ts, allocator = context.allocator)
    }

    if rows_text, cols_text, elem, ok := parse_odin_matrix_type(t); ok {
        elem_ts := map_odin_type_to_ts(elem, ts_ctx)
        rows, rows_ok := parse_decimal_int(rows_text)
        cols, cols_ok := parse_decimal_int(cols_text)
        if rows_ok && cols_ok {
            return ts_tuple_type(elem_ts, rows * cols)
        }
        return fmt.aprintf("Array<%s>", elem_ts, allocator = context.allocator)
    }

    if strings.has_prefix(t, "enum") || strings.has_prefix(t, "bit_set[") {
        return "number"
    }
    if strings.has_prefix(t, "map[") {
        return "Record<string, unknown>"
    }
    if strings.has_prefix(t, "proc") || contains_substring(t, "#typeproc") {
        return "(...args: unknown[]) => unknown"
    }
    if strings.has_prefix(t, "any") || contains_substring(t, "Type_Info") {
        return "unknown"
    }
    if strings.has_prefix(t, "struct{") {
        return "JscObject"
    }

    if dot := strings.last_index(t, "."); dot >= 0 && dot + 1 < len(t) {
        trailing := t[dot + 1:]
        if guessed, ok := ts_guess_named_type(trailing); ok {
            return guessed
        }
        return "JscObject"
    }

    if is_odin_identifier(t) {
        return ensure_named_ts_type(t, ts_ctx)
    }

    return "unknown"
}

join_csv :: proc(parts: []string) -> string {
    if len(parts) == 0 do return ""
    sb := strings.builder_make()
    for p, i in parts {
        if i > 0 {
            strings.write_string(&sb, ", ")
        }
        strings.write_string(&sb, p)
    }
    return strings.to_string(sb)
}

extract_ident_name :: proc(expr: ^ast.Expr) -> (symbol: string, ok: bool) {
    if expr == nil do return
    ident, is_ident := expr.derived.(^ast.Ident)
    if !is_ident || ident == nil {
        return
    }
    // DUMBAI: use the parser-provided identifier name exactly like jsc_bindgen.odin.
    symbol = ident.name
    ok = symbol != "" && symbol != "_"
    return
}

collect_proc_infos :: proc(pkg: ^ast.Package) -> []Proc_Info {
    proc_seen := make(map[string]bool)
    infos := make([dynamic]Proc_Info)

    files := make([dynamic]^ast.File, 0, len(pkg.files))
    for _, file in pkg.files {
        if file == nil {
            continue
        }
        append(&files, file)
    }
    slice.sort_by(files[:], proc(lhs, rhs: ^ast.File) -> bool {
        return lhs.fullpath < rhs.fullpath
    })

    for file in files {
        // DUMBAI: parser AST exposes declarations on `decls` (matching jsc bindgen traversal).
        for stmt in file.decls {
            decl, is_value_decl := stmt.derived_stmt.(^ast.Value_Decl)
            if !is_value_decl || decl == nil {
                continue
            }

            count := min(len(decl.names), len(decl.values))
            for i := 0; i < count; i += 1 {
                proc_lit, is_proc_lit := decl.values[i].derived_expr.(^ast.Proc_Lit)
                if !is_proc_lit || proc_lit == nil {
                    continue
                }

                symbol, has_symbol := extract_ident_name(decl.names[i])
                if !has_symbol {
                    continue
                }
                // DUMBAI: keep parity with jsc bindgen by omitting package-private declarations from JS API surfaces.
                if decl_has_private_attribute(file, decl) {
                    continue
                }
                if strings.has_prefix(symbol, "_") {
                    continue
                }
                if proc_seen[symbol] {
                    continue
                }
                proc_seen[symbol] = true
                params, params_invalid, params_msg := analyze_params(file, proc_lit.type)
                results, results_invalid, results_msg := analyze_results(file, proc_lit.type)
                invalid := params_invalid || results_invalid
                invalid_msg := ""
                if params_invalid {
                    invalid_msg = params_msg
                }
                if invalid_msg == "" && results_invalid {
                    invalid_msg = results_msg
                }
                append(
                    &infos,
                    Proc_Info {
                        symbol = symbol,
                        params = params,
                        results = results,
                        diverging = proc_lit.type != nil && proc_lit.type.diverging,
                        generic = proc_lit.type != nil && proc_lit.type.generic,
                        invalid = invalid,
                        invalid_msg = invalid_msg,
                    },
                )
            }
        }
    }

    slice.sort_by(infos[:], proc(lhs, rhs: Proc_Info) -> bool {
        return lhs.symbol < rhs.symbol
    })
    return infos[:]
}

is_ignored_source_file :: proc(fullpath: string, output_abs: string) -> bool {
    if fullpath == output_abs do return true
    name := filepath.base(fullpath)
    if name == GEN_FILE_NAME do return true
    // DUMBAI: skip pre-generated source units (JSC/V8/etc.) to avoid recursive bindgen input pollution.
    if strings.has_suffix(name, ".generated.odin") do return true
    if strings.has_suffix(name, "_test.odin") do return true
    if strings.has_suffix(name, "_shd.odin") do return true
    return false
}

is_type_keyword_ident :: proc(ident: string) -> bool {
    switch ident {
    case "auto_cast",
         "bit_field",
         "bit_set",
         "cast",
         "distinct",
         "dynamic",
         "enum",
         "fixed",
         "map",
         "matrix",
         "no_nil",
         "or_else",
         "or_return",
         "proc",
         "raw_union",
         "shared_nil",
         "struct",
         "typeid",
         "union",
         "using",
         "where":
        return true
    }
    return false
}

collect_type_identifiers_from_text :: proc(type_text: string, out: ^map[string]bool) {
    text := compact_type_text(type_text)
    i := 0
    for i < len(text) {
        c := text[i]
        if !is_ascii_letter(c) && c != '_' {
            i += 1
            continue
        }

        start := i
        i += 1
        for i < len(text) {
            ch := text[i]
            if !is_ascii_letter(ch) && !is_ascii_digit(ch) && ch != '_' {
                break
            }
            i += 1
        }

        ident := text[start:i]
        if ident == "" || is_type_keyword_ident(ident) {
            continue
        }

        // DUMBAI: skip package aliases in selector syntax (e.g. `sg.Range` -> skip `sg`, keep `Range`).
        if i < len(text) && text[i] == '.' {
            continue
        }

        out^[ident] = true
    }
}

collect_used_type_names :: proc(bindings: []Binding_Info) -> map[string]bool {
    used := make(map[string]bool)
    for binding in bindings {
        for p in binding.params {
            collect_type_identifiers_from_text(p.odin_type, &used)
        }
        for r in binding.results {
            collect_type_identifiers_from_text(r.odin_type, &used)
        }
    }
    return used
}

unwrap_paren_expr :: proc(expr: ^ast.Expr) -> ^ast.Expr {
    current := expr
    for current != nil {
        paren, is_paren := current.derived_expr.(^ast.Paren_Expr)
        if !is_paren || paren == nil || paren.expr == nil {
            break
        }
        current = paren.expr
    }
    return current
}

is_explicit_type_decl_expr :: proc(expr: ^ast.Expr) -> bool {
    if expr == nil {
        return false
    }
    node := unwrap_paren_expr(expr)
    if node == nil {
        return false
    }
    if _, ok := node.derived_expr.(^ast.Typeid_Type); ok do return true
    if _, ok := node.derived_expr.(^ast.Helper_Type); ok do return true
    if _, ok := node.derived_expr.(^ast.Distinct_Type); ok do return true
    if _, ok := node.derived_expr.(^ast.Poly_Type); ok do return true
    if _, ok := node.derived_expr.(^ast.Proc_Type); ok do return true
    if _, ok := node.derived_expr.(^ast.Pointer_Type); ok do return true
    if _, ok := node.derived_expr.(^ast.Multi_Pointer_Type); ok do return true
    if _, ok := node.derived_expr.(^ast.Array_Type); ok do return true
    if _, ok := node.derived_expr.(^ast.Dynamic_Array_Type); ok do return true
    if _, ok := node.derived_expr.(^ast.Fixed_Capacity_Dynamic_Array_Type); ok do return true
    if _, ok := node.derived_expr.(^ast.Struct_Type); ok do return true
    if _, ok := node.derived_expr.(^ast.Union_Type); ok do return true
    if _, ok := node.derived_expr.(^ast.Enum_Type); ok do return true
    if _, ok := node.derived_expr.(^ast.Bit_Set_Type); ok do return true
    if _, ok := node.derived_expr.(^ast.Map_Type); ok do return true
    if _, ok := node.derived_expr.(^ast.Relative_Type); ok do return true
    if _, ok := node.derived_expr.(^ast.Matrix_Type); ok do return true
    if _, ok := node.derived_expr.(^ast.Bit_Field_Type); ok do return true
    return false
}

is_alias_type_decl_expr :: proc(expr: ^ast.Expr) -> bool {
    if expr == nil {
        return false
    }
    node := unwrap_paren_expr(expr)
    if node == nil {
        return false
    }
    if _, ok := node.derived_expr.(^ast.Ident); ok do return true
    if _, ok := node.derived_expr.(^ast.Selector_Expr); ok do return true
    if _, ok := node.derived_expr.(^ast.Index_Expr); ok do return true
    return false
}

collect_struct_fields :: proc(file: ^ast.File, struct_type: ^ast.Struct_Type) -> []Named_Type_Field {
    fields := make([dynamic]Named_Type_Field)
    if struct_type == nil || struct_type.fields == nil {
        return fields[:]
    }

    for field in struct_type.fields.list {
        if field == nil || field.type == nil {
            continue
        }

        type_text := compact_type_text(extract_expr_text(file.src, field.type))
        if type_text == "" {
            continue
        }

        if len(field.names) == 0 {
            // DUMBAI: anonymous/using fields do not expose stable property names in generated JS type contracts.
            continue
        }

        for name_expr in field.names {
            name, ok := extract_ident_name(name_expr)
            if !ok || name == "_" {
                continue
            }
            append(&fields, Named_Type_Field{name = name, odin_type = type_text})
        }
    }

    return fields[:]
}

build_named_type_def :: proc(file: ^ast.File, name: string, expr: ^ast.Expr) -> Named_Type_Def {
    def := Named_Type_Def {
        name      = name,
        kind      = .Alias,
        odin_type = compact_type_text(extract_expr_text(file.src, expr)),
    }

    node := unwrap_paren_expr(expr)
    if node == nil {
        return def
    }

    if struct_type, ok := node.derived_expr.(^ast.Struct_Type); ok {
        def.kind = .Struct
        def.fields = collect_struct_fields(file, struct_type)
        return def
    }
    if _, ok := node.derived_expr.(^ast.Enum_Type); ok {
        def.kind = .Enum
        return def
    }
    if _, ok := node.derived_expr.(^ast.Bit_Set_Type); ok {
        def.kind = .Bit_Set
        return def
    }
    // DUMBAI: keep all other declaration forms as alias nodes in d.ts emission.
    return def
}

collect_named_type_defs :: proc(
    pkg: ^ast.Package,
    output_abs: string,
    bindings: []Binding_Info,
) -> map[string]Named_Type_Def {
    defs := make(map[string]Named_Type_Def)
    used_names := collect_used_type_names(bindings)

    files := make([dynamic]^ast.File, 0, len(pkg.files))
    for _, file in pkg.files {
        if file == nil do continue
        if is_ignored_source_file(file.fullpath, output_abs) do continue
        append(&files, file)
    }
    slice.sort_by(files[:], proc(lhs, rhs: ^ast.File) -> bool {
        return lhs.fullpath < rhs.fullpath
    })

    changed := true
    for changed {
        changed = false
        for file in files {
            for stmt in file.decls {
                decl, is_value_decl := stmt.derived_stmt.(^ast.Value_Decl)
                if !is_value_decl || decl == nil {
                    continue
                }
                if decl.is_mutable || decl.type != nil {
                    continue
                }

                count := min(len(decl.names), len(decl.values))
                for i := 0; i < count; i += 1 {
                    name, ok := extract_ident_name(decl.names[i])
                    if !ok {
                        continue
                    }
                    if _, exists := defs[name]; exists {
                        continue
                    }

                    value_expr := decl.values[i]
                    if value_expr == nil {
                        continue
                    }
                    if _, is_proc := value_expr.derived_expr.(^ast.Proc_Lit); is_proc {
                        continue
                    }

                    explicit := is_explicit_type_decl_expr(value_expr)
                    if !explicit {
                        if !used_names[name] || !is_alias_type_decl_expr(value_expr) {
                            continue
                        }
                    }

                    def := build_named_type_def(file, name, value_expr)
                    defs[name] = def
                    changed = true

                    if def.kind == .Struct {
                        for field in def.fields {
                            collect_type_identifiers_from_text(field.odin_type, &used_names)
                        }
                    } else {
                        collect_type_identifiers_from_text(def.odin_type, &used_names)
                    }
                }
            }
        }
    }

    return defs
}

split_head_token :: proc(src: string) -> (head, tail: string, ok: bool) {
    start := 0
    for start < len(src) {
        c := src[start]
        if c != ' ' && c != '\t' {
            break
        }
        start += 1
    }

    end := start
    for end < len(src) {
        c := src[end]
        if c == ' ' || c == '\t' {
            break
        }
        end += 1
    }

    head = src[start:end]
    tail = strings.trim_space(src[end:])
    ok = head != ""
    return
}

parse_bindings_map :: proc(raw: string, line_no: int) -> (map[string]string, bool) {
    bindings := make(map[string]string)
    text := strings.trim_space(raw)
    if text == "" {
        return bindings, true
    }

    chunks, _ := strings.split(text, ",", context.temp_allocator)
    for chunk in chunks {
        part := strings.trim_space(chunk)
        if part == "" {
            continue
        }
        eq := strings.index(part, "=")
        if eq <= 0 || eq >= len(part) - 1 {
            fmt.eprintf("v8_bindgen: invalid specialize binding on line %d: %s\n", line_no, part)
            return bindings, false
        }
        key := strings.trim_space(part[:eq])
        value := strings.trim_space(part[eq + 1:])
        if key == "" || value == "" {
            fmt.eprintf("v8_bindgen: invalid specialize binding on line %d: %s\n", line_no, part)
            return bindings, false
        }
        bindings[key] = value
    }
    return bindings, true
}

normalize_spec_target_symbol :: proc(raw: string, line_no: int) -> (symbol: string, ok: bool) {
    target := strings.trim_space(raw)
    if target == "" {
        fmt.eprintf("v8_bindgen: missing target symbol on line %d\n", line_no)
        return "", false
    }
    if dot := strings.last_index(target, "."); dot >= 0 {
        // DUMBAI: spec targets are always resolved against the current package; any `alias.` prefix is ignored.
        target = strings.trim_space(target[dot + 1:])
    }
    if target == "" {
        fmt.eprintf("v8_bindgen: invalid target symbol `%s` on line %d\n", raw, line_no)
        return "", false
    }
    return target, true
}

parse_binding_mode :: proc(raw: string) -> (mode: Binding_Mode, ok: bool) {
    switch raw {
    case "stub":
        return .stub, true
    case "void", "void0":
        return .void, true
    case "bool", "bool0":
        return .bool, true
    case "utf8", "utf8_1":
        return .utf8, true
    case "rgba4", "rgba4_1":
        return .rgba4, true
    }
    return .stub, false
}

parse_spec_file :: proc(module_abs: string) -> (spec: Spec_Config, ok: bool) {
    spec.target_import_alias = sanitize_identifier(filepath.base(module_abs))
    spec.excludes = make(map[string]bool)
    spec.renames = make(map[string]string)
    spec.specializes = make([dynamic]Specialize_Directive)

    spec_abs, joined := join2(module_abs, SPEC_FILE_NAME)
    if !joined {
        fmt.eprintln("v8_bindgen: failed to allocate spec path")
        return spec, false
    }

    if !os.exists(spec_abs) {
        return spec, true
    }

    bytes, read_err := os.read_entire_file(spec_abs, context.allocator)
    if read_err != nil {
        fmt.eprintf("v8_bindgen: failed to read %s: %v\n", spec_abs, read_err)
        return spec, false
    }

    lines, _ := strings.split(string(bytes), "\n", context.temp_allocator)
    for raw_line, i in lines {
        line_no := i + 1
        line := strings.trim_space(raw_line)
        if line == "" do continue
        if strings.has_prefix(line, "#") || strings.has_prefix(line, "//") do continue

        directive, tail, head_ok := split_head_token(line)
        if !head_ok {
            continue
        }

        switch directive {
        case "target_rename":
            source_or_alias, rest, tok_ok := split_head_token(tail)
            if !tok_ok {
                fmt.eprintf("v8_bindgen: invalid target_rename directive on line %d\n", line_no)
                return spec, false
            }
            alias := source_or_alias
            if renamed_alias, _, has_renamed_alias := split_head_token(rest); has_renamed_alias {
                alias = renamed_alias
            }
            alias = sanitize_identifier(alias)
            if alias == "" {
                fmt.eprintf("v8_bindgen: invalid target_rename alias on line %d\n", line_no)
                return spec, false
            }
            // DUMBAI: spec-level target_rename makes import alias selection explicit and avoids hidden parser hardcodes.
            spec.target_import_alias = alias

        case "exclude":
            raw_symbol, _, tok_ok := split_head_token(tail)
            if !tok_ok {
                fmt.eprintf("v8_bindgen: invalid exclude directive on line %d\n", line_no)
                return spec, false
            }
            symbol, symbol_ok := normalize_spec_target_symbol(raw_symbol, line_no)
            if !symbol_ok {
                return spec, false
            }
            spec.excludes[symbol] = true

        case "rename":
            raw_symbol, rest, tok_ok := split_head_token(tail)
            if !tok_ok {
                fmt.eprintf("v8_bindgen: invalid rename directive on line %d\n", line_no)
                return spec, false
            }
            symbol, symbol_ok := normalize_spec_target_symbol(raw_symbol, line_no)
            if !symbol_ok {
                return spec, false
            }
            js_name, _, name_ok := split_head_token(rest)
            if !name_ok {
                fmt.eprintf("v8_bindgen: invalid rename directive on line %d\n", line_no)
                return spec, false
            }
            spec.renames[symbol] = js_name

        case "specialize":
            raw_symbol, rest, sym_ok := split_head_token(tail)
            if !sym_ok {
                fmt.eprintf("v8_bindgen: invalid specialize directive on line %d\n", line_no)
                return spec, false
            }
            symbol, symbol_ok := normalize_spec_target_symbol(raw_symbol, line_no)
            if !symbol_ok {
                return spec, false
            }
            js_name, binding_text, name_ok := split_head_token(rest)
            if !name_ok {
                fmt.eprintf("v8_bindgen: invalid specialize directive on line %d\n", line_no)
                return spec, false
            }
            bindings, parsed := parse_bindings_map(binding_text, line_no)
            if !parsed {
                return spec, false
            }
            append(
                &spec.specializes,
                Specialize_Directive{symbol = symbol, js_name = js_name, bindings = bindings, line = line_no},
            )

        case:
            fmt.eprintf("v8_bindgen: unknown directive `%s` on line %d\n", directive, line_no)
            return spec, false
        }
    }

    return spec, true
}

build_bindings :: proc(infos: []Proc_Info, spec: Spec_Config) -> (bindings: []Binding_Info, ok: bool) {
    symbol_set := make(map[string]bool)
    for info in infos {
        symbol_set[info.symbol] = true
    }

    specialize_entries := make(map[string][dynamic]Specialize_Directive)
    for entry in spec.specializes {
        if !symbol_set[entry.symbol] {
            fmt.eprintf("v8_bindgen: specialize target `%s` (line %d) does not exist\n", entry.symbol, entry.line)
            return nil, false
        }
        if spec.excludes[entry.symbol] {
            fmt.eprintf("v8_bindgen: specialize target `%s` (line %d) is excluded by spec\n", entry.symbol, entry.line)
            return nil, false
        }
        // DUMBAI: retain all specialize directives (including non-`mode` bindings) so d.ts specialization can mirror jsc specs.
        arr, exists := specialize_entries[entry.symbol]
        if !exists {
            arr = make([dynamic]Specialize_Directive)
        }
        append(&arr, entry)
        specialize_entries[entry.symbol] = arr
    }

    out := make([dynamic]Binding_Info, 0, len(infos))
    for info in infos {
        if spec.excludes[info.symbol] {
            continue
        }

        entries := specialize_entries[info.symbol]
        if len(entries) == 0 {
            js_name := info.symbol
            if rename, has_rename := spec.renames[info.symbol]; has_rename {
                js_name = rename
            }

            mode := Binding_Mode.stub
            supported := true
            unsupported_reason := ""
            if info.generic {
                supported = false
                unsupported_reason = "generic procedure requires `specialize` directive"
            }
            if supported && info.invalid {
                supported = false
                unsupported_reason = info.invalid_msg
            }
            if supported {
                for p in info.params {
                    if !p.runtime_exposed || !p.unsupported {
                        continue
                    }
                    supported = false
                    unsupported_reason = p.unsupported_msg
                    break
                }
            }
            if supported {
                for r in info.results {
                    if !r.unsupported {
                        continue
                    }
                    supported = false
                    unsupported_reason = r.unsupported_msg
                    break
                }
            }
            if !supported {
                // DUMBAI: unsupported signatures must bind as throw stubs so native wrapper generation stays valid.
                mode = .stub
            }

            wrapper_name := ""
            if mode != .stub {
                wrapper_name = fmt.aprintf(
                    "v8_bind_%s_%s",
                    sanitize_identifier(info.symbol),
                    mode_suffix(mode),
                    allocator = context.allocator,
                )
            }

            append(
                &out,
                Binding_Info {
                    symbol = info.symbol,
                    js_name = js_name,
                    wrapper_name = wrapper_name,
                    mode = mode,
                    params = info.params,
                    results = info.results,
                    diverging = info.diverging,
                    supported = supported,
                    unsupported_reason = unsupported_reason,
                },
            )
            continue
        }

        for entry in entries {
            mode := Binding_Mode.stub
            if mode_raw, has_mode := entry.bindings["mode"]; has_mode {
                parsed_mode, parsed := parse_binding_mode(mode_raw)
                if !parsed {
                    fmt.eprintf(
                        "v8_bindgen: invalid specialize mode `%s` for `%s` on line %d\n",
                        mode_raw,
                        entry.symbol,
                        entry.line,
                    )
                    return nil, false
                }
                mode = parsed_mode
            }

            supported := true
            unsupported_reason := ""
            if info.invalid {
                supported = false
                unsupported_reason = info.invalid_msg
            }
            if supported {
                for p in info.params {
                    if !p.runtime_exposed || !p.unsupported {
                        continue
                    }
                    supported = false
                    unsupported_reason = p.unsupported_msg
                    break
                }
            }
            if supported {
                for r in info.results {
                    if !r.unsupported {
                        continue
                    }
                    supported = false
                    unsupported_reason = r.unsupported_msg
                    break
                }
            }
            if !supported {
                // DUMBAI: keep unsupported specializations visible in d.ts while runtime registration stays safe.
                mode = .stub
            }

            wrapper_name := ""
            if mode != .stub {
                wrapper_name = fmt.aprintf(
                    "v8_bind_%s_%s",
                    sanitize_identifier(info.symbol),
                    mode_suffix(mode),
                    allocator = context.allocator,
                )
            }

            append(
                &out,
                Binding_Info {
                    symbol = info.symbol,
                    js_name = entry.js_name,
                    wrapper_name = wrapper_name,
                    mode = mode,
                    params = info.params,
                    results = info.results,
                    diverging = info.diverging,
                    supported = supported,
                    unsupported_reason = unsupported_reason,
                },
            )
        }
    }
    return out[:], true
}

write_line :: proc(sb: ^strings.Builder, line := "") {
    strings.write_string(sb, line)
    strings.write_byte(sb, '\n')
}

write_non_web_build_tags :: proc(sb: ^strings.Builder) {
    // DUMBAI: V8 bindings are native-only and must be excluded from web targets.
    write_line(sb, "#+build !js")
    write_line(sb, "#+build !wasi")
    write_line(sb, "#+build !orca")
    write_line(sb)
}

with_open_brace :: proc(line: string) -> string {
    // DUMBAI: fmt strings treat `{` specially, so append braces after formatting.
    out := strings.builder_make_len_cap(0, len(line) + 1)
    strings.write_string(&out, line)
    strings.write_byte(&out, '{')
    return strings.to_string(out)
}

render_wrapper_proc :: proc(sb: ^strings.Builder, binding: Binding_Info) {
    switch binding.mode {
    case .stub:
        return

    case .void:
        write_line(
            sb,
            with_open_brace(
                fmt.aprintf("    %s :: proc \"c\" (_: rawptr) ", binding.wrapper_name, allocator = context.allocator),
            ),
        )
        write_line(sb, "        context = runtime.default_context()")
        write_line(sb, fmt.aprintf("        %s()", binding.symbol, allocator = context.allocator))
        write_line(sb, "    }")
        write_line(sb)

    case .bool:
        write_line(
            sb,
            with_open_brace(
                fmt.aprintf(
                    "    %s :: proc \"c\" (_: rawptr) -> c.int ",
                    binding.wrapper_name,
                    allocator = context.allocator,
                ),
            ),
        )
        write_line(sb, "        context = runtime.default_context()")
        write_line(sb, with_open_brace(fmt.aprintf("        if %s() ", binding.symbol, allocator = context.allocator)))
        write_line(sb, "            return 1")
        write_line(sb, "        }")
        write_line(sb, "        return 0")
        write_line(sb, "    }")
        write_line(sb)

    case .utf8:
        write_line(
            sb,
            with_open_brace(
                fmt.aprintf(
                    "    %s :: proc \"c\" (arg0_utf8: cstring, _: rawptr) ",
                    binding.wrapper_name,
                    allocator = context.allocator,
                ),
            ),
        )
        write_line(sb, "        context = runtime.default_context()")
        write_line(sb, fmt.aprintf("        %s(arg0_utf8)", binding.symbol, allocator = context.allocator))
        write_line(sb, "    }")
        write_line(sb)

    case .rgba4:
        write_line(
            sb,
            with_open_brace(
                fmt.aprintf(
                    "    %s :: proc \"c\" (r, g, b, a: f32, _: rawptr) ",
                    binding.wrapper_name,
                    allocator = context.allocator,
                ),
            ),
        )
        write_line(sb, "        context = runtime.default_context()")
        write_line(sb, fmt.aprintf("        %s(%s)", binding.symbol, "{r, g, b, a}", allocator = context.allocator))
        write_line(sb, "    }")
        write_line(sb)
    }
}

render_register_call :: proc(sb: ^strings.Builder, binding: Binding_Info) {
    register_call := ""
    switch binding.mode {
    case .stub:
        register_call = fmt.aprintf(
            "v8.bind_throwing_function(isolate, ctx, %s)",
            quote_odin_string(binding.js_name),
            allocator = context.allocator,
        )
    case .void:
        register_call = fmt.aprintf(
            "v8.bind_void_function(isolate, ctx, %s, %s)",
            quote_odin_string(binding.js_name),
            binding.wrapper_name,
            allocator = context.allocator,
        )
    case .bool:
        register_call = fmt.aprintf(
            "v8.bind_bool_function(isolate, ctx, %s, %s)",
            quote_odin_string(binding.js_name),
            binding.wrapper_name,
            allocator = context.allocator,
        )
    case .utf8:
        register_call = fmt.aprintf(
            "v8.bind_utf8_function(isolate, ctx, %s, %s)",
            quote_odin_string(binding.js_name),
            binding.wrapper_name,
            allocator = context.allocator,
        )
    case .rgba4:
        register_call = fmt.aprintf(
            "v8.bind_rgba4_function(isolate, ctx, %s, %s)",
            quote_odin_string(binding.js_name),
            binding.wrapper_name,
            allocator = context.allocator,
        )
    }

    write_line(sb, with_open_brace(fmt.aprintf("        if !%s ", register_call, allocator = context.allocator)))
    write_line(sb, "            return false")
    write_line(sb, "        }")
}

collect_unique_js_names :: proc(bindings: []Binding_Info) -> []string {
    seen := make(map[string]bool)
    names := make([dynamic]string, 0, len(bindings))
    for binding in bindings {
        if seen[binding.js_name] {
            continue
        }
        seen[binding.js_name] = true
        append(&names, binding.js_name)
    }
    slice.sort_by(names[:], proc(lhs, rhs: string) -> bool {
        return lhs < rhs
    })
    return names[:]
}

write_namespace_registration :: proc(sb: ^strings.Builder, namespace_path: string, bindings: []Binding_Info) {
    names := collect_unique_js_names(bindings)
    if len(names) == 0 {
        return
    }

    write_line(sb, "        // DUMBAI: move bindgen globals under the configured shared JS root object namespace.")
    write_line(
        sb,
        with_open_brace(
            fmt.aprintf(
                "        if !v8.bind_global_functions_into_namespace(isolate, ctx, %s, []string",
                quote_odin_string(namespace_path),
                allocator = context.allocator,
            ),
        ),
    )
    for name in names {
        write_line(sb, fmt.aprintf("            %s,", quote_odin_string(name), allocator = context.allocator))
    }
    write_line(sb, "        }) {")
    write_line(sb, "            return false")
    write_line(sb, "        }")
}

ts_namespace_type_name :: proc(namespace: string) -> string {
    out := make([dynamic]byte, 0, len(namespace) + len("Bindings") + 4)
    upper_next := true
    for i := 0; i < len(namespace); i += 1 {
        c := namespace[i]
        if is_ascii_letter(c) || is_ascii_digit(c) {
            ch := c
            if upper_next && ch >= 'a' && ch <= 'z' {
                ch = ch - ('a' - 'A')
            }
            append(&out, ch)
            upper_next = false
        } else {
            upper_next = true
        }
    }
    if len(out) == 0 || is_ascii_digit(out[0]) {
        prefixed := make([dynamic]byte, 0, len(out) + 3)
        append(&prefixed, 'L', 'i', 'b')
        append(&prefixed, ..out[:])
        out = prefixed
    }
    base := string(out[:])
    return fmt.aprintf("%sBindings", base, allocator = context.allocator)
}

prime_dts_type_context :: proc(bindings: []Binding_Info, ts_ctx: ^TS_Render_Context) {
    for info in bindings {
        for p in info.params {
            if !p.runtime_exposed || p.unsupported {
                continue
            }
            _ = map_odin_type_to_ts(p.odin_type, ts_ctx)
        }
        for r in info.results {
            if r.unsupported {
                continue
            }
            _ = map_odin_type_to_ts(r.odin_type, ts_ctx)
        }
    }
}

render_dts_function_entry :: proc(sb: ^strings.Builder, info: Binding_Info, ts_ctx: ^TS_Render_Context) {
    prop_name := info.js_name
    use_method_syntax := is_ts_identifier(prop_name)
    render_name := prop_name if use_method_syntax else quote_odin_string(prop_name)

    if !info.supported {
        write_line(sb, fmt.aprintf("    // unsupported: %s", info.unsupported_reason, allocator = context.allocator))
        write_line(
            sb,
            fmt.aprintf("    %s: (...args: unknown[]) => never;", render_name, allocator = context.allocator),
        )
        return
    }

    param_parts := make([dynamic]string)
    runtime_idx := 0
    for p in info.params {
        if !p.runtime_exposed {
            continue
        }
        pname := ts_param_name(p.name, fmt.aprintf("arg%d", runtime_idx, allocator = context.temp_allocator))
        ptype := "unknown"
        if !p.unsupported {
            ptype = map_odin_type_to_ts(p.odin_type, ts_ctx)
        }
        optional := "?" if p.has_default else ""
        append(&param_parts, fmt.aprintf("%s%s: %s", pname, optional, ptype, allocator = context.allocator))
        runtime_idx += 1
    }
    params_joined := join_csv(param_parts[:])

    return_type := "void"
    if info.diverging {
        return_type = "never"
    } else if len(info.results) == 1 {
        if info.results[0].unsupported {
            return_type = "unknown"
        } else {
            return_type = map_odin_type_to_ts(info.results[0].odin_type, ts_ctx)
        }
    } else if len(info.results) > 1 {
        parts := make([dynamic]string)
        for r in info.results {
            if r.unsupported {
                append(&parts, "unknown")
            } else {
                append(&parts, map_odin_type_to_ts(r.odin_type, ts_ctx))
            }
        }
        return_type = fmt.aprintf("[%s]", join_csv(parts[:]), allocator = context.allocator)
    }

    if use_method_syntax {
        write_line(
            sb,
            fmt.aprintf("    %s(%s): %s;", render_name, params_joined, return_type, allocator = context.allocator),
        )
    } else {
        write_line(
            sb,
            fmt.aprintf("    %s: (%s) => %s;", render_name, params_joined, return_type, allocator = context.allocator),
        )
    }
}

render_dts_output :: proc(
    namespace_root: string,
    namespace_leaf: string,
    bindings: []Binding_Info,
    named_defs: map[string]Named_Type_Def,
) -> string {
    sb := strings.builder_make()
    root_name := sanitize_identifier(namespace_root)
    leaf_name := sanitize_identifier(namespace_leaf)
    type_name := ts_namespace_type_name(leaf_name)
    ts_ctx := TS_Render_Context {
        named_defs       = named_defs,
        named_ts_exprs   = make(map[string]string),
        named_alias_name = make(map[string]string),
        resolving_named  = make(map[string]bool),
    }

    prime_dts_type_context(bindings, &ts_ctx)

    write_line(&sb, "// DUMBAI: generated by v8/scripts/bindgen.odin; do not edit by hand.")
    write_line(&sb, "export type JscObject = Record<string, unknown>;")
    write_line(&sb, "export type JscOpaqueHandle<T extends string = string> = { readonly __jscOpaqueType?: T };")
    write_line(&sb)

    alias_names := make([dynamic]string)
    for alias, _ in ts_ctx.named_ts_exprs {
        append(&alias_names, alias)
    }
    slice.sort_by(alias_names[:], proc(lhs, rhs: string) -> bool {
        return lhs < rhs
    })
    for alias in alias_names {
        expr := ts_ctx.named_ts_exprs[alias]
        write_line(&sb, fmt.aprintf("export type %s = %s;", alias, expr, allocator = context.allocator))
    }
    if len(alias_names) > 0 {
        write_line(&sb)
    }

    write_line(&sb, fmt.aprintf("export type %s = ", type_name, allocator = context.allocator))
    write_line(&sb, "{")
    for info in bindings {
        render_dts_function_entry(&sb, info, &ts_ctx)
    }
    write_line(&sb, "};")
    write_line(&sb)
    write_line(&sb, "declare global {")
    write_line(&sb, with_open_brace(fmt.aprintf("    var %s: ", root_name, allocator = context.allocator)))
    write_line(&sb, fmt.aprintf("        %s: %s;", leaf_name, type_name, allocator = context.allocator))
    write_line(&sb, "    };")
    write_line(&sb, "    interface GlobalThis {")
    write_line(&sb, with_open_brace(fmt.aprintf("        %s: ", root_name, allocator = context.allocator)))
    write_line(&sb, fmt.aprintf("            %s: %s;", leaf_name, type_name, allocator = context.allocator))
    write_line(&sb, "        };")
    write_line(&sb, "    }")
    write_line(&sb, "}")
    write_line(&sb)
    write_line(&sb, "export {}")

    return strings.to_string(sb)
}

render_output :: proc(
    package_name: string,
    module_name: string,
    namespace_root: string,
    namespace_leaf: string,
    v8_import: string,
    bindings: []Binding_Info,
) -> string {
    sb := strings.builder_make()

    has_specialized := false
    for binding in bindings {
        if binding.mode != .stub {
            has_specialized = true
            break
        }
    }

    write_non_web_build_tags(&sb)
    write_line(&sb, fmt.aprintf("package %s", package_name, allocator = context.allocator))
    write_line(&sb)
    if has_specialized {
        write_line(&sb, "import \"core:c\"")
        write_line(&sb, "import runtime \"base:runtime\"")
    }
    write_line(&sb, fmt.aprintf("import v8 %s", quote_odin_string(v8_import), allocator = context.allocator))
    write_line(&sb)
    write_line(&sb, "// generated by v8/scripts/bindgen.odin; do not edit by hand.")
    write_line(&sb, "when #config(V8_BINDINGS, false) {")
    write_line(
        &sb,
        "    // DUMBAI: gate registration stubs so modules skip V8 binding proc compilation unless explicitly enabled.",
    )

    if has_specialized {
        write_line(
            &sb,
            "    // DUMBAI: callbacks specialized by v8_bindgen.spec keep JS bridge logic generated and out of hand-written entrypoints.",
        )
        for binding in bindings {
            if binding.mode == .stub {
                continue
            }
            render_wrapper_proc(&sb, binding)
        }
    }

    write_line(
        &sb,
        with_open_brace(
            fmt.aprintf(
                "    register_%s_v8_bindings :: proc(isolate: v8.Isolate, ctx: v8.Context) -> bool ",
                module_name,
                allocator = context.allocator,
            ),
        ),
    )
    write_line(
        &sb,
        "        // DUMBAI: Register exported proc names as stubs unless spec-specialized callbacks request live bindings.",
    )
    for binding in bindings {
        render_register_call(&sb, binding)
    }
    namespace_path := fmt.aprintf("%s.%s", namespace_root, namespace_leaf, allocator = context.allocator)
    write_namespace_registration(&sb, namespace_path, bindings)
    write_line(&sb, "        return true")
    write_line(&sb, "    }")
    write_line(&sb, "}")
    return strings.to_string(sb)
}

count_specialized_bindings :: proc(bindings: []Binding_Info) -> int {
    count := 0
    for binding in bindings {
        if binding.mode != .stub {
            count += 1
        }
    }
    return count
}

write_file_if_changed :: proc(path, content: string) -> (changed: bool, ok: bool) {
    existing, read_err := os.read_entire_file(path, context.temp_allocator)
    if read_err == nil && string(existing) == content {
        return false, true
    }

    if write_err := os.write_entire_file(path, content); write_err != nil {
        fmt.eprintf("v8_bindgen: failed to write %s: %v\n", path, write_err)
        return false, false
    }

    return true, true
}

run :: proc() -> int {
    if len(os.args) != 2 {
        print_usage()
        return 1
    }

    lib_arg := strings.trim_space(os.args[1])
    if lib_arg == "" {
        print_usage()
        return 1
    }

    module_abs, module_name, resolved := resolve_module_path(lib_arg)
    if !resolved {
        return 1
    }

    output_abs, output_ok := join2(module_abs, GEN_FILE_NAME)
    if !output_ok {
        fmt.eprintln("v8_bindgen: failed to allocate output path")
        return 1
    }
    output_dts_abs, output_dts_ok := join2(module_abs, GEN_DTS_FILE_NAME)
    if !output_dts_ok {
        fmt.eprintln("v8_bindgen: failed to allocate d.ts output path")
        return 1
    }

    spec, spec_ok := parse_spec_file(module_abs)
    if !spec_ok {
        return 1
    }

    // DUMBAI: Parse package source directly so bindgen stays deterministic and toolchain-local.
    pkg, collected := parser.collect_package(module_abs)
    if !collected || pkg == nil {
        fmt.eprintf("v8_bindgen: failed to collect package files from %s\n", module_abs)
        return 1
    }

    for fullpath, _ in pkg.files {
        name := filepath.base(fullpath)
        // DUMBAI: mirror jsc bindgen source filtering so V8 d.ts and API surfaces track the same runtime-facing files.
        if is_generated_source_file(name) ||
           strings.has_suffix(name, "_test.odin") ||
           strings.has_suffix(name, "_shd.odin") {
            delete_key(&pkg.files, fullpath)
        }
    }

    if !parser.parse_package(pkg) {
        fmt.eprintf("v8_bindgen: parse failed for package %s\n", module_abs)
        return 1
    }
    if pkg.name == "" {
        fmt.eprintf("v8_bindgen: package name could not be detected for %s\n", module_abs)
        return 1
    }

    v8_root_abs, root_ok := resolve_generator_v8_root()
    if !root_ok {
        return 1
    }
    v8_import, import_ok := resolve_v8_import(module_abs, v8_root_abs)
    if !import_ok {
        return 1
    }

    infos := collect_proc_infos(pkg)
    bindings, built := build_bindings(infos, spec)
    if !built {
        return 1
    }
    named_defs := collect_named_type_defs(pkg, output_abs, bindings)
    // DUMBAI: infer hierarchy from module path automatically so specs only need symbol-level directives.
    namespace_root := derive_default_namespace_root(module_abs)
    namespace_leaf := sanitize_identifier(spec.target_import_alias)
    if namespace_leaf == "" {
        namespace_leaf = module_name
    }

    rendered := render_output(pkg.name, module_name, namespace_root, namespace_leaf, v8_import, bindings)
    rendered_dts := render_dts_output(namespace_root, namespace_leaf, bindings, named_defs)
    specialized_count := count_specialized_bindings(bindings)
    odin_changed := false
    dts_changed := false
    if changed, ok := write_file_if_changed(output_abs, rendered); !ok {
        return 1
    } else if changed {
        odin_changed = true
    }
    if changed, ok := write_file_if_changed(output_dts_abs, rendered_dts); !ok {
        return 1
    } else if changed {
        dts_changed = true
    }

    if !odin_changed && !dts_changed {
        fmt.printf(
            "No changes: %s (%d procs, %d spec-specialized, 2 generated files)\n",
            module_abs,
            len(bindings),
            specialized_count,
        )
        return 0
    }

    changed_count := 0
    if odin_changed {
        changed_count += 1
        fmt.printf("Wrote %s\n", output_abs)
    }
    if dts_changed {
        changed_count += 1
        fmt.printf("Wrote %s\n", output_dts_abs)
    }
    fmt.printf(
        "Generated %s (%d procs, %d spec-specialized, %d files written)\n",
        module_abs,
        len(bindings),
        specialized_count,
        changed_count,
    )
    return 0
}

main :: proc() {
    os.exit(run())
}
