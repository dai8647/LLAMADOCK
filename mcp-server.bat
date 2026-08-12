@echo off
echo ========================================
echo  MCP Web Search Server
echo ========================================
echo.

cd /d "%~dp0"

echo Starting MCP server on http://127.0.0.1:3100 ...
echo MCP endpoint: http://127.0.0.1:3100/mcp
echo.

node mcp-server.js

echo.
echo MCP server stopped.
pause
