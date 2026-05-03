from __future__ import annotations

import argparse
import os
import platform
import shlex
import shutil
import subprocess
import tempfile
from dataclasses import dataclass
from pathlib import Path
from typing import Literal


LinkMode = Literal["shared", "static"]

ROOT = Path(__file__).resolve().parents[1]
V8_SOURCE = ROOT / "v8"
DEPOT_TOOLS = ROOT / "depot_tools"
V8_SOURCE_URL = "https://chromium.googlesource.com/v8/v8.git"
V8_SOURCE_BRANCH = "main"


@dataclass(frozen=True)
class V8Outputs:
    runtime_libs: list[Path]
    link_inputs: list[Path]


def _default_gn_out() -> str:
    arch = platform.machine().lower()
    target_cpu = "arm64" if ("arm64" in arch or "aarch64" in arch) else "x64"
    # DUMBAI: default to host CPU to keep generated binaries ABI-compatible with local Odin builds.
    return f"{target_cpu}.release"


def _is_windows() -> bool:
    return platform.system() == "Windows"


def _is_darwin() -> bool:
    return platform.system() == "Darwin"


def _run(args: list[str], *, cwd: Path) -> None:
    cmd = " ".join(shlex.quote(part) for part in args)
    print(f"[build_cv8] $ {cmd}  (cwd={cwd})")
    env = os.environ.copy()
    if _is_windows():
        # DUMBAI: prefer local VS toolchain on Windows so depot_tools does not
        # require authenticated downloads from Chromium's toolchain bucket.
        env.setdefault("DEPOT_TOOLS_WIN_TOOLCHAIN", "0")
    if DEPOT_TOOLS.exists():
        # DUMBAI: keep depot_tools first on PATH so gn/autoninja resolve predictably for V8 builds.
        env["PATH"] = f"{DEPOT_TOOLS}{os.pathsep}{env.get('PATH', '')}"
    subprocess.run(args, cwd=cwd, check=True, env=env)


def _depot_tool(tool: str) -> str:
    if _is_windows():
        bat = DEPOT_TOOLS / f"{tool}.bat"
        if bat.exists():
            return str(bat)
    return str(DEPOT_TOOLS / tool)


def _resolve_windows_tool(
    tool_name: str,
    *,
    fallback_names: tuple[str, ...] = (),
) -> str | None:
    resolved = shutil.which(tool_name)
    if resolved is not None:
        return resolved

    for fallback in fallback_names:
        resolved = shutil.which(fallback)
        if resolved is not None:
            return resolved

    local_tool_bins = (
        V8_SOURCE / "third_party" / "llvm-build" / "Release+Asserts" / "bin",
    )
    names = (tool_name, *fallback_names)
    for bin_dir in local_tool_bins:
        if not bin_dir.exists():
            continue
        for name in names:
            candidate = bin_dir / name
            if candidate.exists():
                return str(candidate)

    search_roots = [
        Path(os.environ.get("ProgramFiles", "C:\\Program Files")),
        Path(os.environ.get("ProgramFiles(x86)", "C:\\Program Files (x86)")),
    ]
    candidates: list[Path] = []
    for root in search_roots:
        vs_root = root / "Microsoft Visual Studio"
        if not vs_root.exists():
            continue
        for name in names:
            candidates.extend(
                vs_root.glob(
                    f"*/*/VC/Tools/MSVC/*/bin/Hostx64/x64/{name}",
                )
            )

    if not candidates:
        return None

    # DUMBAI: prefer the newest discovered MSVC tool binary so hosts with
    # multiple VS installs use the latest available compiler/linker.
    selected = max(candidates, key=lambda path: path.stat().st_mtime_ns)
    return str(selected)


def _resolve_vcvarsall(tool_path: str) -> Path | None:
    path = Path(tool_path)
    for parent in path.parents:
        if parent.name != "VC":
            continue
        candidate = parent / "Auxiliary" / "Build" / "vcvarsall.bat"
        if candidate.exists():
            return candidate
    return None


