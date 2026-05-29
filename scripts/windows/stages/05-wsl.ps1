#Requires -RunAsAdministrator
#Requires -Version 5.1

<#
.SYNOPSIS
    Stage 5 — WSL2 installation and Linux environment setup.

.DESCRIPTION
    Installs and configures WSL2 and the Ubuntu environment in two phases:

    Phase A — WSL2 Installation:
      - Enable VirtualMachinePlatform and Microsoft-Windows-Subsystem-Linux
        Windows features (exits for reboot if features were just enabled)
      - Set WSL default version to 2
      - Install the specified distro with --no-launch to avoid interactive prompts
      - Verify the distro is accessible as root

    Phase B — WSL Linux Environment:
      - Update apt package index
      - Install required packages: sudo, python3, openssh-client
      - Create Linux ansible user
      - Configure passwordless sudo for ansible in /etc/sudoers.d/ansible
      - Create ~/.ssh with correct permissions and ownership
      - Configure authorized_keys for the ansible Linux user

    All operations are idempotent. This script is safe to run standalone
    or as part of the bootstrap.ps1 orchestrator.

    Reboot handling: If Windows features require a reboot, the script prints
    a clear message and exits cleanly. Rerun after rebooting — the script
    will detect the features are already enabled and proceed to distro
    installation.

.PARAMETER WslDistro
    WSL distro name to install. Default: Ubuntu

.PARAMETER AnsiblePublicKey
    Content of the ansible user's SSH public key. Mutually exclusive with
    AnsiblePublicKeyPath; AnsiblePublicKey takes precedence.

.PARAMETER AnsiblePublicKeyPath
    Path to the ansible user's SSH public key file. Used when running
    standalone (the orchestrator passes the content directly).

.PARAMETER PromptReboot
    If specified, the script asks before rebooting when required.
    Otherwise it prints instructions and exits (default).
#>

[CmdletBinding()]
param(
    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$WslDistro = 'Ubuntu',

    [Parameter()]
    [string]$AnsiblePublicKey,

    [Parameter()]
    [string]$AnsiblePublicKeyPath,

    [Parameter()]
    [switch]$PromptReboot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not (Get-Command Write-Info -ErrorAction SilentlyContinue)) {
    . (Join-Path $PSScriptRoot '..\common.ps1')
}

Write-Info '=== Stage 5: WSL2 ==='

$script:StageAllPassed = $true

# ─── Resolve ansible key content ──────────────────────────────────────────────

if (-not $AnsiblePublicKey) {
    if (-not $AnsiblePublicKeyPath) {
        Exit-Fatal 'Provide either -AnsiblePublicKey or -AnsiblePublicKeyPath.'
    }
    if (-not (Test-Path $AnsiblePublicKeyPath -PathType Leaf)) {
        Exit-Fatal "ansible public key file not found: $AnsiblePublicKeyPath"
    }
    $AnsiblePublicKey = (Get-Content $AnsiblePublicKeyPath -Raw).Trim()
}

# ─── Phase A: WSL2 Installation ───────────────────────────────────────────────

Write-Info '--- Phase A: WSL2 installation ---'

function Get-WinFeatureState {
    param([string]$FeatureName)
    return (Get-WindowsOptionalFeature -Online -FeatureName $FeatureName -ErrorAction SilentlyContinue).State
}

$vmPlatformState = Get-WinFeatureState 'VirtualMachinePlatform'
$wslFeatureState  = Get-WinFeatureState 'Microsoft-Windows-Subsystem-Linux'
$rebootNeeded    = $false

if ($vmPlatformState -ne 'Enabled') {
    Write-Info 'Enabling VirtualMachinePlatform...'
    $result = Enable-WindowsOptionalFeature -Online -FeatureName 'VirtualMachinePlatform' -NoRestart
    if ($result.RestartNeeded) { $rebootNeeded = $true }
} else {
    Write-Info 'VirtualMachinePlatform already enabled.'
}

