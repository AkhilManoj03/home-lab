<#
.SYNOPSIS
    Shared utility functions for Windows homelab bootstrap scripts.

.DESCRIPTION
    Dot-source this file at the top of each stage script. The guard at the
    call site prevents double-loading when scripts are composed by the
    orchestrator.

    Usage in each stage script:
        if (-not (Get-Command Write-Info -ErrorAction SilentlyContinue)) {
            . (Join-Path $PSScriptRoot '..\common.ps1')
        }
#>

# Set on each dot-source (StrictMode forbids reading unset globals in -not checks).

# ─── Logging ─────────────────────────────────────────────────────────────────

function Write-Info { param([string]$Msg) Write-Host "INFO:  $Msg" -ForegroundColor Cyan }
function Write-Warn { param([string]$Msg) Write-Host "WARN:  $Msg" -ForegroundColor Yellow }
function Write-Err  { param([string]$Msg) Write-Host "ERROR: $Msg" -ForegroundColor Red }

function Exit-Fatal {
    param([string]$Msg)
    Write-Err $Msg
    exit 1
}

# ─── Reboot helpers ──────────────────────────────────────────────────────────

function Test-PendingReboot {
    $keys = @(
        'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\PendingFileRenameOperations',
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending',
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired'
    )
    foreach ($key in $keys) {
        if (Test-Path $key) { return $true }
    }
    return $false
}

function Request-Reboot {
    param(
        [string]$Reason,
        [switch]$PromptReboot
    )
    Write-Info "Reboot required: $Reason"
    Write-Info "Please reboot and rerun this script to continue."
    if ($PromptReboot) {
        $response = Read-Host "Reboot now? [y/N]"
        if ($response -ceq 'y' -or $response -ceq 'Y') {
            Restart-Computer -Force
        }
    }
    exit 0
}

# ─── Security helpers ─────────────────────────────────────────────────────────

function New-RandomPassword {
    $bytes = New-Object byte[] 32
    [System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
    return [Convert]::ToBase64String($bytes)
}

function Enable-AdminPathMaintenance {
    <#
    Grants Administrators Full Control on a path and its descendants so the
    bootstrap script can manage files inside locked user-profile directories.

    IMPORTANT: [IO.Directory]::Exists() silently returns $false for paths that
    exist but are ACL-locked (it swallows UnauthorizedAccessException internally).
    We therefore detect existence and type via the PARENT directory, which
    Administrators can still enumerate even when the child is locked. This avoids
    the false-negative that would cause New-Item to receive an access-denied error
    on a subsequent idempotent run.
    #>
    param([string]$Path)

    if (-not $Path) { return }

    # Detect existence and type via parent enumeration.
    # Get-ChildItem on the parent only requires List permission on the parent,
    # not on the (potentially locked) child entry.
    $isDirectory = $false
    $isFile      = $false
    $parent = Split-Path -Parent $Path
    if ($parent -and [System.IO.Directory]::Exists($parent)) {
        $leaf = Split-Path -Leaf $Path
        $item = Get-ChildItem -LiteralPath $parent -Force -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -ieq $leaf } |
                Select-Object -First 1
        if ($item) {
            $isDirectory = $item.PSIsContainer
            $isFile      = -not $item.PSIsContainer
        }
    }
    # Fallback for root-level paths or when parent enumeration is unavailable.
    if (-not ($isDirectory -or $isFile)) {
        $isDirectory = [System.IO.Directory]::Exists($Path)
        $isFile      = [System.IO.File]::Exists($Path)
    }
    if (-not ($isDirectory -or $isFile)) { return }

    Write-Info "Granting Administrator access to '$Path' for maintenance..."
    if ($isDirectory) {
        & takeown.exe /F $Path /R /A /D Y 2>&1 | Out-Null
        & icacls.exe $Path /grant 'BUILTIN\Administrators:(OI)(CI)F' /T 2>&1 | Out-Null
    } else {
        & takeown.exe /F $Path /A 2>&1 | Out-Null
        & icacls.exe $Path /grant 'BUILTIN\Administrators:F' 2>&1 | Out-Null
    }
}

function Set-RestrictedAcl {
    <#
    Locks down a file or directory so only the given user SID and SYSTEM
    have access. All inherited and other explicit entries are removed.
    Sets the owner to the user SID (required by Win32 OpenSSH).

    If the path is already locked down (e.g. a prior partial run), takes
    ownership as Administrators so ACLs can be repaired.
    #>
    param(
        [string]$Path,
        [System.Security.Principal.SecurityIdentifier]$UserSid,
        [string]$UserAccess
    )

    $acl = $null
    try {
        $acl = Get-Acl -LiteralPath $Path
    } catch [System.UnauthorizedAccessException] {
        Write-Info "Taking ownership of '$Path' to repair ACL..."
        & takeown.exe /F $Path /A | Out-Null
        if ($LASTEXITCODE -ne 0) {
            throw "takeown failed for '$Path' (exit $LASTEXITCODE)"
        }
        $acl = Get-Acl -LiteralPath $Path
    }

    $acl.SetOwner($UserSid)
    $acl.SetAccessRuleProtection($true, $false)
    foreach ($rule in @($acl.Access)) { $acl.RemoveAccessRule($rule) | Out-Null }
    $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule(
        $UserSid, $UserAccess, 'Allow')))
    $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule(
        'NT AUTHORITY\SYSTEM', 'FullControl', 'Allow')))
    Set-Acl -LiteralPath $Path -AclObject $acl
}

# ─── WSL helpers ──────────────────────────────────────────────────────────────

function Get-WslCliOutputText {
    param([object[]]$Output)
    return (($Output | ForEach-Object {
        if ($_ -is [System.Management.Automation.ErrorRecord]) { $_.ToString() } else { "$_" }
    }) -join "`n")
}

function Test-WslCliOutputCorrupted {
    param([string]$OutputText)
    return $OutputText -match '(?i)corrupted|REGDB_E_CLASSNOTREG|cannot be accessed by the system|Wsl/CallMsi'
}

function Invoke-WslCli {
    <#
    Runs wsl.exe without letting native stderr become a terminating error under
    $ErrorActionPreference = 'Stop'. Returns exit code and captured output.
    #>
    param([string[]]$Arguments)

    $prevEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $output   = & wsl.exe @Arguments 2>&1
        $exitCode = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $prevEap
    }

    $outputText = Get-WslCliOutputText -Output @($output)
    return [PSCustomObject]@{
        ExitCode   = $exitCode
        Output     = @($output)
        OutputText = $outputText
        Corrupted  = (Test-WslCliOutputCorrupted -OutputText $outputText)
    }
}

function Get-WslRepairInstructions {
    return @(
        'WSL is corrupted or inaccessible on this machine. Repair it before rerunning bootstrap:'
        ''
        '  1. In an elevated PowerShell, run:  wsl --update'
        '  2. If wsl prompts to repair, press a key to allow the repair, then reboot.'
        '  3. If still broken, run:  wsl --install --no-distribution'
        '  4. Reboot, then rerun bootstrap.ps1 (or 05-wsl.ps1).'
        ''
        'If the error persists, uninstall "Windows Subsystem for Linux" from'
        'Settings > Apps, reboot, then run step 3 again.'
    ) -join "`n"
}

