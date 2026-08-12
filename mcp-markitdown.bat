@echo off
echo ========================================
echo  MCP MarkItDown Server
echo ========================================
echo.

cd /d "%~dp0"

echo MCP endpoint: http://127.0.0.1:3104/mcp
echo.
echo Converts PDF, Office, HTML, images, audio, and URLs to Markdown.
echo.

uvx --from markitdown-mcp markitdown-mcp --http --host 127.0.0.1 --port 3104

echo.
echo MCP MarkItDown server stopped.
pause
