@echo off
echo ========================================
echo  MCP Context7 Server
echo ========================================
echo.

cd /d "%~dp0"

echo MCP endpoint: http://127.0.0.1:3103/mcp
echo.
echo Tip: ask coding/doc questions with "use context7".
echo.

npx @upstash/context7-mcp --transport http --port 3103

echo.
echo MCP Context7 server stopped.
pause