function Assert-WslHealthy {
    $version = Invoke-WslCli -Arguments @('--version')
    if ($version.Corrupted) {
        Exit-Fatal (Get-WslRepairInstructions)
    }

    $status = Invoke-WslCli -Arguments @('--status')
    if ($status.Corrupted) {
        Exit-Fatal (Get-WslRepairInstructions)
    }

    $list = Invoke-WslCli -Arguments @('--list', '--quiet')
    if ($list.Corrupted) {
        Exit-Fatal (Get-WslRepairInstructions)
    }

    if ($version.ExitCode -ne 0 -and $list.ExitCode -ne 0) {
        $detail = ($version.OutputText, $list.OutputText | Where-Object { $_ }) -join "`n"
        Exit-Fatal "WSL is not usable.`n$detail`n`n$(Get-WslRepairInstructions)"
    }
}

function Invoke-Wsl {
    <#
    Runs a bash command inside WSL as root. Throws on non-zero exit code.
    Pass -DistroName to target a specific distro.
    #>
    param(
        [string]$Command,
        [string]$DistroName
    )
    $result = Invoke-WslCli -Arguments @('-d', $DistroName, '-u', 'root', '--', 'bash', '-c', $Command)
    if ($result.Corrupted) {
        throw "WSL appears corrupted.`n$(Get-WslRepairInstructions)"
    }
    if ($result.ExitCode -ne 0) {
        throw "WSL command failed (exit $($result.ExitCode)): $Command`nOutput: $($result.OutputText)"
    }
    return $result.Output
}

# ─── SSH config helpers ───────────────────────────────────────────────────────

function Repair-AnsibleProfileList {
    <#
    Ensures ProfileList points the ansible user at C:\Users\ansible with State 0.

    Start-Process -Credential (stage 5) can load a temporary Windows profile and
    overwrite ProfileImagePath with C:\Users\TEMP, which breaks sshd pubkey lookup
    when AuthorizedKeysFile is relative to the profile directory. Idempotent.
    #>
    param(
        [string]$Username = 'ansible',
        [string]$ProfilePath = 'C:\Users\ansible'
    )

    $user = Get-LocalUser -Name $Username -ErrorAction SilentlyContinue
    if (-not $user) {
        Write-Warn "Repair-AnsibleProfileList: user '$Username' not found - skipping."
        return $false
    }

    $profileListKey = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\$($user.SID.Value)"
    if (-not (Test-Path $profileListKey)) {
        New-Item -Path $profileListKey -Force | Out-Null
        Write-Info "Created '$Username' ProfileList registry key."
    }

    $props = Get-ItemProperty -Path $profileListKey -ErrorAction SilentlyContinue
    if (-not $props.ProfileImagePath -or $props.ProfileImagePath -ne $ProfilePath) {
        $was = if ($props.ProfileImagePath) { $props.ProfileImagePath } else { '(missing)' }
        New-ItemProperty -Path $profileListKey -Name 'ProfileImagePath' `
            -Value $ProfilePath -PropertyType ExpandString -Force | Out-Null
        Write-Info "ProfileImagePath: '$was' -> '$ProfilePath'."
    }

    $stateVal = if ($null -ne $props.State) { [int]$props.State } else { $null }
    if ($null -eq $stateVal -or $stateVal -ne 0) {
        $wasState = if ($null -eq $stateVal) { '(missing)' } else { $stateVal }
        New-ItemProperty -Path $profileListKey -Name 'State' `
            -Value 0 -PropertyType DWord -Force | Out-Null
        Write-Info "ProfileList State: $wasState -> 0."
    }

    return $true
}

function Initialize-AnsibleUserProfile {
    <#
    Seeds C:\Users\ansible\NTUSER.DAT from the Default user template so ansible
    has a persistent HKCU hive before stage 5 registers WSL (Lxss lives in HKCU).
    Without this, Start-Process -Credential or SSH may use a temporary profile
    (C:\Users\TEMP) and WSL registrations end up in the wrong hive.
    #>
    param(
        [string]$Username = 'ansible',
        [string]$ProfilePath = 'C:\Users\ansible'
    )

    $user = Get-LocalUser -Name $Username -ErrorAction SilentlyContinue
    if (-not $user) {
        Write-Warn "Initialize-AnsibleUserProfile: user '$Username' not found - skipping."
        return $false
    }

    if (-not [System.IO.Directory]::Exists($ProfilePath)) {
        New-Item -ItemType Directory -Path $ProfilePath -Force | Out-Null
    }

    $ntUserDat = Join-Path $ProfilePath 'NTUSER.DAT'
    if ([System.IO.File]::Exists($ntUserDat)) {
        Write-Info "Profile hive already present: $ntUserDat"
        Repair-AnsibleUserProfileAcl -ProfilePath $ProfilePath -User $user | Out-Null
        return $true
    }

    $defaultNtUser = Join-Path $env:SystemDrive 'Users\Default\NTUSER.DAT'
    if (-not (Test-Path -LiteralPath $defaultNtUser)) {
        Write-Warn "Default profile hive not found at $defaultNtUser - cannot seed NTUSER.DAT."
        return $false
    }

    Write-Info "Seeding '$Username' profile hive from Default user template..."
    Copy-Item -LiteralPath $defaultNtUser -Destination $ntUserDat -Force

    # icacls requires *SID for raw SIDs; bare S-1-5-... is treated as an account name.
    $sidIcacls = "*$($user.SID.Value)"
    & takeown.exe /F $ntUserDat /A 2>&1 | Out-Null
    $icaclsOut = & icacls.exe $ntUserDat /setowner $sidIcacls 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Warn "icacls setowner on NTUSER.DAT failed: $(($icaclsOut | Out-String).Trim())"
    }
    $icaclsOut = & icacls.exe $ntUserDat /inheritance:r /grant:r "${sidIcacls}:(F)" /grant:r 'SYSTEM:(F)' /grant:r 'BUILTIN\Administrators:(F)' 2>&1
    if ($LASTEXITCODE -ne 0) {
        Remove-Item -LiteralPath $ntUserDat -Force -ErrorAction SilentlyContinue
        Write-Warn "icacls grant on NTUSER.DAT failed: $(($icaclsOut | Out-String).Trim())"
        return $false
    }
    Write-Info "Created profile hive: $ntUserDat"
    Repair-AnsibleUserProfileAcl -ProfilePath $ProfilePath -User $user | Out-Null
    return $true
}

function Repair-AnsibleUserProfileAcl {
    <#
    Ensures ansible owns NTUSER.DAT and can write under AppData\Local\Temp.
    Called when seeding a new hive or repairing an existing one (e.g. owner is Administrators).
    #>
    param(
        [string]$ProfilePath = 'C:\Users\ansible',
        $User
    )

    if (-not $User) {
        $User = Get-LocalUser -Name 'ansible' -ErrorAction SilentlyContinue
    }
    if (-not $User) { return $false }

    $sidIcacls = "*$($User.SID.Value)"
    $ntUserDat = Join-Path $ProfilePath 'NTUSER.DAT'

    if ([System.IO.File]::Exists($ntUserDat)) {
        & takeown.exe /F $ntUserDat /A 2>&1 | Out-Null
        & icacls.exe $ntUserDat /setowner $sidIcacls 2>&1 | Out-Null
        & icacls.exe $ntUserDat /inheritance:r /grant:r "${sidIcacls}:(F)" /grant:r 'SYSTEM:(F)' /grant:r 'BUILTIN\Administrators:(F)' 2>&1 | Out-Null
    }

    Ensure-AnsibleProfileExportDir -ProfilePath $ProfilePath -User $User | Out-Null
    Ensure-AnsibleWslProfileLayout -ProfilePath $ProfilePath -User $User | Out-Null
    return $true
}

