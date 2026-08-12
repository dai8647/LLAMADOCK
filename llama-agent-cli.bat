@echo off
title llama-agent
cd /d "%~dp0"
powershell.exe -ExecutionPolicy Bypass -NoProfile -File "%~dp0select-model.ps1" -PresetMode LlamaAgentResearch -ClientMode LlamaAgent
pause