def _run_windows_with_vcvars(command: list[str], *, tool_path: str) -> None:
    vcvarsall = _resolve_vcvarsall(tool_path)
    if vcvarsall is None and _is_windows():
        msvc_cl = _resolve_windows_tool("cl.exe")
        if msvc_cl is not None:
            vcvarsall = _resolve_vcvarsall(msvc_cl)
    if vcvarsall is None:
        _run(command, cwd=ROOT)
        return

    target_cmd = subprocess.list2cmdline(command)
    # DUMBAI: run through a temporary batch file to avoid cmd.exe quoting edge
    # cases with long absolute paths containing spaces.
    with tempfile.NamedTemporaryFile(
        mode="w",
        suffix=".bat",
        delete=False,
        dir=ROOT,
        encoding="utf-8",
        newline="\r\n",
    ) as bat_file:
        bat_path = Path(bat_file.name)
        bat_file.write("@echo off\n")
        bat_file.write(f'call "{vcvarsall}" x64 >nul\n')
        bat_file.write("if errorlevel 1 exit /b %errorlevel%\n")
        bat_file.write(f"{target_cmd}\n")
        bat_file.write("exit /b %errorlevel%\n")

    try:
        _run(["cmd", "/c", str(bat_path)], cwd=ROOT)
    finally:
        bat_path.unlink(missing_ok=True)


def _remove_path(path: Path) -> None:
    if not path.exists():
        return
    if path.is_dir():
        # DUMBAI: recursive cleanup is intentional for large generated trees like v8/out.
        shutil.rmtree(path)
    else:
        path.unlink()
    print(f"[build_cv8] removed {path}")


def _ensure_depot_tools() -> None:
    if DEPOT_TOOLS.exists():
        cloned = False
    else:
        cloned = True
        # DUMBAI: bootstrap Chromium toolchain the same way other vendor build scripts fetch missing prerequisites.
        _run(
            [
                "git",
                "clone",
                "--depth=1",
                "https://chromium.googlesource.com/chromium/tools/depot_tools.git",
                str(DEPOT_TOOLS),
            ],
            cwd=ROOT,
        )

    bootstrap_marker = DEPOT_TOOLS / "python3_bin_reldir.txt"
    if cloned or not bootstrap_marker.exists():
        if _is_windows():
            # DUMBAI: ensure_bootstrap is bash-only; Windows bootstrap uses the batch updater.
            _run([str(DEPOT_TOOLS / "update_depot_tools.bat")], cwd=DEPOT_TOOLS)
        else:
            # DUMBAI: ensure_bootstrap initializes cipd-managed depot_tools runtime on Unix hosts.
            _run([str(DEPOT_TOOLS / "ensure_bootstrap")], cwd=DEPOT_TOOLS)


def _ensure_v8_source() -> None:
    if not V8_SOURCE.exists():
        # DUMBAI: clone V8 source as a shallow checkout so first-run bootstrap
        # remains bandwidth-friendly on CI and local developer machines.
        _run(
            [
                "git",
                "clone",
                "--depth=1",
                "--single-branch",
                "--branch",
                V8_SOURCE_BRANCH,
                V8_SOURCE_URL,
                str(V8_SOURCE),
            ],
            cwd=ROOT,
        )

    if not (ROOT / ".gclient").exists():
        if not V8_SOURCE.exists():
            msg = f"Missing .gclient in {ROOT}; cannot bootstrap V8 dependency sync."
            raise FileNotFoundError(msg)
        return

    # DUMBAI: sync dependency graph with no-history mode so third-party repos
    # stay shallow while still matching the configured .gclient solution pins.
    _run([_depot_tool("gclient"), "sync", "--no-history"], cwd=ROOT)
    if not V8_SOURCE.exists():
        msg = f"Expected V8 source checkout not found after sync: {V8_SOURCE}"
        raise FileNotFoundError(msg)


def _ensure_v8_build_metadata() -> None:
    lastchange = V8_SOURCE / "build" / "util" / "LASTCHANGE.committime"
    if lastchange.exists():
        return
    # DUMBAI: regenerate V8 metadata hooks when LASTCHANGE is missing so GN
    # timestamp scripts can run in freshly synced checkouts.
    _run([_depot_tool("gclient"), "sync", "--no-history"], cwd=ROOT)
    if not lastchange.exists():
        msg = f"Missing V8 metadata after sync: {lastchange}"
        raise FileNotFoundError(msg)


def _gn_binary() -> Path:
    if _is_windows():
        return V8_SOURCE / "buildtools" / "win" / "gn.exe"
    if _is_darwin():
        return V8_SOURCE / "buildtools" / "mac" / "gn"
    return V8_SOURCE / "buildtools" / "linux64" / "gn"