function Ensure-AnsibleProfileExportDir {
    param(
        [string]$ProfilePath = 'C:\Users\ansible',
        $User
    )

    if (-not $User) {
        $User = Get-LocalUser -Name 'ansible' -ErrorAction SilentlyContinue
    }
    if (-not $User) { return $null }

    $sidIcacls = "*$($User.SID.Value)"
    $tempDir   = Join-Path $ProfilePath 'AppData\Local\Temp'
    New-Item -ItemType Directory -Path $tempDir -Force | Out-Null
    & icacls.exe $tempDir /inheritance:r /grant:r "${sidIcacls}:(OI)(CI)F" /grant:r 'SYSTEM:(OI)(CI)F' /grant:r 'BUILTIN\Administrators:(OI)(CI)F' 2>&1 | Out-Null
    return $tempDir
}

function Ensure-AnsibleWslProfileLayout {
    <#
    Creates AppData\Local\wsl under the ansible profile with ACLs ansible can write.
    WSL RegisterDistro fails with E_ACCESSDENIED when this tree is missing or not writable.
    #>
    param(
        [string]$ProfilePath = 'C:\Users\ansible',
        $User
    )

    if (-not $User) {
        $User = Get-LocalUser -Name 'ansible' -ErrorAction SilentlyContinue
    }
    if (-not $User) { return $null }

    $sidIcacls = "*$($User.SID.Value)"
    foreach ($rel in @('AppData', 'AppData\Local', 'AppData\Local\Temp', 'AppData\Local\wsl')) {
        New-Item -ItemType Directory -Path (Join-Path $ProfilePath $rel) -Force | Out-Null
    }

    $localAppData = Join-Path $ProfilePath 'AppData\Local'
    & icacls.exe $localAppData /inheritance:r /grant:r "${sidIcacls}:(OI)(CI)F" /grant:r 'SYSTEM:(OI)(CI)F' /grant:r 'BUILTIN\Administrators:(OI)(CI)F' 2>&1 | Out-Null
    return Join-Path $localAppData 'wsl'
}

function Import-RegKeyNodeToPath {
    param(
        [string]$ParentPath,
        $Node
    )
    if (-not $Node) { return }

    $keyPath = Join-Path $ParentPath $Node.KeyName
    if (-not (Test-Path -LiteralPath $keyPath)) {
        New-Item -Path $keyPath -Force | Out-Null
    }

    foreach ($prop in @($Node.Properties)) {
        if (-not $prop) { continue }
        $type = switch ([string]$prop.Kind) {
            'String'        { 'String' }
            'ExpandString'  { 'ExpandString' }
            'DWord'         { 'DWord' }
            'QWord'         { 'QWord' }
            'Binary'        { 'Binary' }
            'MultiString'   { 'MultiString' }
            default         { 'String' }
        }
        $val = switch ([string]$prop.Kind) {
            'Binary' { [Convert]::FromBase64String([string]$prop.Value) }
            default  { $prop.Value }
        }
        New-ItemProperty -LiteralPath $keyPath -Name $prop.Name -Value $val -PropertyType $type -Force | Out-Null
    }

    foreach ($child in @($Node.Children)) {
        Import-RegKeyNodeToPath -ParentPath $keyPath -Node $child
    }
}

function Import-AnsibleLxssJsonToProfile {
    param(
        [string]$JsonPath,
        [string]$ProfilePath = 'C:\Users\ansible'
    )

    if (-not (Test-Path -LiteralPath $JsonPath)) { return $false }

    $payload  = Get-Content -LiteralPath $JsonPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $ntUserDat = Join-Path $ProfilePath 'NTUSER.DAT'
    if (-not (Test-Path -LiteralPath $ntUserDat)) { return $false }

    $hiveName = 'HomelabAnsibleLoad'
    $loadOut  = cmd.exe /c "reg load HKU\$hiveName `"$ntUserDat`" 2>&1"
    if ($LASTEXITCODE -ne 0) {
        Write-Warn "reg load for Lxss JSON import failed: $loadOut"
        return $false
    }

    try {
        $versionKey = "Registry::HKEY_USERS\$hiveName\Software\Microsoft\Windows\CurrentVersion"
        if (-not (Test-Path -LiteralPath $versionKey)) {
            New-Item -Path $versionKey -Force | Out-Null
        }
        Import-RegKeyNodeToPath -ParentPath $versionKey -Node $payload.Lxss
        Write-Info "Imported Lxss registry into NTUSER.DAT (exported from $($payload.UserProfile))."
        return $true
    } finally {
        cmd.exe /c "reg unload HKU\$hiveName 2>&1" | Out-Null
    }
}

function Export-AnsibleLxssJsonFromSession {
    <#
    Exports HKCU\...\Lxss via PowerShell registry cmdlets (no SeBackupPrivilege).
    Writes JSON to BootstrapSharedTemp for admin import into NTUSER.DAT.
    #>
    param(
        [System.Management.Automation.PSCredential]$Credential,
        [string]$ProfilePath = 'C:\Users\ansible'
    )

    $user = Get-LocalUser -Name ($Credential.UserName -replace '^.*\\', '') -ErrorAction SilentlyContinue
    if (-not $user) { return $null }

    Repair-AnsibleUserProfileAcl -ProfilePath $ProfilePath -User $user | Out-Null
    Initialize-BootstrapSharedTemp

    $exportScriptContent = @'
#Requires -Version 5.1
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
'@

    $exportScript = Join-Path $global:BootstrapSharedTemp 'export-ansible-lxss.ps1'
    [System.IO.File]::WriteAllText($exportScript, $exportScriptContent, [System.Text.UTF8Encoding]::new($false))

    $jsonPath = Join-Path $global:BootstrapSharedTemp 'ansible-lxss.json'
    Remove-Item -LiteralPath $jsonPath -Force -ErrorAction SilentlyContinue

    try {
        $run = Invoke-AsUser -Credential $Credential -FilePath 'powershell.exe' -ArgumentList @(
            '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
            '-File', $exportScript,
            '-OutJson', $jsonPath
        )
        if ($run.ExitCode -ne 0 -or -not (Test-Path -LiteralPath $jsonPath)) {
            Write-Warn "Lxss JSON export failed (exit $($run.ExitCode)): $($run.OutputText)"
            return $null
        }

        Write-Info "Exported ansible Lxss registry to $jsonPath"
        return $jsonPath
    } finally {
        Remove-Item -LiteralPath $exportScript -Force -ErrorAction SilentlyContinue
    }
}

function Set-WslOobeCompleteInProfile {
    <#
    Marks WSL first-run (OOBE) complete in ansible's offline NTUSER.DAT hive so
    SSH ForceCommand does not trigger provisioning (which fails under ConstrainedLanguage).
    #>
    param([string]$ProfilePath = 'C:\Users\ansible')

    $ntUserDat = Join-Path $ProfilePath 'NTUSER.DAT'
    if (-not (Test-Path -LiteralPath $ntUserDat)) { return $false }

    $hiveName = 'HomelabAnsibleLoad'
    $loaded   = $false
    try {
        $loadOut = cmd.exe /c "reg load HKU\$hiveName `"$ntUserDat`" 2>&1"
        if ($LASTEXITCODE -ne 0) {
            Write-Warn "Could not load ansible profile hive: $loadOut"
            return $false
        }
        $loaded = $true

        $lxssPath = "Registry::HKEY_USERS\$hiveName\Software\Microsoft\Windows\CurrentVersion\Lxss"
        if (-not (Test-Path -LiteralPath $lxssPath)) {
            Write-Info 'No Lxss registrations in ansible profile yet - skipping OOBE flags.'
            return $false
        }

        New-ItemProperty -LiteralPath $lxssPath -Name 'OOBEComplete' -Value 1 -PropertyType DWord -Force | Out-Null
        Get-ChildItem -LiteralPath $lxssPath -ErrorAction SilentlyContinue |
            Where-Object { $_.PSChildName -match '^\{' } |
            ForEach-Object {
                New-ItemProperty -LiteralPath $_.PSPath -Name 'RunOOBE' -Value 0 -PropertyType DWord -Force | Out-Null
            }
        Write-Info 'WSL OOBEComplete=1 and RunOOBE=0 set in ansible profile registry.'
        return $true
    } finally {
        if ($loaded) {
            cmd.exe /c "reg unload HKU\$hiveName 2>&1" | Out-Null
        }
    }
}

