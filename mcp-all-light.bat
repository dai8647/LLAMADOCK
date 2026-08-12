@echo off
echo ========================================
echo  MCP Light Stack
echo ========================================
echo.

cd /d "%~dp0"

call :start_if_down "Web Search" 3100 "mcp-server.bat"
call :start_if_down "Filesystem" 3101 "mcp-filesystem.bat"
call :start_if_down "Memory" 3102 "mcp-memory.bat"

echo.
echo Light MCP stack requested.
echo.
echo Endpoints:
echo   Web Search : http://127.0.0.1:3100/mcp
echo   Filesystem : http://127.0.0.1:3101/mcp
echo   Memory     : http://127.0.0.1:3102/mcp
echo.
exit /b 0

:start_if_down
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "try { $c = New-Object Net.Sockets.TcpClient; $iar = $c.BeginConnect('127.0.0.1', %~2, $null, $null); if ($iar.AsyncWaitHandle.WaitOne(1000, $false)) { $c.EndConnect($iar); $c.Close(); exit 0 } else { $c.Close(); exit 1 } } catch { exit 1 }"
if %ERRORLEVEL% neq 0 (
    echo Starting MCP %~1 server...
    start "MCP %~1" /min cmd /k "%~dp0%~3"
    timeout /t 2 /nobreak >nul
) else (
    echo MCP %~1 server already running.
)
exit /b 0