def _default_gn_args(*, gn_out: str, link_mode: LinkMode) -> list[str]:
    parts = gn_out.split(".")
    target_cpu = parts[0] if parts else "x64"
    mode = parts[1] if len(parts) > 1 else "release"
    is_debug = mode in {"debug", "dbg"}

    component_build = link_mode == "shared"
    # DUMBAI: keep args.gn deterministic so both shared and static builds remain reproducible across hosts.
    return [
        f"is_component_build = {'true' if component_build else 'false'}",
        f"is_debug = {'true' if is_debug else 'false'}",
        f'target_cpu = "{target_cpu}"',
        f"v8_monolithic = {'false' if component_build else 'true'}",
        "v8_use_external_startup_data = false",
        # DUMBAI: disable Temporal to avoid dragging the full Rust rlib link closure into Odin consumers.
        "v8_enable_temporal_support = false",
        "v8_enable_sandbox = true",
        "v8_enable_backtrace = true",
        "v8_enable_disassembler = true",
        "v8_enable_object_print = true",
        "v8_enable_verify_heap = true",
        f"dcheck_always_on = {'true' if is_debug else 'false'}",
    ]


def _ensure_gn_args(*, gn_out: str, link_mode: LinkMode) -> None:
    out_dir = V8_SOURCE / "out" / gn_out
    out_dir.mkdir(parents=True, exist_ok=True)
    args_file = out_dir / "args.gn"
    # DUMBAI: rewrite args.gn each run so selected link mode is never left stale from prior builds.
    args_file.write_text(
        "\n".join(_default_gn_args(gn_out=gn_out, link_mode=link_mode)) + "\n",
        encoding="utf-8",
    )


def _shared_suffix() -> str:
    if _is_windows():
        return ".dll"
    if _is_darwin():
        return ".dylib"
    return ".so"


def _shared_name(base: str) -> str:
    if _is_windows():
        return f"{base}.dll"
    return f"lib{base}{_shared_suffix()}"


def _static_monolith_name() -> str:
    if _is_windows():
        return "v8_monolith.lib"
    return "libv8_monolith.a"


def _cv8_obj_name() -> str:
    if _is_windows():
        return "cv8.obj"
    return "cv8.o"


def _cv8_lib_name(*, link_mode: LinkMode) -> str:
    if link_mode == "static":
        if _is_windows():
            return "cv8.lib"
        return "libcv8.a"
    return _shared_name("cv8")


def _needs_rebuild(output: Path, *, inputs: list[Path]) -> bool:
    if not output.exists():
        return True

    output_mtime = output.stat().st_mtime_ns
    for path in inputs:
        if path.exists() and path.stat().st_mtime_ns > output_mtime:
            return True
    return False


def _candidate_artifact_paths(*, out_dir: Path, name: str) -> list[Path]:
    # DUMBAI: prefer shallow well-known output locations before falling back to recursive search.
    return [
        out_dir / name,
        out_dir / "obj" / name,
        out_dir / "lib" / name,
    ]


def _find_output_artifact(*, out_dir: Path, name: str) -> Path:
    for candidate in _candidate_artifact_paths(out_dir=out_dir, name=name):
        if candidate.exists():
            return candidate

    matches = sorted(
        (path for path in out_dir.rglob(name) if path.is_file()),
        key=lambda path: (len(path.parts), str(path)),
    )
    if matches:
        return matches[0]

    msg = f"Expected build artifact not found in {out_dir}: {name}"
    raise FileNotFoundError(msg)


def _shared_runtime_names() -> list[str]:
    return [
        _shared_name("v8"),
        _shared_name("v8_libbase"),
        _shared_name("v8_libplatform"),
    ]


def _all_shared_runtime_outputs(*, out_dir: Path) -> list[Path]:
    suffix = _shared_suffix()
    runtime = sorted(path for path in out_dir.glob(f"*{suffix}") if path.is_file())
    if not runtime:
        msg = f"Expected shared libraries not found in {out_dir} (*{suffix})"
        raise FileNotFoundError(msg)
    return runtime


def _shared_windows_link_name_candidates(base: str) -> list[str]:
    # DUMBAI: try both import-lib naming styles because Chromium outputs differ across toolchain revisions.
    return [f"{base}.dll.lib", f"{base}.lib"]