function Invoke-WithAnsibleProfileHive {
    param(
        [string]$ProfilePath = 'C:\Users\ansible',
        [scriptblock]$Action
    )
    $ntUserDat = Join-Path $ProfilePath 'NTUSER.DAT'
    if (-not (Test-Path -LiteralPath $ntUserDat)) { return $null }

    $hiveName = 'HomelabAnsibleLoad'
    $loadOut  = cmd.exe /c "reg load HKU\$hiveName `"$ntUserDat`" 2>&1"
    if ($LASTEXITCODE -ne 0) {
        throw "reg load HKU\$hiveName failed: $loadOut"
    }
    try {
        return & $Action $hiveName
    } finally {
        cmd.exe /c "reg unload HKU\$hiveName 2>&1" | Out-Null
    }
}

function Get-AnsibleProfileLxssDistros {
    <#
    Reads WSL distro registrations from ansible's on-disk NTUSER.DAT hive.
    Returns DistributionName values persisted in the profile file (what SSH loads).
    #>
    param([string]$ProfilePath = 'C:\Users\ansible')

    try {
        return Invoke-WithAnsibleProfileHive -ProfilePath $ProfilePath -Action {
            param($HiveName)
            $lxssPath = "Registry::HKEY_USERS\$HiveName\Software\Microsoft\Windows\CurrentVersion\Lxss"
            if (-not (Test-Path -LiteralPath $lxssPath)) { return @() }

            $rootProps = Get-ItemProperty -LiteralPath $lxssPath -ErrorAction SilentlyContinue
            $result    = [System.Collections.Generic.List[pscustomobject]]::new()

            if ($null -ne $rootProps.OOBEComplete) {
                $result.Add([pscustomobject]@{ Kind = 'LxssRoot'; Name = 'OOBEComplete'; Value = $rootProps.OOBEComplete })
            }

            Get-ChildItem -LiteralPath $lxssPath -ErrorAction SilentlyContinue |
                Where-Object { $_.PSChildName -match '^\{' } |
                ForEach-Object {
                    $p = Get-ItemProperty -LiteralPath $_.PSPath -ErrorAction SilentlyContinue
                    if ($p.DistributionName) {
                        $result.Add([pscustomobject]@{
                            Kind             = 'Distro'
                            Name             = $p.DistributionName
                            BasePath         = $p.BasePath
                            State            = $p.State
                            RunOOBE          = $p.RunOOBE
                            Version          = $p.Version
                            DefaultUid       = $p.DefaultUid
                        })
                    }
                }
            return @($result)
        }
    } catch {
        Write-Warn "Get-AnsibleProfileLxssDistros: $_"
        return @()
    }
}

function Test-WslDistroBasePathUnderProfile {
    param(
        [string]$BasePath,
        [string]$ProfilePath = 'C:\Users\ansible'
    )
    if (-not $BasePath) { return $false }
    $root = $ProfilePath.TrimEnd('\')
    return ($BasePath -ieq $root) -or ($BasePath -like "$root\*")
}

function Get-WslDistroGuidFromBasePath {
    param([string]$BasePath)
    if ($BasePath -match '\\(\{[0-9a-fA-F-]+\})$') {
        return $Matches[1]
    }
    return $null
}

function Copy-WslDistroBasePathTree {
    param(
        [string]$SourceBasePath,
        [string]$DestBasePath
    )

    if (-not (Test-Path -LiteralPath $SourceBasePath)) {
        return @{ Success = $false; Reason = 'source_missing' }
    }
    if ($SourceBasePath -ieq $DestBasePath) {
        return @{ Success = $true; Reason = 'already_in_place' }
    }

    New-Item -ItemType Directory -Path (Split-Path -Parent $DestBasePath) -Force | Out-Null
    if (Test-Path -LiteralPath $DestBasePath) {
        Remove-Item -LiteralPath $DestBasePath -Recurse -Force -ErrorAction SilentlyContinue
    }

    $robocopy = & robocopy.exe $SourceBasePath $DestBasePath /E /COPY:DAT /R:2 /W:3 /NFL /NDL /NJH /NJS 2>&1
    $rc = $LASTEXITCODE
    if ($rc -ge 8) {
        return @{ Success = $false; Reason = 'robocopy_failed'; ExitCode = $rc; Output = ($robocopy | Out-String).Trim() }
    }
    if (-not (Test-Path -LiteralPath (Join-Path $DestBasePath 'ext4.vhdx'))) {
        return @{ Success = $false; Reason = 'ext4_missing_after_copy' }
    }
    return @{ Success = $true; Reason = 'copied' }
}

function Move-AnsibleWslDistroBasePath {
    <#
    Moves distro files from a stale BasePath (e.g. C:\Users\TEMP\...) into the
    ansible profile and updates HKCU BasePath without unregister/reinstall.
    #>
    param(
        [System.Management.Automation.PSCredential]$Credential,
        [string]$DistroName,
        [string]$OldBasePath,
        [string]$ProfilePath = 'C:\Users\ansible'
    )

    $guid = Get-WslDistroGuidFromBasePath -BasePath $OldBasePath
    if (-not $guid) {
        return @{ Success = $false; Reason = 'bad_guid' }
    }

    Ensure-AnsibleWslProfileLayout -ProfilePath $ProfilePath | Out-Null
    $newBasePath = Join-Path $ProfilePath "AppData\Local\wsl\$guid"

    Invoke-WslCli -Arguments @('--shutdown') | Out-Null

    $copy = Copy-WslDistroBasePathTree -SourceBasePath $OldBasePath -DestBasePath $newBasePath
    if (-not $copy.Success) {
        return @{ Success = $false; Reason = $copy.Reason; Detail = $copy }
    }

    $setBasePathScriptContent = @'
#Requires -Version 5.1
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
'@

    Initialize-BootstrapSharedTemp
    $setScript = Join-Path $global:BootstrapSharedTemp 'set-ansible-wsl-basepath.ps1'
    [System.IO.File]::WriteAllText($setScript, $setBasePathScriptContent, [System.Text.UTF8Encoding]::new($false))

    try {
        $set = Invoke-AsUser -Credential $Credential -FilePath 'powershell.exe' -ArgumentList @(
            '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
            '-File', $setScript,
            '-DistroName', $DistroName,
            '-BasePath', $newBasePath
        )
        if ($set.ExitCode -ne 0) {
            return @{ Success = $false; Reason = 'registry_update_failed'; Output = $set.OutputText }
        }
    } finally {
        Remove-Item -LiteralPath $setScript -Force -ErrorAction SilentlyContinue
    }

    return @{ Success = $true; BasePath = $newBasePath; Reason = 'migrated' }
}

function Get-OrphanedWslDistroSourcePaths {
    param(
        [string]$DistroName,
        [string]$ProfilePath = 'C:\Users\ansible'
    )

    $paths = @()
    foreach ($rec in @(Get-AnsibleProfileLxssDistros -ProfilePath $ProfilePath |
            Where-Object { $_.Kind -eq 'Distro' -and $_.Name -eq $DistroName })) {
        if ($rec.BasePath -and (Test-Path -LiteralPath (Join-Path $rec.BasePath 'ext4.vhdx'))) {
            $paths += $rec.BasePath
        }
    }

    $tempRoot = Join-Path $env:SystemDrive 'Users\TEMP\AppData\Local\wsl'
    if (Test-Path -LiteralPath $tempRoot) {
        Get-ChildItem -LiteralPath $tempRoot -Directory -ErrorAction SilentlyContinue | ForEach-Object {
            if (Test-Path -LiteralPath (Join-Path $_.FullName 'ext4.vhdx')) {
                $paths += $_.FullName
            }
        }
    }

    return @($paths | Select-Object -Unique)
}

function Import-AnsibleWslDistroFromSource {
    <#
    Recovers an unregistered distro by copying ext4.vhdx into ansible's profile
    and running wsl --import as the ansible user.
    #>
    param(
        [System.Management.Automation.PSCredential]$Credential,
        [string]$DistroName,
        [string]$SourceBasePath,
        [string]$ProfilePath = 'C:\Users\ansible'
    )

    if (-not (Test-Path -LiteralPath (Join-Path $SourceBasePath 'ext4.vhdx'))) {
        return @{ Success = $false; Reason = 'source_vhdx_missing' }
    }

    Ensure-AnsibleWslProfileLayout -ProfilePath $ProfilePath | Out-Null
    $guid = Get-WslDistroGuidFromBasePath -BasePath $SourceBasePath
    if (-not $guid) {
        $guid = '{' + [guid]::NewGuid().ToString() + '}'
    }

    $destBase = Join-Path $ProfilePath "AppData\Local\wsl\$guid"
    Invoke-WslCli -Arguments @('--shutdown') | Out-Null

    $copy = Copy-WslDistroBasePathTree -SourceBasePath $SourceBasePath -DestBasePath $destBase
    if (-not $copy.Success) {
        return @{ Success = $false; Reason = $copy.Reason; Detail = $copy }
    }

    $vhdxPath = Join-Path $destBase 'ext4.vhdx'
    $import = Invoke-WslCliAsUser `
        -Arguments  @('--import', $DistroName, $destBase, $vhdxPath, '--version', '2') `
        -Credential $Credential `
        -TimeoutSec 600
    if ($import.Corrupted) {
        return @{ Success = $false; Reason = 'wsl_corrupted'; Output = $import.OutputText }
    }
    if ($import.ExitCode -ne 0) {
        return @{ Success = $false; Reason = 'import_failed'; Output = $import.OutputText }
    }

    return @{ Success = $true; BasePath = $destBase; Reason = 'imported' }
}

