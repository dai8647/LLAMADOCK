@echo off
echo ========================================
echo  MCP Playwright Browser Server
echo ========================================
echo.

cd /d "%~dp0"
if not exist "%~dp0mcp-browser-output" mkdir "%~dp0mcp-browser-output"

echo MCP endpoint: http://localhost:3105/mcp
echo.
echo This one is heavier because it can launch/control a browser.
echo.

npx @playwright/mcp --host localhost --port 3105 --browser chrome --output-dir "%~dp0mcp-browser-output"

echo.
echo MCP Playwright server stopped.
pause
