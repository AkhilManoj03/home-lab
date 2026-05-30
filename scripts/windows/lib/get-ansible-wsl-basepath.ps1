#Requires -Version 5.1
param(
    [Parameter(Mandatory)]
    [string]$DistroName
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Lxss'
if (-not (Test-Path -LiteralPath $root)) { exit 1 }

foreach ($key in Get-ChildItem -LiteralPath $root | Where-Object { $_.PSChildName -match '^\{' }) {
    $props = Get-ItemProperty -LiteralPath $key.PSPath
    if ($props.DistributionName -eq $DistroName) {
        Write-Output $props.BasePath
        exit 0
    }
}

exit 2
