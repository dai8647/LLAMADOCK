@echo off
echo ========================================
echo  MCP Filesystem Server
echo ========================================
echo.

cd /d "%~dp0"
if not exist "%~dp0mcp-share" mkdir "%~dp0mcp-share"

echo Allowed directory:
echo   %~dp0mcp-share
echo.
echo MCP endpoint: http://127.0.0.1:3101/mcp
echo.

npx mcp-proxy --shell --host 127.0.0.1 --port 3101 --server stream --streamEndpoint /mcp -- npx -y @modelcontextprotocol/server-filesystem "%~dp0mcp-share"

echo.
echo MCP filesystem server stopped.
pause
