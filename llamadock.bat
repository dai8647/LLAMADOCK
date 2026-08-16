@echo off
chcp 65001 >nul
setlocal
title LlamaDock

REM Keep Python and child CLI processes on the same UTF-8 boundary.
set "PYTHONUTF8=1"
set "PYTHONIOENCODING=utf-8"

REM Optional ROCm path for local Windows builds.
set HIP_PATH=
for /f "delims=" %%D in ('powershell -NoProfile -Command "Get-ChildItem 'C:\Program Files\AMD\ROCm' -Directory -ErrorAction SilentlyContinue | Sort-Object { [version]($_.Name -replace '^[^0-9]*','') } -Descending | Select-Object -First 1 -ExpandProperty Name"') do (
    if not defined HIP_PATH set "HIP_PATH=C:\Program Files\AMD\ROCm\%%D"
)
if defined HIP_PATH set "PATH=%HIP_PATH%\bin;%PATH%"

powershell.exe -ExecutionPolicy Bypass -NoProfile -File "%~dp0select-model.ps1"

echo.
if %ERRORLEVEL% neq 0 (
    echo LlamaDock exited with error
    pause
)
