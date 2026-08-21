@echo off
chcp 65001 >nul
title LlamaDock Web GUI
setlocal
set "LLAMADOCK_GUI_URL=http://127.0.0.1:3000"

rem Open the browser only after the server answers /api/health.
start "" /min powershell -NoProfile -ExecutionPolicy Bypass -Command "$u='http://127.0.0.1:3000/api/health'; for($i=0;$i -lt 120;$i++){try{Invoke-RestMethod $u -TimeoutSec 1|Out-Null;break}catch{Start-Sleep -Milliseconds 500}}; Start-Process 'http://127.0.0.1:3000'"

node "%~dp0web-ui\server.js"
if errorlevel 1 (
    echo.
    echo ERROR: LlamaDock Web GUI failed to start ^(node exited with an error^).
    echo Check the message above, then press any key to close this window.
    pause >nul
)
endlocal
