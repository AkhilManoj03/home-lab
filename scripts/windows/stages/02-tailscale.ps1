#Requires -RunAsAdministrator
#Requires -Version 5.1

<#
.SYNOPSIS
    Stage 2 — Tailscale installation and authentication.

.DESCRIPTION
    Installs Tailscale, ensures the service is running, and authenticates
    the node to the tailnet. All operations are idempotent.

    !! IMPORTANT: TailscaleAuthKey must be REUSABLE and NON-EPHEMERAL !!
    Ephemeral keys cause the node to vanish from the tailnet when Tailscale
    restarts, which breaks persistent homelab connectivity. Generate a
    reusable key at: https://login.tailscale.com/admin/settings/keys

    This script is safe to run standalone or as part of the bootstrap.ps1
    orchestrator.

.PARAMETER TailscaleAuthKey
    A reusable, non-ephemeral Tailscale auth key.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$TailscaleAuthKey
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not (Get-Command Write-Info -ErrorAction SilentlyContinue)) {
    . (Join-Path $PSScriptRoot '..\common.ps1')
}

Write-Info '=== Stage 2: Tailscale ==='

$script:StageAllPassed = $true

# ─── Installation ─────────────────────────────────────────────────────────────

$tailscalePath = Find-TailscaleBinary

if (-not $tailscalePath) {
    Write-Info 'Tailscale not found — downloading and installing...'
    $installerPath = Join-Path $env:TEMP 'tailscale-setup.exe'
    Invoke-WebRequest -Uri 'https://pkgs.tailscale.com/stable/tailscale-setup-latest-amd64.exe' `
        -OutFile $installerPath -UseBasicParsing
    Start-Process -FilePath $installerPath -ArgumentList '/S' -Wait
    Remove-Item $installerPath -ErrorAction SilentlyContinue

    $tailscalePath = Find-TailscaleBinary
    if (-not $tailscalePath) {
        Exit-Fatal 'Tailscale installer ran but tailscale.exe was not found. Try rebooting and rerunning.'
    }
    Write-Info "Tailscale installed: $tailscalePath"
} else {
    Write-Info "Tailscale already installed: $tailscalePath"
}

# ─── Service ──────────────────────────────────────────────────────────────────

$tailscaleSvc = Get-Service -Name 'Tailscale' -ErrorAction SilentlyContinue
if ($tailscaleSvc) {
    if ($tailscaleSvc.StartType -ne 'Automatic') {
        Set-Service -Name 'Tailscale' -StartupType Automatic
        Write-Info 'Tailscale service set to automatic startup.'
    }
    if ($tailscaleSvc.Status -ne 'Running') {
        Start-Service -Name 'Tailscale'
        Write-Info 'Tailscale service started.'
    } else {
        Write-Info 'Tailscale service already running.'
    }
} else {
    Write-Warn 'Tailscale service not found via Get-Service — proceeding anyway.'
}

# ─── Authentication ───────────────────────────────────────────────────────────

$tsStatus = & $tailscalePath status --json 2>&1 | Out-String | ConvertFrom-Json -ErrorAction SilentlyContinue
if ($tsStatus -and $tsStatus.BackendState -eq 'Running') {
    Write-Info 'Tailscale already connected to tailnet — skipping auth.'
} else {
    Write-Info 'Authenticating with Tailscale...'
    & $tailscalePath up --authkey=$TailscaleAuthKey --accept-dns=false --reset
    if ($LASTEXITCODE -ne 0) {
        Exit-Fatal 'tailscale up failed. Verify the auth key and network connectivity.'
    }
    Write-Info 'Tailscale authenticated.'
}

# ─── Validation ───────────────────────────────────────────────────────────────

Write-Info '--- Stage 2 validation ---'

$tailscalePathFinal = Find-TailscaleBinary
Assert-Check 'Tailscale binary found on disk' ($null -ne $tailscalePathFinal) 'Installation may have failed'

$tailscaleSvcFinal = Get-Service -Name 'Tailscale' -ErrorAction SilentlyContinue
Assert-Check 'Tailscale service Running' `
    ($tailscaleSvcFinal -and $tailscaleSvcFinal.Status -eq 'Running') `
    'Run: Start-Service Tailscale'

$tsStatusFinal = & $tailscalePath status --json 2>&1 | Out-String | ConvertFrom-Json -ErrorAction SilentlyContinue
Assert-Check 'Tailscale connected to tailnet' `
    ($tsStatusFinal -and $tsStatusFinal.BackendState -eq 'Running') `
    'Check tailscale status and verify auth key'

if (-not $script:StageAllPassed) {
    Write-Warn 'Stage 2 completed with warnings — review FAIL items above.'
} else {
    Write-Info 'Stage 2 complete.'
}