def _resolve_v8_outputs(*, gn_out: str, link_mode: LinkMode) -> V8Outputs:
    out_dir = V8_SOURCE / "out" / gn_out
    if link_mode == "static":
        monolith = out_dir / "obj" / _static_monolith_name()
        if not monolith.exists():
            msg = f"Expected static monolith output not found: {monolith}"
            raise FileNotFoundError(msg)
        return V8Outputs(runtime_libs=[monolith], link_inputs=[monolith])

    required_runtime = [
        _find_output_artifact(out_dir=out_dir, name=name)
        for name in _shared_runtime_names()
    ]
    # DUMBAI: stage full shared closure found in out/<gn-out> root so runtime deps of v8/v8_libbase/v8_libplatform are available.
    runtime = _all_shared_runtime_outputs(out_dir=out_dir)
    required_names = {path.name for path in required_runtime}
    runtime_names = {path.name for path in runtime}
    if not required_names.issubset(runtime_names):
        missing = sorted(required_names - runtime_names)
        msg = f"Missing required shared outputs: {missing}"
        raise FileNotFoundError(msg)

    if _is_windows():
        link_inputs: list[Path] = []
        for base in ("v8", "v8_libbase", "v8_libplatform"):
            link_path: Path | None = None
            for candidate in _shared_windows_link_name_candidates(base):
                try:
                    link_path = _find_output_artifact(out_dir=out_dir, name=candidate)
                    break
                except FileNotFoundError:
                    continue
            if link_path is None:
                msg = (
                    "Expected V8 import library not found for shared build target "
                    f"{base} in {out_dir}"
                )
                raise FileNotFoundError(msg)
            link_inputs.append(link_path)
        libcxx_link: Path | None = None
        for candidate in _shared_windows_link_name_candidates("libc++"):
            try:
                libcxx_link = _find_output_artifact(out_dir=out_dir, name=candidate)
                break
            except FileNotFoundError:
                continue
        if libcxx_link is None:
            msg = (
                "Expected libc++ import library not found for shared build target "
                f"libc++ in {out_dir}"
            )
            raise FileNotFoundError(msg)
        # DUMBAI: shared cv8 uses Chromium's libc++ ABI namespace (__Cr), so
        # link against the matching libc++.dll import library.
        link_inputs.append(libcxx_link)
    else:
        # DUMBAI: Unix shared linking can consume staged dylib/so files directly.
        link_inputs = list(runtime)

    return V8Outputs(runtime_libs=runtime, link_inputs=link_inputs)


def _build_targets(*, link_mode: LinkMode) -> list[str]:
    if link_mode == "static":
        return ["v8_monolith"]
    # DUMBAI: build shared split targets explicitly to guarantee v8/v8_libbase/v8_libplatform are emitted.
    return ["v8", "v8_libbase", "v8_libplatform"]


def _build_v8_outputs(
    *,
    gn_out: str,
    link_mode: LinkMode,
    rebuild_v8: bool,
    skip_v8_build: bool,
) -> V8Outputs:
    if skip_v8_build:
        outputs = _resolve_v8_outputs(gn_out=gn_out, link_mode=link_mode)
        print(f"[build_cv8] reusing existing V8 outputs ({link_mode})")
        return outputs

    if not rebuild_v8:
        try:
            outputs = _resolve_v8_outputs(gn_out=gn_out, link_mode=link_mode)
            print(f"[build_cv8] V8 outputs already exist ({link_mode})")
            return outputs
        except FileNotFoundError:
            pass

    _ensure_depot_tools()
    _ensure_v8_source()
    _ensure_v8_build_metadata()
    gn = _gn_binary()
    if not gn.exists():
        # DUMBAI: recover from partial checkouts by forcing a sync before
        # failing on missing GN tool binaries.
        _run([_depot_tool("gclient"), "sync", "--no-history"], cwd=ROOT)
    if not gn.exists():
        msg = f"Expected gn binary not found: {gn}"
        raise FileNotFoundError(msg)

    _ensure_gn_args(gn_out=gn_out, link_mode=link_mode)

    # DUMBAI: call gn + autoninja directly so we build only requested targets instead of broader gm flows.
    _run([str(gn), "gen", f"out/{gn_out}"], cwd=V8_SOURCE)

    _run(
        [
            _depot_tool("autoninja"),
            "-C",
            f"out/{gn_out}",
            *_build_targets(link_mode=link_mode),
        ],
        cwd=V8_SOURCE,
    )
    return _resolve_v8_outputs(gn_out=gn_out, link_mode=link_mode)