if ($wslFeatureState -ne 'Enabled') {
    Write-Info 'Enabling Microsoft-Windows-Subsystem-Linux...'
    $result = Enable-WindowsOptionalFeature -Online -FeatureName 'Microsoft-Windows-Subsystem-Linux' -NoRestart
    if ($result.RestartNeeded) { $rebootNeeded = $true }
} else {
    Write-Info 'Microsoft-Windows-Subsystem-Linux already enabled.'
}

# WSL features require a reboot before wsl.exe can install distros.
# This is expected — rerun the script after rebooting to continue.
if ($rebootNeeded -or (Test-PendingReboot)) {
    Request-Reboot -Reason 'WSL feature enablement (VirtualMachinePlatform / Subsystem-Linux)' -PromptReboot:$PromptReboot
}

# Set WSL2 as default (idempotent)
wsl --set-default-version 2 | Out-Null
Write-Info 'WSL default version set to 2.'

# Install distro if not present
if (-not (Test-WslDistroInstalled -DistroName $WslDistro)) {
    Write-Info "Installing WSL distro '$WslDistro'..."
    # --no-launch prevents the interactive first-run shell from opening
    wsl --install -d $WslDistro --no-launch
    if ($LASTEXITCODE -ne 0) {
        Exit-Fatal "WSL distro installation failed for '$WslDistro' (exit $LASTEXITCODE)."
    }
    Write-Info "WSL distro '$WslDistro' installed."
} else {
    Write-Info "WSL distro '$WslDistro' already installed — skipping."
}

# Confirm distro is accessible without interactive setup
Write-Info "Verifying WSL '$WslDistro' is accessible..."
$wslInit = wsl -d $WslDistro -u root -- echo 'WSL ready' 2>&1
if ($LASTEXITCODE -ne 0 -or ($wslInit -join '') -notmatch 'WSL ready') {
    Exit-Fatal "WSL distro '$WslDistro' is not accessible. Output: $wslInit"
}
Write-Info "WSL '$WslDistro' accessible — OK"

# ─── Phase B: WSL Linux Environment ──────────────────────────────────────────

Write-Info '--- Phase B: WSL Linux environment ---'

# All WSL configuration is driven non-interactively from PowerShell.
# Invoke-Wsl runs commands as root inside the distro.

Write-Info 'Updating apt package index...'
Invoke-Wsl -Command 'apt-get update -qq' -DistroName $WslDistro

foreach ($pkg in @('sudo', 'python3', 'openssh-client')) {
    $state = Invoke-Wsl -Command "dpkg -l $pkg 2>/dev/null | grep -q '^ii' && echo installed || echo missing" -DistroName $WslDistro
    if (($state -join '') -match 'missing') {
        Write-Info "Installing WSL package: $pkg..."
        Invoke-Wsl -Command "DEBIAN_FRONTEND=noninteractive apt-get install -y -qq $pkg" -DistroName $WslDistro
    } else {
        Write-Info "WSL package '$pkg' already installed — skipping."
    }
}

# Create Linux ansible user
$userState = Invoke-Wsl -Command 'id ansible &>/dev/null && echo exists || echo missing' -DistroName $WslDistro
if (($userState -join '') -match 'missing') {
    Write-Info "Creating WSL Linux user 'ansible'..."
    Invoke-Wsl -Command 'useradd -m -s /bin/bash ansible' -DistroName $WslDistro
} else {
    Write-Info "WSL Linux user 'ansible' already exists — skipping."
}

# Passwordless sudo inside WSL (does not affect Windows sudo)
$sudoersPath  = '/etc/sudoers.d/ansible'
$sudoersState = Invoke-Wsl -Command "test -f $sudoersPath && echo exists || echo missing" -DistroName $WslDistro
if (($sudoersState -join '') -match 'missing') {
    Write-Info "Configuring passwordless sudo for WSL 'ansible' user..."
    Invoke-Wsl -Command "echo 'ansible ALL=(ALL) NOPASSWD:ALL' > $sudoersPath && chmod 0440 $sudoersPath" -DistroName $WslDistro
} else {
    Write-Info "WSL sudoers entry for 'ansible' already present — skipping."
}