function Get-AnsibleSessionWslDistroBasePath {
    param(
        [System.Management.Automation.PSCredential]$Credential,
        [string]$DistroName
    )

    $getBasePathScriptContent = @'
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
'@

    Initialize-BootstrapSharedTemp
    $getScript = Join-Path $global:BootstrapSharedTemp 'get-ansible-wsl-basepath.ps1'
    [System.IO.File]::WriteAllText($getScript, $getBasePathScriptContent, [System.Text.UTF8Encoding]::new($false))

    try {
        $run = Invoke-AsUser -Credential $Credential -FilePath 'powershell.exe' -ArgumentList @(
            '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
            '-File', $getScript,
            '-DistroName', $DistroName
        )
        if ($run.ExitCode -ne 0) { return $null }
        return ($run.OutputText -replace [char]0, '').Trim()
    } finally {
        Remove-Item -LiteralPath $getScript -Force -ErrorAction SilentlyContinue
    }
}

function Test-WslDistroInAnsibleProfile {
    param(
        [string]$DistroName,
        [string]$ProfilePath = 'C:\Users\ansible'
    )
    $entries = Get-AnsibleProfileLxssDistros -ProfilePath $ProfilePath
    return [bool]($entries | Where-Object { $_.Kind -eq 'Distro' -and $_.Name -eq $DistroName })
}

function Sync-WslRegistryToAnsibleProfile {
    <#
    Exports HKCU\...\Lxss from a live ansible session (PowerShell JSON export)
    and imports it into C:\Users\ansible\NTUSER.DAT.
    #>
    param(
        [System.Management.Automation.PSCredential]$Credential,
        [string]$ProfilePath = 'C:\Users\ansible'
    )

    $jsonPath = Export-AnsibleLxssJsonFromSession -Credential $Credential -ProfilePath $ProfilePath
    if (-not $jsonPath) {
        Write-Warn 'WSL Lxss JSON export from ansible session failed.'
        return $false
    }

    if (-not (Import-AnsibleLxssJsonToProfile -JsonPath $jsonPath -ProfilePath $ProfilePath)) {
        Write-Warn 'WSL Lxss JSON import into NTUSER.DAT failed.'
        return $false
    }

    Write-Info 'Persisted WSL Lxss registry from ansible session into NTUSER.DAT.'
    Remove-Item -LiteralPath $jsonPath -Force -ErrorAction SilentlyContinue
    return $true
}

function Get-SshdAnsibleWslForceCommandScriptPath {
    return Join-Path $env:ProgramData 'ssh\ansible-wsl-forcecommand.bat'
}

function Get-SshdAnsibleWslForceCommandShellPath {
    return Join-Path $env:ProgramData 'ssh\ansible-wsl-forcecommand.sh'
}

function ConvertTo-WslPath {
    param([string]$WindowsPath)
    if ($WindowsPath -match '^([A-Za-z]):\\(.*)$') {
        return "/mnt/$($Matches[1].ToLower())/$($Matches[2] -replace '\\', '/')"
    }
    throw "Invalid Windows path for WSL conversion: $WindowsPath"
}