def _stage_monolith_lib(*, monolith: Path) -> Path:
    staged = ROOT / _static_monolith_name()
    if _needs_rebuild(staged, inputs=[monolith]):
        # DUMBAI: stage monolith into vendor/v8 root so Odin foreign imports follow the same flat artifact pattern as other vendor deps.
        shutil.copy2(monolith, staged)
        print(f"[build_cv8] staged monolith {monolith} -> {staged}")
    else:
        print(f"[build_cv8] monolith staging already up to date at {staged}")
    return staged


def _is_thin_archive(path: Path) -> bool:
    probe = subprocess.run(
        ["file", str(path)],
        check=False,
        capture_output=True,
        text=True,
    )
    return "thin archive" in probe.stdout


def _flatten_thin_archive(*, src: Path, dst: Path) -> None:
    llvm_ar = shutil.which("llvm-ar")
    if llvm_ar is None:
        msg = "llvm-ar is required to flatten thin archives on macOS."
        raise RuntimeError(msg)

    listed = subprocess.run(
        [llvm_ar, "t", str(src)],
        check=True,
        capture_output=True,
        text=True,
        cwd=ROOT,
    ).stdout
    members = [line.strip() for line in listed.splitlines() if line.strip()]
    if not members:
        msg = f"Thin archive had no members: {src}"
        raise RuntimeError(msg)

    with tempfile.TemporaryDirectory(prefix="v8-thin-") as tmp:
        out_archive = Path(tmp) / dst.name
        chunk_size = 200
        for idx in range(0, len(members), chunk_size):
            chunk = members[idx : idx + chunk_size]
            resolved = [
                str((ROOT / member).resolve())
                if not Path(member).is_absolute()
                else member
                for member in chunk
            ]
            _run([llvm_ar, "q", str(out_archive), *resolved], cwd=ROOT)
        _run([llvm_ar, "s", str(out_archive)], cwd=ROOT)
        shutil.copy2(out_archive, dst)


def _archive_member_count(path: Path) -> int:
    probe = subprocess.run(
        ["ar", "t", str(path)],
        check=False,
        capture_output=True,
        text=True,
    )
    if probe.returncode != 0:
        return 0
    return sum(1 for line in probe.stdout.splitlines() if line.strip())


def _stage_static_support_libs(*, gn_out: str) -> list[Path]:
    obj_root = V8_SOURCE / "out" / gn_out / "obj"
    if _is_windows():
        # DUMBAI: Chromium's Windows static outputs are .lib files without lib* prefixes.
        staged_pairs: list[tuple[Path, Path]] = [
            (obj_root / "v8_libbase.lib", ROOT / "v8_libbase.lib"),
            (obj_root / "v8_libplatform.lib", ROOT / "v8_libplatform.lib"),
        ]
    else:
        staged_pairs = [
            (obj_root / "libv8_libbase.a", ROOT / "libv8_libbase.a"),
            (obj_root / "libv8_libplatform.a", ROOT / "libv8_libplatform.a"),
        ]
    if _is_darwin():
        staged_pairs.extend(
            [
                (
                    obj_root / "buildtools" / "third_party" / "libc++" / "libc++.a",
                    ROOT / "libv8_libcxx.a",
                ),
                (
                    obj_root
                    / "buildtools"
                    / "third_party"
                    / "libc++abi"
                    / "libc++abi.a",
                    ROOT / "libv8_libcxxabi.a",
                ),
            ]
        )

    staged: list[Path] = []
    for src, dst in staged_pairs:
        if not src.exists():
            msg = f"Expected support library not found: {src}"
            raise FileNotFoundError(msg)
        should_restage = _needs_rebuild(dst, inputs=[src])
        if (
            not should_restage
            and _is_darwin()
            and dst.exists()
            and _is_thin_archive(dst)
        ):
            # DUMBAI: if a previous run copied a thin archive, regenerate it as a regular archive for Apple ld compatibility.
            should_restage = True
        if (
            not should_restage
            and _is_darwin()
            and dst.exists()
            and _is_thin_archive(src)
            and _archive_member_count(dst) <= 1
        ):
            # DUMBAI: recover from broken one-member wrappers produced by earlier libtool-based staging of thin archives.
            should_restage = True

        if should_restage:
            if _is_darwin() and _is_thin_archive(src):
                # DUMBAI: Apple ld rejects thin archives; flatten into regular archives before staging.
                _flatten_thin_archive(src=src, dst=dst)
            else:
                # DUMBAI: non-mac toolchains in this repo accept staged archive copies as-is.
                shutil.copy2(src, dst)
            print(f"[build_cv8] staged support lib {src} -> {dst}")
        else:
            print(f"[build_cv8] support lib staging already up to date at {dst}")
        staged.append(dst)
    return staged


