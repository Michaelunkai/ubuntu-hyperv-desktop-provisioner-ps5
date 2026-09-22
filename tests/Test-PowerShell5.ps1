#requires -Version 5.1

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
$scriptPath = Join-Path $projectRoot 'Install-UbuntuHyperVDesktop.ps1'
if (-not (Test-Path -LiteralPath $scriptPath)) { throw "Missing script: $scriptPath" }

$tokens = $null
$errors = $null
[System.Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$tokens, [ref]$errors) | Out-Null
if ($errors.Count -gt 0) {
    $messages = $errors | ForEach-Object { "line $($_.Extent.StartLineNumber): $($_.Message)" }
    throw ('PowerShell 5.1 parser errors: ' + ($messages -join '; '))
}

$source = Get-Content -LiteralPath $scriptPath -Raw
$requiredText = @(
    '#requires -Version 5.1',
    "`$VMName = 'Ubuntu-Desktop-Auto'",
    "`$GuestUsername = 'ubuntu'",
    "`$GuestPassword = 'ubuntu'",
    'source:',
    'id: ubuntu-desktop',
    'autoinstall',
    'ds=nocloud\;s=/cdrom/nocloud/',
    'layerfs-path=minimal.standard.live.squashfs',
    'xorriso',
    'shutdown: poweroff',
    'AutomaticLoginEnable=true',
    'AutomaticLogin=$GuestUsername',
    'gnome-initial-setup-done',
    'gnome-initial-setup/upgrade-',
    'gnome-initial-s',
    'loginctl show-session',
    'Wait-ForGuestDesktop',
    'legacyInputsHash',
    'systemctl get-default',
    'Set-VMFirmware'
)
foreach ($text in $requiredText) {
    if ($source -notlike "*$text*") { throw "Static assertion failed; missing: $text" }
}

Write-Host 'PowerShell 5.1 parser/static test passed.' -ForegroundColor Green
Write-Host 'No Hyper-V feature, VM, ISO, network switch, or guest was changed.' -ForegroundColor Green
