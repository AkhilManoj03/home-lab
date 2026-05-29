This is a text/document task, not a frontend one. Let me just write the updated prompt directly.

Here is the fully revised prompt with all clarifications integrated. I've marked every addition so you can see exactly what changed and why.

---

# Homelab Windows Bootstrap Script — Agent Prompt v2

## High-Level Goal

The script should transform a freshly installed Windows machine into a remotely reachable, Ansible-manageable homelab node over Tailscale.

The script must:

* be idempotent
* be rerunnable safely — **the script is expected to be run multiple times, including across reboots. Each run should detect existing state and only apply missing configuration. This is the primary mechanism for handling staged installation rather than any automated reboot/resume logic.**
* follow 2026 PowerShell scripting best practices
* remain minimal in scope
* only perform bootstrap responsibilities
* NOT become a full configuration-management system

The script should prepare the machine for future management using Ansible from a remote MacBook connected via Tailscale.

The script should assume it is being executed locally on the Windows machine as Administrator.

---

## Architectural Model

This system has three layers:

1. Windows host
2. WSL Ubuntu environment
3. Docker/services inside WSL

Windows is only responsible for:

* hardware/runtime layer
* Tailscale
* OpenSSH
* WSL2 runtime
* remote entrypoint
* recovery/admin access

WSL Ubuntu is the actual Linux server environment and future Ansible target.

Docker will ONLY run inside WSL Ubuntu.
DO NOT install Docker Desktop.
DO NOT configure Docker in this script.

---

## Idempotency Requirements

The script must:

* check current state before applying changes
* skip work already completed
* avoid destructive overwrites
* support safe reruns after partial execution
* use early exits where appropriate
* fail fast on unrecoverable errors

Every major operation should:

* verify whether configuration already exists
* only apply missing state

**The script will commonly be run 2 or more times due to reboot requirements (particularly for WSL feature enablement). This is expected and acceptable. The script must handle this gracefully by detecting already-completed stages and skipping them cleanly.**

---

## Logging Requirements

Use simple console logging with consistent prefixes:

```
INFO: <message>
WARN: <message>
ERROR: <message>
```

Do not use excessive verbosity.

---

## Coding Style Requirements

Use modern PowerShell best practices:

* clear variable names
* readable flow
* minimal but useful comments
* avoid unnecessary abstraction
* create functions only when they improve readability/reuse
* prefer early exits over nested conditionals
* explicit error handling
* deterministic behavior

The final script should feel production-grade and easy to maintain.

---

## Script Inputs

The script should accept parameters for:

* Tailscale auth key (**required** — must be a reusable, non-ephemeral key; see Stage 2)
* hostname (optional)
* path to devops public SSH key (**required**)
* path to ansible public SSH key (**required**)
* WSL distro name (default: `Ubuntu`)
* optional reboot behavior (whether to prompt user to reboot when required, or just warn and exit)

The script should validate all required parameters early and fail fast with a clear error if any are missing or if referenced key files do not exist on disk.

---

## Desired Final State

After all runs of the script complete successfully:

1. Machine is connected to Tailscale
2. OpenSSH Server is installed and running
3. WSL2 Ubuntu is installed and initialized
4. SSH key authentication works for both users
5. Password authentication is disabled
6. `devops` SSH user lands in Windows PowerShell
7. `ansible` SSH user automatically lands in WSL Ubuntu shell
8. `ansible` behaves operationally like a Linux server user
9. MacBook on same tailnet can remotely SSH into the node

---

## Detailed Bootstrap Responsibilities

### Stage 0 — Preflight Checks

Implement:

* verify script is running as Administrator
* verify internet connectivity
* verify supported Windows version — **minimum Windows 10 build 19041 (20H1) or any Windows 11 build; check `[System.Environment]::OSVersion.Version` against build 19041 explicitly and fail with a clear message if not met**
* initialize logging
* validate all input parameters and verify that all referenced public key files exist on disk before proceeding

Fail fast if prerequisites are not met.

---

### Stage 1 — Base Machine Configuration

Implement idempotent logic for:

* optional hostname configuration (only if `$Hostname` parameter provided and current hostname differs)
* disable sleep
* disable hibernate
* configure reasonable remote-management-safe power settings

Do NOT configure unrelated Windows personalization.

---

