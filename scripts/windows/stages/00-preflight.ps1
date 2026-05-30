#Requires -RunAsAdministrator
#Requires -Version 5.1

<#
.SYNOPSIS
    Stage 0 - Preflight checks for the Windows homelab bootstrap.

.DESCRIPTION
    Validates all prerequisites before any system changes are made:
      - Script is running as Administrator
      - Windows build meets the minimum requirement (19041 / 20H1)
      - Internet connectivity is reachable
      - SSH public key files exist and contain valid key material

    This script exits non-zero on any failure. It is safe to run standalone
    or as part of the bootstrap.ps1 orchestrator.

.PARAMETER DevopsPublicKeyPath
    Path to the devops user's SSH public key file.

.PARAMETER AnsiblePublicKeyPath
    Path to the ansible user's SSH public key file.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$DevopsPublicKeyPath,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$AnsiblePublicKeyPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not (Get-Command Write-Info -ErrorAction SilentlyContinue)) {
    . (Join-Path $PSScriptRoot '..\common.ps1')
}

Write-Info '=== Stage 0: Preflight ==='

# ─── Admin check ─────────────────────────────────────────────────────────────

$principal = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Exit-Fatal 'This script must be run as Administrator.'
}

# ─── Windows version ──────────────────────────────────────────────────────────

# Minimum: Windows 10 build 19041 (20H1) or any Windows 11 build
$osBuild = [System.Environment]::OSVersion.Version.Build
if ($osBuild -lt 19041) {
    Exit-Fatal "Unsupported Windows version. Minimum: Windows 10 build 19041 (20H1). Current build: $osBuild"
}
Write-Info "Windows build $osBuild - OK"

# ─── Internet connectivity ────────────────────────────────────────────────────

try {
    $null = Invoke-WebRequest -Uri 'https://pkgs.tailscale.com' -Method Head -TimeoutSec 10 -UseBasicParsing
    Write-Info 'Internet connectivity - OK'
} catch {
    Exit-Fatal 'No internet connectivity. Ensure the network is available before running this script.'
}

# ─── SSH key file validation ──────────────────────────────────────────────────

foreach ($keyPath in @($DevopsPublicKeyPath, $AnsiblePublicKeyPath)) {
    if (-not (Test-Path $keyPath -PathType Leaf)) {
        Exit-Fatal "SSH public key file not found: $keyPath"
    }
    $keyContent = (Get-Content $keyPath -Raw).Trim()
    if ($keyContent -notmatch '^(ssh-rsa|ssh-ed25519|ecdsa-sha2-nistp|sk-ssh-)') {
        Exit-Fatal "File does not appear to be a valid SSH public key: $keyPath"
    }
}
Write-Info 'SSH key files validated - OK'

Write-Info 'Preflight complete.'
