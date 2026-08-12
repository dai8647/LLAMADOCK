param([int]$Port = 8000)
$listeners = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue
foreach ($listener in $listeners) {
    if ($listener.OwningProcess -gt 0) { Stop-Process -Id $listener.OwningProcess -Force -ErrorAction SilentlyContinue }
}
Write-Host "Computer stopped on 127.0.0.1:$Port" -ForegroundColor Cyan