function Install-SshdAnsibleWslForceCommandScript {
    <#
    Writes a cmd wrapper plus a bash script that forwards SSH_ORIGINAL_COMMAND
    into WSL so Ansible non-interactive sessions work. Interactive SSH (empty
    command) still drops into a login shell.
    #>
    param(
        [string]$WslDistro,
        [string]$LinuxUser = 'ansible'
    )

    $batPath   = Get-SshdAnsibleWslForceCommandScriptPath
    $shellPath = Get-SshdAnsibleWslForceCommandShellPath
    $wslExe    = Join-Path $env:SystemRoot 'System32\wsl.exe'
    $wslScript = ConvertTo-WslPath -WindowsPath $shellPath

    $shellScript = @'
#!/bin/bash
if [ -n "$SSH_ORIGINAL_COMMAND" ]; then
  exec /bin/bash -lc "$SSH_ORIGINAL_COMMAND"
else
  exec /bin/bash -l
fi
'@

    $batScript = @"
@echo off
"$wslExe" -d $WslDistro -u $LinuxUser -- /bin/bash $wslScript
"@

    $changed = $false
    $existingShell = if ([System.IO.File]::Exists($shellPath)) { [System.IO.File]::ReadAllText($shellPath) } else { '' }
    if ($existingShell -cne $shellScript) {
        $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
        [System.IO.File]::WriteAllText($shellPath, $shellScript.Replace("`r`n", "`n"), $utf8NoBom)
        Write-Info "Wrote ansible WSL ForceCommand shell script to $shellPath."
        $changed = $true
    } else {
        Write-Info "ansible WSL ForceCommand shell script already up to date at $shellPath."
    }

    $existingBat = if ([System.IO.File]::Exists($batPath)) { [System.IO.File]::ReadAllText($batPath) } else { '' }
    if ($existingBat -cne $batScript) {
        [System.IO.File]::WriteAllText($batPath, $batScript)
        Write-Info "Wrote ansible WSL ForceCommand wrapper to $batPath."
        $changed = $true
    } else {
        Write-Info "ansible WSL ForceCommand wrapper already up to date at $batPath."
    }

    return $changed
}

