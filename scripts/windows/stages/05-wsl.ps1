#Requires -RunAsAdministrator
#Requires -Version 5.1

<#
.SYNOPSIS
    Stage 5 - WSL2 installation and Linux environment setup.

.DESCRIPTION
    Installs and configures WSL2 and the Ubuntu Linux environment in three phases:

    Phase A - Windows features (as Administrator, machine-wide):
      - Enable VirtualMachinePlatform and Microsoft-Windows-Subsystem-Linux
      - Exit for reboot if features were just enabled

    Phase B - WSL distro installation (as ansible Windows user):
      - Set WSL default version to 2
      - Install Ubuntu distro — registered in ansible's HKCU so that
        ForceCommand "wsl.exe -d Ubuntu -u ansible" works when ansible
        authenticates via SSH
      - Verify the distro is accessible

    Phase C - WSL Linux environment (as ansible Windows user):
      - apt update + required packages (sudo, python3, openssh-client)
      - Create Linux ansible user with passwordless sudo
      - Configure ~/.ssh and authorized_keys

    WSL ownership model:
      - Ubuntu belongs exclusively to the ansible Windows user
      - devops has no WSL involvement; it is a Windows-only admin account
      - All wsl.exe operations run under ansible's identity (Start-Process
        -Credential) so HKCU registrations target the correct user

    All operations are idempotent. To run ansible-context operations this
    script temporarily sets a known password on the ansible account and resets
    it in a finally block. sshd_config has PasswordAuthentication no so this
    temporary password cannot be used for remote login.

.PARAMETER WslDistro
    WSL distro name to install. Default: Ubuntu

.PARAMETER AnsiblePublicKey
    Content of the ansible user's SSH public key (passed by the orchestrator).

.PARAMETER AnsiblePublicKeyPath
    Path to the ansible user's SSH public key file (for standalone use).

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

# ─── Phase A: Windows features (as Administrator, machine-wide) ───────────────

Write-Info '--- Phase A: WSL2 Windows features ---'

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

if ($rebootNeeded -or (Test-PendingReboot)) {
    Request-Reboot `
        -Reason       'WSL feature enablement (VirtualMachinePlatform / Subsystem-Linux)' `
        -PromptReboot:$PromptReboot
}

# Machine-level WSL health check (does not depend on per-user HKCU).
$wslVersion = Invoke-WslCli -Arguments @('--version')
if ($wslVersion.Corrupted) {
    Exit-Fatal (Get-WslRepairInstructions)
}
if ($wslVersion.ExitCode -ne 0) {
    Exit-Fatal "WSL is not usable: $($wslVersion.OutputText)`n`n$(Get-WslRepairInstructions)"
}

# ─── Ansible Windows user credential (temporary, for user-context operations) ─

Write-Info '--- Setting up ansible user credentials for WSL operations ---'
Write-Info '  (Temporary password set for Start-Process -Credential; reset in finally block.)'
Write-Info '  sshd PasswordAuthentication no prevents remote use of this password.'

$ansibleCred = Set-UserTempPassword -Username 'ansible'

