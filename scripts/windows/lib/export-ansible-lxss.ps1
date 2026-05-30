#Requires -Version 5.1
<#
  Runs under the ansible Windows user (via Invoke-AsUser).
  Reads HKCU\...\Lxss and writes JSON for import into NTUSER.DAT.
#>
param(
    [Parameter(Mandatory)]
    [string]$OutJson
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Export-RegKeyNode {
    param([string]$Path)
    $item = Get-Item -LiteralPath $Path
    $props = @()
    if ($item.Property) {
        foreach ($name in @($item.Property)) {
            $kind = $item.GetValueKind($name)
            $val  = $item.GetValue($name)
            $stored = switch ($kind.ToString()) {
                'Binary'      { [Convert]::ToBase64String([byte[]]$val) }
                'MultiString' { ,@($val) }
                default       { $val }
            }
            $props += [ordered]@{
                Name  = $name
                Kind  = $kind.ToString()
                Value = $stored
            }
        }
    }
    $children = @()
    foreach ($sub in @(Get-ChildItem -LiteralPath $Path -ErrorAction SilentlyContinue)) {
        $children += Export-RegKeyNode -Path $sub.PSPath
    }
    return [ordered]@{
        KeyName    = $item.PSChildName
        Properties = $props
        Children   = $children
    }
}

$lxssPath = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Lxss'
if (-not (Test-Path -LiteralPath $lxssPath)) {
    Write-Error "Lxss key not found in this user's HKCU ($env:USERPROFILE)."
    exit 2
}

$payload = [ordered]@{
    UserProfile = $env:USERPROFILE
    ExportedAt  = (Get-Date).ToString('o')
    Lxss        = Export-RegKeyNode -Path $lxssPath
}

$dir = Split-Path -Parent $OutJson
if (-not (Test-Path -LiteralPath $dir)) {
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
}

$payload | ConvertTo-Json -Depth 40 -Compress | Set-Content -LiteralPath $OutJson -Encoding UTF8
exit 0
