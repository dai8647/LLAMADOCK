@echo off
echo ========================================
echo  Restart MCP Web Search Server
echo ========================================
echo.

powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "$owners = Get-NetTCPConnection -LocalPort 3100 -ErrorAction SilentlyContinue | Select-Object -ExpandProperty OwningProcess -Unique; foreach ($owner in $owners) { Stop-Process -Id $owner -Force -ErrorAction SilentlyContinue }"

cd /d "%~dp0"
start "MCP Web Search" /min cmd /k "%~dp0mcp-server.bat"

echo Restart requested.
echo MCP endpoint: http://127.0.0.1:3100/mcp
echo.
pause