try {

# Profile path must be correct and NTUSER.DAT present before any Invoke-AsUser so
# WSL distro registration lands in C:\Users\ansible HKCU (not C:\Users\TEMP).
Repair-AnsibleProfileList | Out-Null
Initialize-AnsibleUserProfile | Out-Null

# ─── Phase B: WSL distro installation (as ansible Windows user) ───────────────
#
# All wsl.exe operations run under ansible's identity so the distro is registered
# in ansible's HKCU. This is required for ForceCommand "wsl.exe -d Ubuntu -u ansible"
# to succeed when ansible logs in via SSH.

Write-Info '--- Phase B: WSL2 distro installation (as ansible) ---'

# Set WSL default version — per-user setting, must run as ansible.
$setDefault = Invoke-WslCliAsUser `
    -Arguments  @('--set-default-version', '2') `
    -Credential $ansibleCred
if ($setDefault.Corrupted) {
    Exit-Fatal (Get-WslRepairInstructions)
}
if ($setDefault.ExitCode -ne 0) {
    Exit-Fatal "Failed to set WSL default version (exit $($setDefault.ExitCode)): $($setDefault.OutputText)"
}
Write-Info 'WSL default version set to 2.'

$ansibleProfile = 'C:\Users\ansible'
Ensure-AnsibleWslProfileLayout -ProfilePath $ansibleProfile | Out-Null

$needsInstall = -not (Test-WslDistroRegisteredForUser -DistroName $WslDistro -Credential $ansibleCred)

if (-not $needsInstall) {
    $sessionBasePath = Get-AnsibleSessionWslDistroBasePath -Credential $ansibleCred -DistroName $WslDistro
    if (-not $sessionBasePath) {
        $onDiskRecord = Get-AnsibleProfileLxssDistros -ProfilePath $ansibleProfile |
            Where-Object { $_.Kind -eq 'Distro' -and $_.Name -eq $WslDistro } |
            Select-Object -First 1
        if ($onDiskRecord) { $sessionBasePath = $onDiskRecord.BasePath }
    }
    if ($sessionBasePath -and -not (Test-WslDistroBasePathUnderProfile -BasePath $sessionBasePath -ProfilePath $ansibleProfile)) {
        Write-Warn "WSL '$WslDistro' BasePath is '$sessionBasePath' (expected under '$ansibleProfile')."
        Write-Info 'Migrating WSL distro files into ansible profile (no unregister)...'
        $move = Move-AnsibleWslDistroBasePath `
            -Credential   $ansibleCred `
            -DistroName   $WslDistro `
            -OldBasePath  $sessionBasePath `
            -ProfilePath  $ansibleProfile
        if ($move.Success) {
            Write-Info "WSL '$WslDistro' BasePath migrated to '$($move.BasePath)'."
            Sync-WslRegistryToAnsibleProfile -Credential $ansibleCred -ProfilePath $ansibleProfile | Out-Null
        } else {
            Write-Warn "BasePath migration failed ($($move.Reason)); will try import from orphaned files or fresh install."
            $needsInstall = $true
        }
    } else {
        Write-Info "WSL distro '$WslDistro' already registered with valid BasePath - skipping install."
    }
}

if ($needsInstall) {
    if (Test-WslDistroRegisteredForUser -DistroName $WslDistro -Credential $ansibleCred) {
        Write-Warn "WSL '$WslDistro' is still registered; unregistering before import/reinstall."
        $unreg = Unregister-WslDistroForUser -Credential $ansibleCred -DistroName $WslDistro
        if ($unreg.Corrupted) {
            Exit-Fatal (Get-WslRepairInstructions)
        }
        if ($unreg.ExitCode -ne 0) {
            Exit-Fatal "wsl --unregister '$WslDistro' failed (exit $($unreg.ExitCode)): $($unreg.OutputText)"
        }
        Write-Info "Unregistered WSL distro '$WslDistro'."
    }

    foreach ($orphanBase in @(Get-OrphanedWslDistroSourcePaths -DistroName $WslDistro -ProfilePath $ansibleProfile)) {
        Write-Info "Found orphaned WSL data at '$orphanBase'; attempting wsl --import as ansible..."
        Ensure-AnsibleWslProfileLayout -ProfilePath $ansibleProfile | Out-Null
        $imp = Import-AnsibleWslDistroFromSource `
            -Credential      $ansibleCred `
            -DistroName      $WslDistro `
            -SourceBasePath  $orphanBase `
            -ProfilePath     $ansibleProfile
        if ($imp.Success) {
            Write-Info "Imported WSL '$WslDistro' from orphaned data (BasePath: $($imp.BasePath))."
            Sync-WslRegistryToAnsibleProfile -Credential $ansibleCred -ProfilePath $ansibleProfile | Out-Null
            $needsInstall = $false
            break
        }
        Write-Warn "Import from '$orphanBase' failed ($($imp.Reason))."
        if ($imp.Output) { Write-Warn $imp.Output }
    }
}

if ($needsInstall) {
    Ensure-AnsibleWslProfileLayout -ProfilePath $ansibleProfile | Out-Null
    Write-Info "Installing WSL distro '$WslDistro' as ansible Windows user..."
    # --no-launch suppresses the interactive first-run shell. A generous timeout
    # allows for slow network downloads on first install.
    $install = Invoke-WslCliAsUser `
        -Arguments  @('--install', '-d', $WslDistro, '--no-launch') `
        -Credential $ansibleCred `
        -TimeoutSec 1800
    if ($install.Corrupted) {
        Exit-Fatal (Get-WslRepairInstructions)
    }
    if ($install.ExitCode -ne 0) {
        Exit-Fatal "WSL distro installation failed for '$WslDistro' (exit $($install.ExitCode)): $($install.OutputText)"
    }
    Write-Info "WSL distro '$WslDistro' installed for ansible Windows user."
}

# Verify distro is accessible and responds to commands.
Write-Info "Verifying WSL '$WslDistro' is accessible as ansible user..."
$wslInit = Invoke-WslCliAsUser `
    -Arguments  @('-d', $WslDistro, '-u', 'root', '--', 'echo', 'WSL ready') `
    -Credential $ansibleCred
if ($wslInit.Corrupted) {
    Exit-Fatal (Get-WslRepairInstructions)
}
if ($wslInit.ExitCode -ne 0 -or $wslInit.OutputText -notmatch 'WSL ready') {
    Exit-Fatal "WSL distro '$WslDistro' is not accessible. Output: $($wslInit.OutputText)"
}
Write-Info "WSL '$WslDistro' accessible - OK"

if (-not (Sync-WslRegistryToAnsibleProfile -Credential $ansibleCred)) {
    Exit-Fatal @(
        "WSL responded for the ansible session but Lxss registry was not persisted to C:\Users\ansible\NTUSER.DAT."
        'SSH login will try to provision Ubuntu again and fail under ConstrainedLanguage.'
        'Run scripts\windows\diag-wsl-ansible.ps1 and share the output.'
    ) -join ' '
}

Set-WslOobeCompleteInProfile | Out-Null

if (-not (Test-WslDistroInAnsibleProfile -DistroName $WslDistro)) {
    Exit-Fatal "Ubuntu is not registered in ansible's on-disk profile hive after sync. SSH ForceCommand will fail."
}

$onDiskDistro = Get-AnsibleProfileLxssDistros -ProfilePath $ansibleProfile |
    Where-Object { $_.Kind -eq 'Distro' -and $_.Name -eq $WslDistro } |
    Select-Object -First 1
if (-not $onDiskDistro -or -not (Test-WslDistroBasePathUnderProfile -BasePath $onDiskDistro.BasePath -ProfilePath $ansibleProfile)) {
    $bp = if ($onDiskDistro) { $onDiskDistro.BasePath } else { '(missing)' }
    Exit-Fatal "WSL '$WslDistro' on-disk BasePath is '$bp' but must be under '$ansibleProfile' for SSH login."
}
Write-Info "WSL '$WslDistro' persisted in ansible NTUSER.DAT (BasePath: $($onDiskDistro.BasePath)) - OK"

# ─── Phase C: WSL Linux environment (as ansible Windows user) ─────────────────
#
# All bash commands run inside ansible's Ubuntu instance.

Write-Info '--- Phase C: WSL Linux environment (as ansible) ---'

Write-Info 'Updating apt package index...'
Invoke-WslAsUser -Command 'apt-get update -qq' -DistroName $WslDistro -Credential $ansibleCred | Out-Null

foreach ($pkg in @('sudo', 'python3', 'openssh-client')) {
    $state = Invoke-WslAsUser `
        -Command    "dpkg -l $pkg 2>/dev/null | grep -q '^ii' && echo installed || echo missing" `
        -DistroName $WslDistro `
        -Credential $ansibleCred
    if ($state -match 'missing') {
        Write-Info "Installing WSL package: $pkg..."
        Invoke-WslAsUser `
            -Command    "DEBIAN_FRONTEND=noninteractive apt-get install -y -qq $pkg" `
            -DistroName $WslDistro `
            -Credential $ansibleCred | Out-Null
    } else {
        Write-Info "WSL package '$pkg' already installed - skipping."
    }
}

# Linux ansible user
$userState = Invoke-WslAsUser `
    -Command    'id ansible &>/dev/null && echo exists || echo missing' `
    -DistroName $WslDistro `
    -Credential $ansibleCred
if ($userState -match 'missing') {
    Write-Info "Creating WSL Linux user 'ansible'..."
    Invoke-WslAsUser `
        -Command    'useradd -m -s /bin/bash ansible' `
        -DistroName $WslDistro `
        -Credential $ansibleCred | Out-Null
} else {
    Write-Info "WSL Linux user 'ansible' already exists - skipping."
}

# Passwordless sudo inside WSL
$sudoersPath  = '/etc/sudoers.d/ansible'
$sudoersState = Invoke-WslAsUser `
    -Command    "test -f $sudoersPath && echo exists || echo missing" `
    -DistroName $WslDistro `
    -Credential $ansibleCred
if ($sudoersState -match 'missing') {
    Write-Info "Configuring passwordless sudo for WSL 'ansible' user..."
    Invoke-WslAsUser `
        -Command    "echo 'ansible ALL=(ALL) NOPASSWD:ALL' > $sudoersPath && chmod 0440 $sudoersPath" `
        -DistroName $WslDistro `
        -Credential $ansibleCred | Out-Null
} else {
    Write-Info "WSL sudoers entry for 'ansible' already present - skipping."
}

# .ssh directory
$sshDirState = Invoke-WslAsUser `
    -Command    'test -d /home/ansible/.ssh && echo exists || echo missing' `
    -DistroName $WslDistro `
    -Credential $ansibleCred
if ($sshDirState -match 'missing') {
    Invoke-WslAsUser `
        -Command    'mkdir -p /home/ansible/.ssh && chmod 700 /home/ansible/.ssh && chown ansible:ansible /home/ansible/.ssh' `
        -DistroName $WslDistro `
        -Credential $ansibleCred | Out-Null
    Write-Info 'Created /home/ansible/.ssh in WSL.'
} else {
    Write-Info 'WSL /home/ansible/.ssh already exists - skipping.'
}

# authorized_keys
$escapedKey  = $AnsiblePublicKey -replace "'", "'\\'''"
$keyWslState = Invoke-WslAsUser `
    -Command    "grep -qxF '$escapedKey' /home/ansible/.ssh/authorized_keys 2>/dev/null && echo found || echo missing" `
    -DistroName $WslDistro `
    -Credential $ansibleCred
if ($keyWslState -match 'missing') {
    Invoke-WslAsUser `
        -Command    "printf '%s\n' '$escapedKey' >> /home/ansible/.ssh/authorized_keys && chmod 600 /home/ansible/.ssh/authorized_keys && chown ansible:ansible /home/ansible/.ssh/authorized_keys" `
        -DistroName $WslDistro `
        -Credential $ansibleCred | Out-Null
    Write-Info 'ansible public key added to WSL authorized_keys.'
} else {
    Write-Info 'ansible public key already in WSL authorized_keys - skipping.'
}

# ─── Validation ───────────────────────────────────────────────────────────────

Write-Info '--- Stage 5 validation ---'

Assert-Check 'VirtualMachinePlatform feature Enabled' `
    ((Get-WinFeatureState 'VirtualMachinePlatform') -eq 'Enabled')

Assert-Check 'Microsoft-Windows-Subsystem-Linux feature Enabled' `
    ((Get-WinFeatureState 'Microsoft-Windows-Subsystem-Linux') -eq 'Enabled')

Assert-Check "WSL '$WslDistro' registered in ansible on-disk profile hive" `
    (Test-WslDistroInAnsibleProfile -DistroName $WslDistro) `
    'Run stage 5 again; Lxss must be persisted to C:\Users\ansible\NTUSER.DAT for SSH'

$validationDistro = Get-AnsibleProfileLxssDistros -ProfilePath 'C:\Users\ansible' |
    Where-Object { $_.Kind -eq 'Distro' -and $_.Name -eq $WslDistro } |
    Select-Object -First 1
Assert-Check "WSL '$WslDistro' BasePath under C:\Users\ansible" `
    ($validationDistro -and (Test-WslDistroBasePathUnderProfile -BasePath $validationDistro.BasePath)) `
    "BasePath must not point at C:\Users\TEMP; rerun stage 5 to reinstall the distro"

Assert-Check "WSL distro '$WslDistro' registered for ansible Windows user" `
    (Test-WslDistroRegisteredForUser -DistroName $WslDistro -Credential $ansibleCred) `
    "ForceCommand 'wsl.exe -d $WslDistro -u ansible' requires the distro in ansible's HKCU"

$wslCheck = Invoke-WslCliAsUser `
    -Arguments  @('-d', $WslDistro, '-u', 'root', '--', 'echo', 'ok') `
    -Credential $ansibleCred
Assert-Check "WSL '$WslDistro' accessible as ansible user" `
    ($wslCheck.ExitCode -eq 0 -and $wslCheck.OutputText -match 'ok')

$py3State = Invoke-WslAsUser `
    -Command    "dpkg -l python3 2>/dev/null | grep -q '^ii' && echo installed || echo missing" `
    -DistroName $WslDistro `
    -Credential $ansibleCred
Assert-Check 'WSL python3 installed' ($py3State -match 'installed') `
    'Run: apt-get install -y python3 inside WSL'

$userCheck = Invoke-WslAsUser `
    -Command    'id ansible &>/dev/null && echo exists || echo missing' `
    -DistroName $WslDistro `
    -Credential $ansibleCred
Assert-Check "WSL Linux 'ansible' user exists" ($userCheck -match 'exists')

$sudoCheck = Invoke-WslAsUser `
    -Command    "test -f /etc/sudoers.d/ansible && echo exists || echo missing" `
    -DistroName $WslDistro `
    -Credential $ansibleCred
Assert-Check 'WSL /etc/sudoers.d/ansible present' ($sudoCheck -match 'exists')

$authKeyCheck = Invoke-WslAsUser `
    -Command    'test -f /home/ansible/.ssh/authorized_keys && echo exists || echo missing' `
    -DistroName $WslDistro `
    -Credential $ansibleCred
Assert-Check 'WSL /home/ansible/.ssh/authorized_keys present' ($authKeyCheck -match 'exists')

} finally {
    # Start-Process -Credential ansible can load a temp profile and corrupt
    # ProfileList (ProfileImagePath -> C:\Users\TEMP). Repair before clearing pwd.
    Repair-AnsibleProfileList | Out-Null
    Reset-UserPassword -Username 'ansible'
    Write-Info 'ansible Windows user temporary password cleared.'
}

if (-not $script:StageAllPassed) {
    Write-Warn 'Stage 5 completed with warnings - review FAIL items above.'
} else {
    Write-Info 'Stage 5 complete.'
}
