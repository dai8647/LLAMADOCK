@echo off
chcp 65001 >nul
setlocal
title LlamaDock

REM Keep Python and child CLI processes on the same UTF-8 boundary.
set "PYTHONUTF8=1"
set "PYTHONIOENCODING=utf-8"

REM Optional ROCm path for local Windows builds.
set HIP_PATH=
for /f "delims=" %%D in ('dir /b /ad /o-n "C:\Program Files\AMD\ROCm" 2^>nul') do (
    if not defined HIP_PATH set "HIP_PATH=C:\Program Files\AMD\ROCm\%%D"
)
if defined HIP_PATH set "PATH=%HIP_PATH%\bin;%PATH%"

powershell.exe -ExecutionPolicy Bypass -NoProfile -File "%~dp0select-model.ps1"

echo.
if %ERRORLEVEL% neq 0 (
    echo LlamaDock exited with error
    pause
)