def _darwin_list_dependencies(path: Path) -> list[str]:
    probe = subprocess.run(
        ["otool", "-L", str(path)],
        check=True,
        capture_output=True,
        text=True,
    )
    deps: list[str] = []
    for line in probe.stdout.splitlines()[1:]:
        stripped = line.strip()
        if not stripped:
            continue
        deps.append(stripped.split(" (", 1)[0])
    return deps


def _rewrite_darwin_shared_install_names(*, staged_libs: list[Path]) -> None:
    install_name_tool = shutil.which("install_name_tool")
    if install_name_tool is None:
        msg = "install_name_tool is required for staging shared V8 libraries on macOS."
        raise RuntimeError(msg)

    staged_names = {path.name for path in staged_libs}
    for lib in staged_libs:
        # DUMBAI: give staged shared libs a stable rpath-based install id so binaries can run from copied artifact folders.
        _run([install_name_tool, "-id", f"@rpath/{lib.name}", str(lib)], cwd=ROOT)
        for dep in _darwin_list_dependencies(lib):
            dep_name = Path(dep).name
            if dep_name not in staged_names:
                continue
            # DUMBAI: force sibling shared-library resolution so moving staged artifacts keeps runtime loading intact.
            _run(
                [
                    install_name_tool,
                    "-change",
                    dep,
                    f"@loader_path/{dep_name}",
                    str(lib),
                ],
                cwd=ROOT,
            )


def _stage_shared_runtime_libs(*, runtime_libs: list[Path]) -> list[Path]:
    staged: list[Path] = []
    for src in runtime_libs:
        dst = ROOT / src.name
        if _needs_rebuild(dst, inputs=[src]):
            # DUMBAI: keep shared runtime outputs in vendor root so Odin foreign imports stay shallow and consistent.
            shutil.copy2(src, dst)
            print(f"[build_cv8] staged shared lib {src} -> {dst}")
        else:
            print(f"[build_cv8] shared staging already up to date at {dst}")
        staged.append(dst)

    if _is_darwin():
        _rewrite_darwin_shared_install_names(staged_libs=staged)

    return staged