# .ssh directory
$wslSshState = Invoke-Wsl -Command 'test -d /home/ansible/.ssh && echo exists || echo missing' -DistroName $WslDistro
if (($wslSshState -join '') -match 'missing') {
    Invoke-Wsl -Command 'mkdir -p /home/ansible/.ssh && chmod 700 /home/ansible/.ssh && chown ansible:ansible /home/ansible/.ssh' -DistroName $WslDistro
    Write-Info 'Created /home/ansible/.ssh in WSL.'
} else {
    Write-Info 'WSL /home/ansible/.ssh already exists — skipping.'
}

# authorized_keys — escape single quotes for safe embedding in the bash command
$escapedKey  = $AnsiblePublicKey -replace "'", "'\\'''"
$keyWslState = Invoke-Wsl -Command "grep -qxF '$escapedKey' /home/ansible/.ssh/authorized_keys 2>/dev/null && echo found || echo missing" -DistroName $WslDistro
if (($keyWslState -join '') -match 'missing') {
    Invoke-Wsl -Command "printf '%s\n' '$escapedKey' >> /home/ansible/.ssh/authorized_keys && chmod 600 /home/ansible/.ssh/authorized_keys && chown ansible:ansible /home/ansible/.ssh/authorized_keys" -DistroName $WslDistro
    Write-Info 'ansible public key added to WSL authorized_keys.'
} else {
    Write-Info 'ansible public key already in WSL authorized_keys — skipping.'
}

# ─── Validation ───────────────────────────────────────────────────────────────

Write-Info '--- Stage 5 validation ---'

Assert-Check 'VirtualMachinePlatform feature Enabled' `
    ((Get-WinFeatureState 'VirtualMachinePlatform') -eq 'Enabled')

Assert-Check 'Microsoft-Windows-Subsystem-Linux feature Enabled' `
    ((Get-WinFeatureState 'Microsoft-Windows-Subsystem-Linux') -eq 'Enabled')

Assert-Check "WSL distro '$WslDistro' installed" `
    (Test-WslDistroInstalled -DistroName $WslDistro)

$wslCheck = wsl -d $WslDistro -u root -- echo ok 2>&1
Assert-Check "WSL '$WslDistro' accessible" `
    ($LASTEXITCODE -eq 0 -and ($wslCheck -join '') -match 'ok')

$py3State = Invoke-Wsl -Command "dpkg -l python3 2>/dev/null | grep -q '^ii' && echo installed || echo missing" -DistroName $WslDistro
Assert-Check 'WSL python3 installed' (($py3State -join '') -match 'installed') `
    'Run: apt-get install -y python3 inside WSL'

$userCheck = Invoke-Wsl -Command 'id ansible &>/dev/null && echo exists || echo missing' -DistroName $WslDistro
Assert-Check "WSL Linux 'ansible' user exists" (($userCheck -join '') -match 'exists')

$sudoCheck = Invoke-Wsl -Command "test -f /etc/sudoers.d/ansible && echo exists || echo missing" -DistroName $WslDistro
Assert-Check 'WSL /etc/sudoers.d/ansible present' (($sudoCheck -join '') -match 'exists')

$authKeyCheck = Invoke-Wsl -Command 'test -f /home/ansible/.ssh/authorized_keys && echo exists || echo missing' -DistroName $WslDistro
Assert-Check 'WSL /home/ansible/.ssh/authorized_keys present' (($authKeyCheck -join '') -match 'exists')

if (-not $script:StageAllPassed) {
    Write-Warn 'Stage 5 completed with warnings — review FAIL items above.'
} else {
    Write-Info 'Stage 5 complete.'
}
