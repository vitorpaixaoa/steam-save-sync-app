param([switch]$Uninstall)

# Instala o Steam Save Sync para o usuario atual (sem precisar de administrador):
# copia os arquivos para %LOCALAPPDATA%\Programs\SaveSync e cria atalhos na
# area de trabalho e no menu Iniciar. Use -Uninstall para remover.

$ErrorActionPreference = 'Stop'
$appName = 'Steam Save Sync'
$dest    = Join-Path $env:LOCALAPPDATA 'Programs\SaveSync'
$links   = @(
    (Join-Path ([Environment]::GetFolderPath('Desktop'))  "$appName.lnk"),
    (Join-Path ([Environment]::GetFolderPath('Programs')) "$appName.lnk")
)

if ($Uninstall) {
    foreach ($l in $links) { if (Test-Path $l) { Remove-Item $l -Force } }
    if (Test-Path $dest) { Remove-Item $dest -Recurse -Force }
    Write-Host "$appName removido."
    Write-Host "Backups e preferencias continuam em $env:LOCALAPPDATA\SaveSync (apague manualmente se quiser)."
    return
}

New-Item -ItemType Directory -Force $dest | Out-Null
foreach ($f in 'SaveSync.ps1', 'SaveSync.ico') {
    Copy-Item (Join-Path $PSScriptRoot $f) $dest -Force
}

$shell = New-Object -ComObject WScript.Shell
foreach ($l in $links) {
    $s = $shell.CreateShortcut($l)
    $s.TargetPath       = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $s.Arguments        = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$dest\SaveSync.ps1`""
    $s.WorkingDirectory = $dest
    $s.IconLocation     = "$dest\SaveSync.ico,0"
    $s.WindowStyle      = 7
    $s.Description      = 'Sincroniza saves de jogos entre contas Steam deste PC'
    $s.Save()
}

Write-Host "$appName instalado em $dest"
Write-Host 'Atalhos criados na area de trabalho e no menu Iniciar.'
