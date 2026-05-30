#Requires -Version 5.1
<#
  Runs under the ansible Windows user (via Invoke-AsUser).
  Updates DistributionName's BasePath in HKCU\...\Lxss.
#>
param(
    [Parameter(Mandatory)]
    [string]$DistroName,

    [Parameter(Mandatory)]
    [string]$BasePath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Lxss'
if (-not (Test-Path -LiteralPath $root)) {
    Write-Error "Lxss key not found in this user's HKCU ($env:USERPROFILE)."
    exit 2
}

foreach ($key in Get-ChildItem -LiteralPath $root | Where-Object { $_.PSChildName -match '^\{' }) {
    $props = Get-ItemProperty -LiteralPath $key.PSPath
    if ($props.DistributionName -eq $DistroName) {
        Set-ItemProperty -LiteralPath $key.PSPath -Name BasePath -Value $BasePath
        exit 0
    }
}

Write-Error "Distro '$DistroName' not found in Lxss."
exit 3