function Get-SshdWslForceCommandLine {
    param(
        [string]$WslDistro,
        [string]$LinuxUser = 'ansible'
    )
    Install-SshdAnsibleWslForceCommandScript -WslDistro $WslDistro -LinuxUser $LinuxUser | Out-Null
    $cmdExe  = Join-Path $env:SystemRoot 'System32\cmd.exe'
    $wrapper = Get-SshdAnsibleWslForceCommandScriptPath
    return "ForceCommand $cmdExe /c `"$wrapper`""
}

function Set-SshdAnsibleMatchBlock {
    <#
    Ensures sshd_config has a Match User ansible block with an absolute
    AuthorizedKeysFile path (immune to ProfileList corruption) and ForceCommand.
    Returns $true if the config file was modified.
    #>
    param(
        [string]$ConfigPath,
        [string]$WslDistro,
        [string]$AuthorizedKeysFile = 'C:/Users/ansible/.ssh/authorized_keys'
    )

    $forceCmdLine = Get-SshdWslForceCommandLine -WslDistro $WslDistro
    $forceCmd     = $forceCmdLine
    $lines    = @(Get-Content -LiteralPath $ConfigPath)
    $changed  = $false

    $matchIdx = -1
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match '^Match User ansible\s*$') { $matchIdx = $i; break }
    }

    if ($matchIdx -lt 0) {
        $block = @(
            '',
            '# Ansible inventory: ansible_user=ansible ansible_shell_type=sh ansible_shell_executable=/bin/bash',
            '# ForceCommand breaks sftp for ansible; use scp or pipelining instead.',
            'Match User ansible',
            "    AuthorizedKeysFile $AuthorizedKeysFile",
            "    $forceCmdLine",
            '    AllowTcpForwarding no'
        )
        $lines += $block
        Set-Content -LiteralPath $ConfigPath -Value $lines -Encoding UTF8
        Write-Info "Added 'Match User ansible' block with absolute AuthorizedKeysFile."
        return $true
    }

    $blockEnd = $lines.Count
    for ($i = $matchIdx + 1; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match '^Match\s') { $blockEnd = $i; break }
    }

    $akIdx = -1
    $fcIdx = -1
    for ($i = $matchIdx + 1; $i -lt $blockEnd; $i++) {
        if ($lines[$i] -match '^\s*AuthorizedKeysFile\s+') { $akIdx = $i }
        if ($lines[$i] -match '^\s*ForceCommand\s+') { $fcIdx = $i }
    }

    $akLine = "    AuthorizedKeysFile $AuthorizedKeysFile"
    if ($akIdx -lt 0) {
        $lines = @($lines[0..$matchIdx]) + @($akLine) + @($lines[($matchIdx + 1)..($lines.Count - 1)])
        $changed = $true
        $blockEnd++
        if ($fcIdx -ge 0 -and $fcIdx -ge $matchIdx) { $fcIdx++ }
        Write-Info 'Inserted absolute AuthorizedKeysFile into Match User ansible block.'
    } elseif ($lines[$akIdx] -ne $akLine) {
        $lines[$akIdx] = $akLine
        $changed = $true
        Write-Info 'Updated AuthorizedKeysFile in Match User ansible block.'
    }

    $expectedFc = "    $forceCmdLine"
    if ($fcIdx -lt 0) {
        Write-Warn 'Match User ansible block has no ForceCommand line - check sshd_config manually.'
    } elseif ($lines[$fcIdx] -ne $expectedFc) {
        $lines[$fcIdx] = $expectedFc
        $changed = $true
        Write-Info 'Updated ForceCommand to launch WSL via cmd.exe (stable under SSH ConstrainedLanguage).'
    }

    if ($changed) {
        Set-Content -LiteralPath $ConfigPath -Value $lines -Encoding UTF8
    } else {
        Write-Info "'Match User ansible' block already configured - skipping."
    }

    return $changed
}

function Get-SshdConfigFirstMatchIndex {
    param([string[]]$Lines)
    for ($i = 0; $i -lt $Lines.Count; $i++) {
        if ($Lines[$i] -match '^Match\s') { return $i }
    }
    return -1
}

function Test-SshdConfigLineInMatchBlock {
    param([string[]]$Lines, [int]$Index)
    $firstMatch = Get-SshdConfigFirstMatchIndex -Lines $Lines
    return ($firstMatch -ge 0 -and $Index -ge $firstMatch)
}

function Test-SshdConfigValid {
    <#
    Runs sshd -t against the given config file. Returns a hashtable with
    Valid (bool) and Output (string).
    #>
    param([string]$ConfigPath = "$env:ProgramData\ssh\sshd_config")

    $sshdExe = Join-Path $env:Windir 'System32\OpenSSH\sshd.exe'
    if (-not (Test-Path -LiteralPath $sshdExe)) {
        return @{ Valid = $false; Output = "sshd.exe not found at $sshdExe" }
    }

    $output = & $sshdExe -t -f $ConfigPath 2>&1 | Out-String
    return @{ Valid = ($LASTEXITCODE -eq 0); Output = $output.Trim() }
}

function Repair-SshdConfigMatchLayout {
    <#
    Moves global-only directives out of Match blocks into the global section.

    Windows default sshd_config often places directives such as StrictModes
  after the Match Group administrators block. OpenSSH still parses them as
    part of that Match block, which makes sshd -t fail once another Match
    block is appended. This repair is idempotent.
    #>
    param([string]$ConfigPath)

    # Directives that must live in the global section (invalid inside Match blocks).
    $globalOnlyPattern = '^(StrictModes|Subsystem|Port|ListenAddress|HostKey|SyslogFacility|LogLevel|LoginGraceTime|MaxAuthTries|MaxSessions|MaxStartups|PermitRootLogin|PermitEmptyPasswords|UsePAM|X11Forwarding|PidFile|ModuliFile|Include)\s+'

    $lines      = @(Get-Content -LiteralPath $ConfigPath)
    $firstMatch = Get-SshdConfigFirstMatchIndex -Lines $lines
    if ($firstMatch -lt 0) { return $false }

    $globalLines = [System.Collections.Generic.List[string]]::new()
    if ($firstMatch -gt 0) {
        foreach ($line in $lines[0..($firstMatch - 1)]) { $globalLines.Add($line) }
    }

    $matchLines  = [System.Collections.Generic.List[string]]::new()
    $relocated   = [System.Collections.Generic.List[string]]::new()
    $changed     = $false

    for ($i = $firstMatch; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match '^Match\s') {
            $matchLines.Add($lines[$i])
            $i++
            while ($i -lt $lines.Count -and $lines[$i] -notmatch '^Match\s') {
                if ($lines[$i] -match $globalOnlyPattern) {
                    $relocated.Add($lines[$i])
                    $changed = $true
                } else {
                    $matchLines.Add($lines[$i])
                }
                $i++
            }
            $i--
            continue
        }
    }

    if (-not $changed) { return $false }

    $globalKeys = @{}
    foreach ($line in $globalLines) {
        if ($line -match '^(\S+)\s+') { $globalKeys[$Matches[1]] = $true }
    }

    foreach ($line in $relocated) {
        if ($line -match '^(\S+)\s+') {
            $key = $Matches[1]
            if (-not $globalKeys.ContainsKey($key)) {
                $globalLines.Add($line)
                $globalKeys[$key] = $true
            }
        }
    }

    $newLines = @($globalLines) + @($matchLines)
    Set-Content -LiteralPath $ConfigPath -Value $newLines -Encoding UTF8
    Write-Info 'sshd_config: relocated global directives out of Match block(s).'
    return $true
}

function Set-SshdConfigGlobalOption {
    <#
    Adds or replaces a global sshd_config directive, ensuring it appears
    before any Match blocks. Safe to call multiple times (idempotent).
    #>
    param([string]$ConfigPath, [string]$Key, [string]$Value)

    Repair-SshdConfigMatchLayout -ConfigPath $ConfigPath | Out-Null

    $lines   = @(Get-Content -LiteralPath $ConfigPath)
    $target  = "$Key $Value"
    $escaped = [regex]::Escape($Key)
    $firstMatch = Get-SshdConfigFirstMatchIndex -Lines $lines

    $existingIdx = -1
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match "^${escaped}\s+") {
            $existingIdx = $i
            break
        }
    }

    if ($existingIdx -ge 0) {
        $inMatch = Test-SshdConfigLineInMatchBlock -Lines $lines -Index $existingIdx
        if ($lines[$existingIdx] -eq $target -and -not $inMatch) {
            Write-Info "sshd_config: '$target' already set - skipping."
            return $false
        }

        if ($inMatch) {
            $removed = $lines[$existingIdx]
            if ($existingIdx -gt 0) {
                $lines = @($lines[0..($existingIdx - 1)] + $lines[($existingIdx + 1)..($lines.Count - 1)])
            } else {
                $lines = @($lines[1..($lines.Count - 1)])
            }
            Write-Info "sshd_config: moved '$removed' out of Match block into global section."
            $firstMatch = Get-SshdConfigFirstMatchIndex -Lines $lines
            $existingIdx = -1
        } else {
            $lines[$existingIdx] = $target
            Set-Content -LiteralPath $ConfigPath -Value $lines -Encoding UTF8
            Write-Info "sshd_config: replaced with '$target'."
            return $true
        }
    }

    $insertIdx = if ($firstMatch -ge 0) { $firstMatch } else { $lines.Count }

    $newLines = @()
    if ($insertIdx -gt 0) { $newLines += $lines[0..($insertIdx - 1)] }
    $newLines += $target
    $newLines += ''
    if ($insertIdx -lt $lines.Count) { $newLines += $lines[$insertIdx..($lines.Count - 1)] }

    Set-Content -LiteralPath $ConfigPath -Value $newLines -Encoding UTF8
    Write-Info "sshd_config: inserted '$target' at line $($insertIdx + 1)."
    return $true
}

# ─── User-impersonation helpers ───────────────────────────────────────────────
#
# WSL distro registrations live in HKCU, so wsl.exe operations (--install,
# --list, command execution) must run under the ansible Windows user's identity.
# These helpers use Start-Process -Credential with a temporary known password
# set for the duration of the bootstrap, reset in a finally block.
#
# File-based IPC uses a shared temp directory that both the admin process and the
# ansible user process can read/write.

# Global scope so orchestrator + stage scripts share one path (stage scripts skip
# re-dot-sourcing common.ps1 when Write-Info already exists, so $script: would
# not be visible when helpers run under a child script's scope).
$global:BootstrapSharedTemp = 'C:\ProgramData\homelab-bootstrap-tmp'

function Initialize-BootstrapSharedTemp {
    New-Item -ItemType Directory -Path $global:BootstrapSharedTemp -Force | Out-Null
    $ansibleUser = Get-LocalUser -Name 'ansible' -ErrorAction SilentlyContinue
    if ($ansibleUser) {
        $sidGrant = "*$($ansibleUser.SID.Value):(OI)(CI)F"
        & icacls.exe $global:BootstrapSharedTemp /grant $sidGrant /T 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) {
            $nameGrant = "$env:COMPUTERNAME\ansible:(OI)(CI)F"
            & icacls.exe $global:BootstrapSharedTemp /grant $nameGrant /T 2>&1 | Out-Null
        }
    }
}

function Set-UserTempPassword {
    <#
    Sets a temporary known password on a local user account and returns a
    PSCredential. Used to run Start-Process -Credential for user-context WSL
    operations. Always call Reset-UserPassword in a finally block.
    Note: sshd_config has PasswordAuthentication no, so this password cannot
    be used for remote login even while it is temporarily set.
    #>
    param([string]$Username)
    $tempPwd   = New-RandomPassword
    $securePwd = ConvertTo-SecureString $tempPwd -AsPlainText -Force
    Set-LocalUser -Name $Username -Password $securePwd
    $tempPwd = $null
    return New-Object System.Management.Automation.PSCredential($Username, $securePwd)
}

function Reset-UserPassword {
    <#
    Sets a new random unknown password on a local user account.
    Call in a finally block after Set-UserTempPassword.
    #>
    param([string]$Username)
    $newPwd = ConvertTo-SecureString (New-RandomPassword) -AsPlainText -Force
    Set-LocalUser -Name $Username -Password $newPwd
    $newPwd = $null
}

function Get-TrimmedFileText {
    param(
        [string]$Path,
        [string]$Default = ''
    )
    if (-not (Test-Path $Path)) { return $Default }
    $content = Get-Content -LiteralPath $Path -Raw -ErrorAction SilentlyContinue
    if ($null -eq $content) { return $Default }
    return $content.Trim()
}

function Invoke-AsUser {
    <#
    Runs an executable under a different Windows user identity and returns the
    captured stdout/stderr and exit code.

    Uses a shared temp directory for file-based IPC:
      - ArgumentList is JSON-serialised so all argument types and special
        characters survive the PowerShell → file → PowerShell round-trip.
      - An inner powershell.exe script (run as the target user) invokes the
        process, captures output, and writes results to temp files readable
        by the parent admin process.
    #>
    param(
        [System.Management.Automation.PSCredential]$Credential,
        [string]$FilePath,
        [string[]]$ArgumentList,
        [int]$TimeoutSec = 300
    )

    Initialize-BootstrapSharedTemp
    $id         = [Guid]::NewGuid().ToString('N').Substring(0, 12)
    $argsFile   = "$global:BootstrapSharedTemp\iau-args-$id.json"
    $outFile    = "$global:BootstrapSharedTemp\iau-out-$id.txt"
    $exitFile   = "$global:BootstrapSharedTemp\iau-exit-$id.txt"
    $scriptFile = "$global:BootstrapSharedTemp\iau-run-$id.ps1"

    try {
        # Serialise argument list — ConvertTo-Json handles all special chars safely
        $ArgumentList | ConvertTo-Json -Compress |
            Set-Content -LiteralPath $argsFile -Encoding UTF8
        [System.IO.File]::WriteAllText($outFile,  '')
        [System.IO.File]::WriteAllText($exitFile, '-1')

        # Build the inner script as an explicit string array so there is no
        # ambiguity about which variables are expanded now vs inside the script.
        # Variables prefixed with backtick-$ are literals for the inner script.
        # Un-escaped $FilePath, $argsFile, $outFile, $exitFile are expanded here
        # to embed the real paths directly in the script text.
        $innerLines = @(
            "`$ErrorActionPreference = 'Continue'"
            "`$raw = Get-Content -LiteralPath '$argsFile' -Raw | ConvertFrom-Json"
            "`$al  = @(`$raw)"
            "`$out = & '$FilePath' @al 2>&1"
            "`$ec  = `$LASTEXITCODE"
            "`$out | ForEach-Object { (`"`$_`" -replace [char]0,'').Trim() } |"
            "    Where-Object { `$_ } |"
            "    Out-File -LiteralPath '$outFile' -Encoding UTF8"
            "`$ec  | Out-File -LiteralPath '$exitFile' -Encoding UTF8"
        )
        [System.IO.File]::WriteAllLines(
            $scriptFile,
            $innerLines,
            [System.Text.UTF8Encoding]::new($false))

        # Start-Process -Credential inherits the caller's current directory as the
        # child process CWD. When bootstrap runs from an admin-only path (e.g.
        # OneDrive), the impersonated user cannot access it and Windows reports
        # the misleading error "The directory name is invalid."
        $proc = Start-Process `
            -FilePath         'powershell.exe' `
            -ArgumentList     @(
                '-NoProfile', '-NonInteractive',
                '-ExecutionPolicy', 'Bypass',
                '-File', $scriptFile) `
            -Credential       $Credential `
            -WorkingDirectory $global:BootstrapSharedTemp `
            -WindowStyle      Hidden `
            -Wait `
            -PassThru

        $stdout   = Get-TrimmedFileText -Path $outFile
        $exitStr  = Get-TrimmedFileText -Path $exitFile -Default "$($proc.ExitCode)"
        $exitCode = try { [int]$exitStr } catch { $proc.ExitCode }

        return [PSCustomObject]@{
            ExitCode   = $exitCode
            OutputText = $stdout
            Corrupted  = (Test-WslCliOutputCorrupted -OutputText $stdout)
        }
    } finally {
        Remove-Item $argsFile, $outFile, $exitFile, $scriptFile `
            -Force -ErrorAction SilentlyContinue
    }
}

