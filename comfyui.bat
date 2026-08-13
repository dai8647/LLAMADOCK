@echo off
chcp 65001 >nul
setlocal
title LlamaDock - ComfyUI

powershell.exe -ExecutionPolicy Bypass -NoProfile -File "%~dp0select-model.ps1" -ClientMode ComfyUI

if %ERRORLEVEL% neq 0 (
    echo ComfyUI launch failed
    pause
)
