@echo off
setlocal

rem DUMBAI: keep a vendor-root Windows build entrypoint so V8 matches other vendor scripts with DLL mode as default.
set SCRIPT_DIR=%~dp0

if defined PYTHON (
    set PYTHON_BIN=%PYTHON%
) else (
    set PYTHON_BIN=python
)

"%PYTHON_BIN%" "%SCRIPT_DIR%scripts\build_cv8.py" %*
exit /b %ERRORLEVEL%