def _build_cv8_shim(
    *,
    link_mode: LinkMode,
    gn_out: str,
    rebuild_cv8: bool,
    v8_link_inputs: list[Path],
) -> Path:
    cv8_cc = ROOT / "cv8.cc"
    cv8_h = ROOT / "cv8.h"
    cv8_obj = ROOT / _cv8_obj_name()
    cv8_lib = ROOT / _cv8_lib_name(link_mode=link_mode)

    # DUMBAI: rebuild shim when C++ shim sources or dependent V8 link artifacts changed.
    if not rebuild_cv8 and not _needs_rebuild(
        cv8_lib, inputs=[cv8_cc, cv8_h, *v8_link_inputs]
    ):
        print(f"[build_cv8] cv8 shim already up to date at {cv8_lib}")
        return cv8_lib

    if _is_windows():
        compiler = _resolve_windows_tool("clang-cl.exe", fallback_names=("cl.exe",))
        if compiler is None:
            msg = "Missing Windows C/C++ compiler. Install VS C++ tools or expose cl/clang-cl on PATH."
            raise RuntimeError(msg)

        compile_cmd = [
            compiler,
            "/nologo",
            "/std:c++20",
            "/Zc:__cplusplus",
            "/O2",
            "/EHsc",
            # DUMBAI: keep cv8 compiled against Chromium's libc++ ABI namespace
            # so shared-mode symbols match V8 DLL exports on Windows.
            "/D_LIBCPP_HARDENING_MODE=_LIBCPP_HARDENING_MODE_EXTENSIVE",
            "/D_LIBCPP_DISABLE_VISIBILITY_ANNOTATIONS",
            "/I",
            "v8",
            "/I",
            "v8\\include",
            "/I",
            "v8\\buildtools\\third_party\\libc++",
            "/I",
            "v8\\third_party\\libc++\\src\\include",
            "/c",
            "cv8.cc",
            f"/Fo{cv8_obj.name}",
        ]
        _run_windows_with_vcvars(compile_cmd, tool_path=compiler)

        if link_mode == "static":
            archiver = _resolve_windows_tool("llvm-lib.exe", fallback_names=("lib.exe",))
            if archiver is None:
                msg = "Missing Windows librarian. Install VS C++ tools or expose lib/llvm-lib on PATH."
                raise RuntimeError(msg)
            _run_windows_with_vcvars(
                [archiver, "/nologo", f"/OUT:{cv8_lib.name}", cv8_obj.name],
                tool_path=archiver,
            )
        else:
            linker = _resolve_windows_tool("lld-link.exe", fallback_names=("link.exe",))
            if linker is None:
                msg = "Missing Windows linker. Install VS C++ tools or expose link/lld-link on PATH."
                raise RuntimeError(msg)
            # DUMBAI: shared mode links cv8.dll against V8 import libs so executables avoid static monolith linkage.
            _run_windows_with_vcvars(
                [
                    linker,
                    "/nologo",
                    "/DLL",
                    f"/OUT:{cv8_lib.name}",
                    "/IMPLIB:cv8.lib",
                    cv8_obj.name,
                    *[str(path) for path in v8_link_inputs],
                ],
                tool_path=linker,
            )
    else:
        cxx = os.environ.get("CXX") or shutil.which("clang++") or shutil.which("g++")
        if cxx is None:
            msg = "No C++ compiler found. Set CXX or install clang++/g++."
            raise RuntimeError(msg)

        command = [
            cxx,
            "-std=c++20",
            "-O2",
            "-fno-exceptions",
            "-fno-rtti",
            # DUMBAI: keep embedder compile-time V8 ABI flags aligned with V8 defaults to avoid runtime config mismatch aborts.
            "-DV8_COMPRESS_POINTERS",
            "-DV8_COMPRESS_POINTERS_IN_SHARED_CAGE",
            "-DV8_31BIT_SMIS_ON_64BIT_ARCH",
            "-DV8_ENABLE_SANDBOX",
            "-I",
            "v8",
            "-I",
            "v8/include",
            "-c",
            "cv8.cc",
            "-o",
            cv8_obj.name,
        ]
        if link_mode == "shared":
            # DUMBAI: PIC is required so cv8 can be emitted as a shared object.
            command.append("-fPIC")
        if _is_darwin():
            # DUMBAI: compile cv8 against Chromium's libc++ headers so ABI namespace (__Cr) matches V8 binaries.
            command.extend(
                [
                    "-D_LIBCPP_HARDENING_MODE=_LIBCPP_HARDENING_MODE_EXTENSIVE",
                    "-D_LIBCPP_DISABLE_VISIBILITY_ANNOTATIONS",
                    "-D_LIBCXXABI_DISABLE_VISIBILITY_ANNOTATIONS",
                    "-nostdinc++",
                    "-isystem",
                    f"v8/out/{gn_out}/gen/third_party/libc++/src/include",
                    "-isystem",
                    "v8/third_party/libc++abi/src/include",
                ]
            )
        _run(command, cwd=ROOT)

        if link_mode == "static":
            ar = os.environ.get("AR") or shutil.which("ar")
            if ar is None:
                msg = "No archiver found. Set AR or install ar."
                raise RuntimeError(msg)
            _run([ar, "rcs", cv8_lib.name, cv8_obj.name], cwd=ROOT)
        elif _is_darwin():
            # DUMBAI: dynamic shim links against staged dylibs and exports a stable @rpath id for consumer binaries.
            _run(
                [
                    cxx,
                    "-dynamiclib",
                    "-o",
                    cv8_lib.name,
                    cv8_obj.name,
                    *[str(path) for path in v8_link_inputs],
                    "-Wl,-install_name,@rpath/libcv8.dylib",
                    "-Wl,-rpath,@loader_path",
                ],
                cwd=ROOT,
            )
        else:
            # DUMBAI: Linux shared shim embeds $ORIGIN rpath so colocated staged libs are discovered at runtime.
            _run(
                [
                    cxx,
                    "-shared",
                    "-o",
                    cv8_lib.name,
                    cv8_obj.name,
                    *[str(path) for path in v8_link_inputs],
                    "-Wl,-rpath,$ORIGIN",
                ],
                cwd=ROOT,
            )

    if not cv8_lib.exists():
        msg = f"Expected cv8 output not found: {cv8_lib}"
        raise FileNotFoundError(msg)
    return cv8_lib


