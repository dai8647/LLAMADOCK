$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$Launcher = Join-Path $ScriptDir "llamadock.bat"
$ShortcutPath = Join-Path $ScriptDir "LlamaDock.lnk"

if (-not (Test-Path $Launcher)) {
    Write-Error "Launcher not found: $Launcher"
    exit 1
}

$WshShell = New-Object -ComObject WScript.Shell
$Shortcut = $WshShell.CreateShortcut($ShortcutPath)
$Shortcut.TargetPath = $Launcher
$Shortcut.WorkingDirectory = $ScriptDir
$Shortcut.Description = "LlamaDock local GGUF workspace launcher"
$Shortcut.Save()

Write-Output "Shortcut created: $ShortcutPath"
