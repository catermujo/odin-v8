# V8 minimal Odin bindings

## Build via vendored script (recommended / canonical)

From this directory:

```bash
./build.sh
```

Windows:

```bat
build.bat
```

Notes:

- `build.sh` / `build.bat` are the canonical entrypoints, matching other vendor package wrappers.
- Default mode is **shared** (`--link-mode=shared`), so the script stages:
  - Linux: `libv8.so`, `libv8_libbase.so`, `libv8_libplatform.so`, `libcv8.so`
  - macOS: `libv8.dylib`, `libv8_libbase.dylib`, `libv8_libplatform.dylib`, `libcv8.dylib`
  - Windows: `v8.dll`, `v8_libbase.dll`, `v8_libplatform.dll`, `cv8.dll`
- Static mode is still available:
  - `./build_static.sh` / `build_static.bat`
  - or `./build.sh --link-mode=static`
- Extra flags are forwarded to `scripts/build_cv8.py`, e.g. `--skip-v8-build`, `--rebuild-v8`, `--rebuild-cv8`, `--gn-out`.
  - Default `--gn-out` is `<host-cpu>.release` (`x64.release` or `arm64.release`).
- Default GN args disable Temporal (`v8_enable_temporal_support = false`) so consumers do not need V8’s Rust rlib link closure.

## Cleanup build artifacts

From this directory:

```bash
./build.sh --clean
```

This removes staged `cv8`/`v8` artifacts and `v8/out` intermediates.

Maximum cleanup:

```bash
./build.sh --clean-all
```

`--clean-all` also removes `v8` and `depot_tools`.

## Odin link mode

`v8.odin` defaults to shared linking.

- Shared (default): no define needed.
- Static: set `-define:V8_LINK_STATIC=true`.

## Build `cv8` shim library

The shim must be compiled as C++20.

Linux/macOS static (example):

```bash
clang++ -std=c++20 -O2 -fno-exceptions -fno-rtti \
  -I v8 -I v8/include \
  -c cv8.cc -o cv8.o
ar rcs libcv8.a cv8.o
```

Linux/macOS shared (example):

```bash
clang++ -std=c++20 -O2 -fno-exceptions -fno-rtti -fPIC \
  -I v8 -I v8/include \
  -c cv8.cc -o cv8.o
clang++ -shared -o libcv8.so cv8.o libv8.so libv8_libbase.so libv8_libplatform.so
```

Windows static (MSVC outline):

```bat
cl /std:c++20 /O2 /EHsc /I v8 /I v8\include /c cv8.cc /Focv8.obj
lib /OUT:cv8.lib cv8.obj
```

Windows shared (MSVC outline):

```bat
cl /std:c++20 /O2 /EHsc /I v8 /I v8\include /c cv8.cc /Focv8.obj
link /DLL /OUT:cv8.dll /IMPLIB:cv8.lib cv8.obj v8.dll.lib v8_libbase.dll.lib v8_libplatform.dll.lib
```

## Generate module bindings

Run bindgen once per Odin module that should expose JS stubs:

```bash
odin run scripts/bindgen.odin -file -- path/to/module
```

Bindgen behavior:

- Writes `<module>/v8_bindings.generated.odin`.
- Writes `<module>/v8_bindings.generated.d.ts`.
- Generates `register_<module>_v8_bindings(isolate, ctx) -> bool`.
- Collects top-level proc literals from parsed package files.
- Skips symbols starting with `_`.
- Skips any source ending in `.generated.odin`.
- Deduplicates and alphabetically sorts symbol registration.
- Registers symbols, then moves them under `globalThis.<namespace_root>.<module_alias>` namespace object.
  - Default `<namespace_root>` is derived from the module parent folder name.
  - Default `<module_alias>` is the module folder name.
  - `target_rename` in `v8_bindgen.spec` overrides `<module_alias>`.
  - Example: for `./rt/drift`, exports are available under `globalThis.rt.drift.*`.

## `v8_bindgen.spec`

`scripts/bindgen.odin` parses `<module>/v8_bindgen.spec` when present.

Supported directives:

- `exclude <symbol>`
- `rename <symbol> <js_name>`
- `specialize <symbol> <js_name> <bindings>`

`<bindings>` is comma-separated `name=value` pairs.

Current `specialize` bindings:

- `mode=stub`
- `mode=void` (or `void0`)
- `mode=bool` (or `bool0`)
- `mode=utf8` (or `utf8_1`)
- `mode=rgba4` (or `rgba4_1`)

Specialized modes generate C-callback wrappers inside `v8_bindings.generated.odin` and register them with:

- `v8.bind_void_function`
- `v8.bind_bool_function`
- `v8.bind_utf8_function`
- `v8.bind_rgba4_function`

## Type declarations

For editor support, bindgen emits `<module>/v8_bindings.generated.d.ts` with:

- one interface describing all exported JS binding names for that module.
- `GlobalThis` augmentation for `globalThis.<namespace_root>.<module_alias>`.

## Quick usage

```odin
package main

import "core:c"
import "v8"

main :: proc() {
    if v8.initialize(nil, nil, nil) == 0 do return
    defer v8.shutdown()

    isolate := v8.isolate_new()
    defer v8.isolate_dispose(isolate)

    ctx := v8.context_new(isolate)
    defer v8.context_dispose(ctx)

    err: v8.Error
    out: [4096]c.char
    out_len: c.size_t
    _ = v8.run_script_utf8(
        isolate,
        ctx,
        "1 + 2 + 39",
        "main.odin",
        &err,
        raw_data(out[:]),
        c.size_t(len(out)),
        &out_len,
    )
}
```