def _cleanup_artifacts(*, clean_all: bool) -> None:
    # DUMBAI: remove both static and shared staged outputs so mode switches cannot leave stale link artifacts.
    staged_names = [
        "libv8_monolith.a",
        "v8_monolith.lib",
        "libv8_libbase.a",
        "libv8_libplatform.a",
        "v8_libbase.lib",
        "v8_libplatform.lib",
        "libv8_libcxx.a",
        "libv8_libcxxabi.a",
        "libv8.so",
        "libv8.dylib",
        "v8.dll",
        "libv8_libbase.so",
        "libv8_libbase.dylib",
        "v8_libbase.dll",
        "libv8_libplatform.so",
        "libv8_libplatform.dylib",
        "v8_libplatform.dll",
        "libcv8.a",
        "libcv8.so",
        "libcv8.dylib",
        "cv8.lib",
        "cv8.dll",
        "cv8.exp",
        "cv8.ilk",
        "cv8.pdb",
        "cv8.o",
        "cv8.obj",
    ]
    for name in staged_names:
        _remove_path(ROOT / name)

    # DUMBAI: V8 out tree dominates disk usage; clear it by default during cleanup.
    _remove_path(V8_SOURCE / "out")

    if clean_all:
        # DUMBAI: full cleanup removes fetched toolchains/sources for maximum disk recovery.
        _remove_path(V8_SOURCE)
        _remove_path(DEPOT_TOOLS)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        prog="build_cv8.py",
        description="Build/refresh V8 (shared or static) and cv8 shim for Odin integration.",
    )
    parser.add_argument(
        "--gn-out",
        default=_default_gn_out(),
        # DUMBAI: default value resolves at runtime so one script works for both x64 and arm64 hosts.
        help="V8 GN output folder under v8/out (default: <host-cpu>.release).",
    )
    parser.add_argument(
        "--link-mode",
        choices=["shared", "static"],
        default="shared",
        # DUMBAI: shared is default to reduce disk/link pressure; static remains available for fully self-contained binaries.
        help="Build/link mode for V8 and cv8 outputs (default: shared).",
    )
    parser.add_argument(
        "--skip-v8-build",
        action="store_true",
        # DUMBAI: V8 build flow is direct gn/autoninja; skip flag reuses previously built outputs from selected link mode.
        help="Do not invoke gn/autoninja; require existing V8 outputs for the selected mode.",
    )
    parser.add_argument(
        "--rebuild-v8",
        action="store_true",
        help="Force rebuilding V8 outputs even when target artifacts already exist.",
    )
    parser.add_argument(
        "--rebuild-cv8",
        action="store_true",
        help="Force rebuilding cv8 shim even when output is up to date.",
    )
    parser.add_argument(
        "--clean",
        action="store_true",
        # DUMBAI: standard cleanup keeps source checkout but deletes staged outputs and v8/out intermediates.
        help="Remove staged artifacts and v8/out build intermediates, then exit.",
    )
    parser.add_argument(
        "--clean-all",
        action="store_true",
        # DUMBAI: full cleanup removes source/tooling checkouts as well for maximal disk recovery.
        help="Like --clean, plus remove vendor/v8/v8 and vendor/v8/depot_tools.",
    )
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    link_mode: LinkMode = args.link_mode

    if args.clean or args.clean_all:
        _cleanup_artifacts(clean_all=args.clean_all)
        return 0

    outputs = _build_v8_outputs(
        gn_out=args.gn_out,
        link_mode=link_mode,
        rebuild_v8=args.rebuild_v8,
        skip_v8_build=args.skip_v8_build,
    )

    if link_mode == "static":
        staged_runtime = [_stage_monolith_lib(monolith=outputs.runtime_libs[0])]
        staged_support = _stage_static_support_libs(gn_out=args.gn_out)
        cv8_link_inputs = [outputs.runtime_libs[0]]
    else:
        staged_runtime = _stage_shared_runtime_libs(runtime_libs=outputs.runtime_libs)
        staged_support = []
        cv8_link_inputs = outputs.link_inputs if _is_windows() else staged_runtime

    cv8_lib = _build_cv8_shim(
        link_mode=link_mode,
        gn_out=args.gn_out,
        rebuild_cv8=args.rebuild_cv8,
        v8_link_inputs=cv8_link_inputs,
    )

    print(f"[build_cv8] ready: link_mode={link_mode}")
    print(f"[build_cv8] ready: v8_runtime={outputs.runtime_libs}")
    print(f"[build_cv8] ready: staged_runtime={staged_runtime}")
    if staged_support:
        print(f"[build_cv8] ready: staged_support={staged_support}")
    print(f"[build_cv8] ready: cv8={cv8_lib}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
