@echo off
echo ========================================
echo  MCP Optional Stack
echo ========================================
echo.

cd /d "%~dp0"

call :start_if_down "Context7" 3103 "mcp-context7.bat"
call :start_if_down "MarkItDown" 3104 "mcp-markitdown.bat"
call :start_if_down "Playwright" 3105 "mcp-playwright.bat"

echo.
echo Optional MCP stack requested.
echo.
echo Endpoints:
echo   Context7   : http://127.0.0.1:3103/mcp
echo   MarkItDown : http://127.0.0.1:3104/mcp
echo   Playwright : http://localhost:3105/mcp
echo.
exit /b 0

:start_if_down
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "try { $c = New-Object Net.Sockets.TcpClient; $iar = $c.BeginConnect('localhost', %~2, $null, $null); if ($iar.AsyncWaitHandle.WaitOne(1000, $false)) { $c.EndConnect($iar); $c.Close(); exit 0 } else { $c.Close(); exit 1 } } catch { exit 1 }"
if %ERRORLEVEL% neq 0 (
    echo Starting MCP %~1 server...
    start "MCP %~1" /min cmd /k "%~dp0%~3"
    timeout /t 3 /nobreak >nul
) else (
    echo MCP %~1 server already running.
)
exit /b 0