### Stage 2 — Tailscale Installation

**Important constraint on auth key type:** The Tailscale auth key provided must be reusable and non-ephemeral. An ephemeral key will cause the node to disappear from the tailnet whenever Tailscale restarts, which is not suitable for a persistent homelab node. Add a comment in the script documenting this requirement clearly. The script cannot programmatically verify key type, but should document this prominently.

Implement idempotent logic for:

* detect existing Tailscale installation
* install Tailscale if missing
* **do not hardcode the Tailscale binary path — search standard installation locations and `$env:PATH` to locate `tailscale.exe` after installation**
* ensure Tailscale service is enabled and running
* authenticate using provided auth key (skip if already authenticated/connected)
* verify node is connected to tailnet

Do not assume interactive login.

---

### Stage 3 — OpenSSH Server

Implement idempotent logic for:

* install OpenSSH Server Windows capability if missing
* enable and start the `sshd` service
* configure `sshd` service for automatic startup
* **add a Windows Firewall inbound rule for SSH (port 22) only if one does not already exist — use `Get-NetFirewallRule` to check before calling `New-NetFirewallRule` to avoid errors on rerun**
* validate SSH service is operational after configuration

---

### Stage 4 — Local User Management

Create two local users: `devops` and `ansible`.

#### devops user

* Member of local Administrators group
* Intended for human administration and recovery
* SSH shell should remain Windows PowerShell (default behavior)

#### ansible user

* Limited Windows privileges — **NOT a member of local Administrators group**
* Intended only for automation
* Should automatically enter WSL Ubuntu when SSHing in (see Stage 7)
* Should have passwordless sudo privileges INSIDE WSL Ubuntu (not Windows)

#### User creation rules

* Create each user only if they do not already exist
* **Create users with a randomly generated password, then immediately disable the password on the account. The account should rely solely on SSH key authentication. Do not hardcode or log passwords.**
* Do not overwrite or modify existing users unnecessarily
* Create `.ssh` directories with correct permissions for each user
* Configure `authorized_keys` using the provided public key files

#### Critical: authorized_keys file locations

Windows OpenSSH uses a **different** `authorized_keys` path for members of the Administrators group. This is a standard Windows OpenSSH behavior that must be handled correctly:

* **devops** (Administrator): authorized keys must be placed in `$env:ProgramData\ssh\administrators_authorized_keys`. Keys in the user's `.ssh` directory will be silently ignored. This file must have restricted permissions — only SYSTEM and Administrators should have access, not regular users.
* **ansible** (non-Administrator): authorized keys should be placed in the user's own `C:\Users\ansible\.ssh\authorized_keys` using the standard path.

Implement both cases correctly. Getting this wrong will silently break SSH authentication for the `devops` user.

---

### SSH Authentication Hardening

Modify `sshd_config` to:

* disable password authentication (`PasswordAuthentication no`)
* require public key authentication
* **apply these settings before the `Match User` block added in Stage 7 so they apply globally**
* verify SSH service remains operational after changes by checking service state

Do not lock out valid key-based access. Apply hardening only after confirming authorized keys are in place.

---

### Stage 5 — WSL2 Installation

Implement idempotent logic for:

* enable required Windows features: `VirtualMachinePlatform` and `Microsoft-Windows-Subsystem-Linux` — check if already enabled before attempting to enable
* install WSL2 runtime
* set WSL2 as the default version
* **install the Ubuntu distro using `wsl --install -d <distro> --no-launch` to avoid triggering interactive first-run prompts**
* initialize the distro by running a no-op command as root: `wsl -d <distro> -u root -- echo "WSL ready"` to confirm the distro is accessible without interactive setup
* verify WSL launches successfully

**Reboot handling:** Enabling the `VirtualMachinePlatform` and `Microsoft-Windows-Subsystem-Linux` Windows features requires a reboot. The script must:

1. Detect whether a reboot is required after enabling features (check the return code or pending-reboot registry keys)
2. If a reboot is required, print a clear `INFO:` message telling the user to reboot and rerun the script
3. Exit cleanly — **do not attempt to schedule automatic rerun via scheduled task, do not force reboot without user action**
4. On the next run, the script will detect the features are already enabled and proceed to WSL distro installation

This multi-run behavior is expected and acceptable given the script's idempotency design.

---

