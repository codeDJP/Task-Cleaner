# Safe Background Task Killer - installer
# Creates Desktop + Start Menu shortcuts that point at this folder. Run again with -Uninstall to remove them.
param([switch]$Uninstall)

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$name = 'Safe Background Task Killer'
$targets = @(
    (Join-Path ([Environment]::GetFolderPath('Desktop')) "$name.lnk"),
    (Join-Path ([Environment]::GetFolderPath('Programs')) "$name.lnk"),
    (Join-Path ([Environment]::GetFolderPath('Desktop')) "$name (Quick Purge).lnk")
)

if ($Uninstall) {
    foreach ($t in $targets) { Remove-Item -LiteralPath $t -ErrorAction SilentlyContinue }
    Write-Host "Removed the $name shortcuts." -ForegroundColor Green
    return
}

# Files downloaded as a ZIP are marked "from the internet"; unblock them so PowerShell can run them.
Get-ChildItem -Path $here -File | Unblock-File -ErrorAction SilentlyContinue

$shell = New-Object -ComObject WScript.Shell
function New-Shortcut([string]$path, [string]$launcher, [string]$description, [string]$icon = 'icon.ico') {
    $sc = $shell.CreateShortcut($path)
    $sc.TargetPath = Join-Path $env:SystemRoot 'System32\wscript.exe'
    $sc.Arguments = "`"$(Join-Path $here $launcher)`""
    $sc.WorkingDirectory = $here
    $sc.IconLocation = "$(Join-Path $here $icon),0"
    $sc.Description = $description
    $sc.Save()
}

New-Shortcut $targets[0] 'run_app.vbs' 'Open the dashboard: see background apps and purge them while visible apps stay safe.'
New-Shortcut $targets[1] 'run_app.vbs' 'Open the dashboard: see background apps and purge them while visible apps stay safe.'
New-Shortcut $targets[2] 'run_silent.vbs' 'One click: close background apps now and show a small summary.' 'quick.ico'

Write-Host ""
Write-Host "  $name is installed." -ForegroundColor Green
Write-Host "  Desktop:    '$name' (dashboard) and '$name (Quick Purge)' (one click)"
Write-Host "  Start Menu: '$name'"
Write-Host ""