function Invoke-WslCliAsUser {
    <#
    Runs wsl.exe with the given arguments under the specified Windows user
    identity. All distro-level operations (--install, --list, command execution)
    must go through this so they target the user's HKCU, not the admin's.
    #>
    param(
        [string[]]$Arguments,
        [System.Management.Automation.PSCredential]$Credential,
        [int]$TimeoutSec = 300
    )
    $wslExe = "$env:SystemRoot\System32\wsl.exe"
    return Invoke-AsUser `
        -Credential   $Credential `
        -FilePath     $wslExe `
        -ArgumentList $Arguments `
        -TimeoutSec   $TimeoutSec
}

function Invoke-WslAsUser {
    <#
    Runs a bash command inside the WSL distro as root, under the specified
    Windows user identity. Throws on non-zero exit code.
    #>
    param(
        [string]$Command,
        [string]$DistroName,
        [System.Management.Automation.PSCredential]$Credential,
        [int]$TimeoutSec = 300
    )
    $result = Invoke-WslCliAsUser `
        -Arguments  @('-d', $DistroName, '-u', 'root', '--', 'bash', '-c', $Command) `
        -Credential $Credential `
        -TimeoutSec $TimeoutSec
    if ($result.Corrupted) {
        throw "WSL appears corrupted.`n$(Get-WslRepairInstructions)"
    }
    if ($result.ExitCode -ne 0) {
        throw "WSL command failed (exit $($result.ExitCode)): $Command`nOutput: $($result.OutputText)"
    }
    return $result.OutputText
}

function Test-WslDistroRegisteredForUser {
    <#
    Returns $true if the named distro is registered in the specified user's WSL
    context (their HKCU). Must run wsl --list as that user.
    #>
    param(
        [string]$DistroName,
        [System.Management.Automation.PSCredential]$Credential
    )
    $result = Invoke-WslCliAsUser -Arguments @('--list', '--quiet') -Credential $Credential
    if ($result.Corrupted -or $result.ExitCode -ne 0) { return $false }
    # Strip null bytes common in WSL UTF-16 list output. Empty list => no distros.
    $cleaned = ('' + $result.OutputText) -replace [char]0, ''
    if (-not $cleaned) { return $false }
    return $cleaned -match [regex]::Escape($DistroName)
}

# ─── Validation helper ────────────────────────────────────────────────────────

function Assert-Check {
    <#
    Reports a named pass/fail check. Sets the caller's $StageAllPassed to
    $false on failure so the stage can emit a summary at exit. The variable
    must be declared with $script: scope in the calling script.
    #>
    param(
        [string]$Label,
        [bool]$Passed,
        [string]$FailHint = ''
    )
    if ($Passed) {
        Write-Info "[PASS] $Label"
    } else {
        Write-Warn "[FAIL] $Label$(if ($FailHint) { ' - ' + $FailHint })"
        $script:StageAllPassed = $false
    }
}