### Stage 6 — Configure WSL Environment

Bootstrap the WSL Ubuntu environment by running commands inside it as root via:
```
wsl -d <distro> -u root -- bash -c "<command>"
```

Do not rely on interactive WSL sessions or first-run prompts. All WSL configuration must be driven non-interactively from Windows PowerShell.

Inside WSL Ubuntu, ensure idempotently:

* `apt` package index is updated
* `sudo` is installed
* `python3` is installed (required for Ansible)
* `openssh-client` is installed
* Linux user `ansible` is created if it does not already exist
* Passwordless sudo is configured for the `ansible` Linux user (add entry to `/etc/sudoers.d/ansible`)
* `~/.ssh` directory created for the `ansible` Linux user with correct ownership and permissions (`700`)
* `authorized_keys` configured for the `ansible` Linux user using the provided ansible public key, with correct permissions (`600`)

DO NOT:

* install Docker
* install Ansible
* install development tooling
* configure containers

Keep WSL bootstrap minimal.

---

### Stage 7 — SSH User Experience

#### devops user

SSH login should land in Windows PowerShell. This is the default behavior for a Windows local user and requires no special configuration beyond not overriding it.

#### ansible user — WSL handoff

SSH login for the `ansible` user must automatically transition into the WSL Ubuntu shell immediately on connection. This must work for both interactive SSH sessions and non-interactive Ansible command execution.

**Implementation — use `sshd_config` `Match User` block with `ForceCommand`:**

Add the following to the end of `sshd_config`:

```
Match User ansible
    ForceCommand wsl.exe -d <distro> -u ansible
    AllowTcpForwarding no
```

**Do not use:**

* PowerShell profile modifications (`$PROFILE`)
* Registry default shell overrides (`HKLM:\SOFTWARE\OpenSSH\DefaultShell`) — this is a global setting that would affect all users including `devops`
* Any interactive shell trick or `.bashrc` hack

**Why `Match User` + `ForceCommand`:** This is the correct OpenSSH mechanism for per-user shell enforcement. It is applied at the protocol level by the SSH daemon, making it reliable for both interactive and non-interactive connections. It does not interfere with other users.

**Important Ansible inventory requirement:** Because the SSH connection lands on Windows but the shell is Linux (WSL), the Ansible inventory for this host must specify:

```ini
ansible_shell_type=sh
ansible_shell_executable=/bin/bash
```

Add this as a comment in the script near the `Match User` block so the operator knows to configure their Ansible inventory correctly.

**Known limitation of `ForceCommand` with sftp:** A plain `ForceCommand` will break `sftp` subsystem access for the `ansible` user. If Ansible's `ssh` connection plugin requires file transfer via sftp, this will fail. The operator should configure Ansible to use `scp` or `sftp` is not required for the intended use case. Add a comment documenting this limitation.

---

### Stage 8 — Validation

At end of script, verify and report:

* Tailscale service is running and node appears connected
* `sshd` service is running
* WSL distro is accessible (run a simple command via `wsl -d <distro> -u root -- echo ok`)
* `sshd_config` contains the `Match User ansible` block (confirm configuration is present)
* Print a concise success summary of all verified items

**Note on SSH handoff validation:** The script cannot fully end-to-end validate the `ansible` SSH handoff from within a local PowerShell session — that requires an actual inbound SSH connection. The validation stage should verify that the *configuration is correctly in place* and note that end-to-end SSH testing must be performed from the MacBook after bootstrap completes.

---

## Additional Constraints

DO NOT:

* install Docker Desktop
* install Docker Engine
* install Kubernetes
* install development tools
* install GUI applications
* configure homelab services

This script is ONLY responsible for bootstrap infrastructure.

---

## Expected Operational Model After Bootstrap

From MacBook connected to same tailnet:

```
ssh devops@<hostname>
→ lands in Windows PowerShell

ssh ansible@<hostname>
→ lands directly in WSL Ubuntu shell
```

Future Ansible runs will primarily target the `ansible` user and the WSL Linux environment.

Windows SSH access through the `devops` user must remain functional for future Windows management tasks.

**Required Ansible inventory configuration for the ansible user (document in script):**
```ini
[homelab]
<hostname> ansible_user=ansible ansible_shell_type=sh ansible_shell_executable=/bin/bash
```
