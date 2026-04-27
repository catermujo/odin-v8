@echo off
setlocal

rem DUMBAI: keep explicit static alias so callers can opt out of default shared-library builds.
call "%~dp0build.bat" --link-mode=static %*
exit /b %ERRORLEVEL%
