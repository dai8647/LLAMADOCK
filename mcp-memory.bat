@echo off
echo ========================================
echo  MCP Memory Server
echo ========================================
echo.

cd /d "%~dp0"
if not exist "%~dp0mcp-data" mkdir "%~dp0mcp-data"
set MEMORY_FILE_PATH=%~dp0mcp-data\memory.jsonl

echo Memory file:
echo   %MEMORY_FILE_PATH%
echo.
echo MCP endpoint: http://127.0.0.1:3102/mcp
echo.

npx mcp-proxy --shell --host 127.0.0.1 --port 3102 --server stream --streamEndpoint /mcp -- npx -y @modelcontextprotocol/server-memory

echo.
echo MCP memory server stopped.
pause
