# Windows Homelab Bootstrap

PowerShell scripts that prepare a fresh Windows machine for remote access over Tailscale and Ansible over SSH.

Run everything from an **elevated** PowerShell session on the target machine (`Run as Administrator`). Scripts are idempotent — safe to rerun after reboots or partial runs.

## Prerequisites

- Windows 10 build 19041 (20H1) or later (any Windows 11)
- Internet access
- A **reusable, non-ephemeral** Tailscale auth key ([create one](https://login.tailscale.com/admin/settings/keys))
- Two SSH public key files on disk (for `devops` and `ansible`)

## Full bootstrap

From `scripts\windows`:

```powershell
.\bootstrap.ps1 `
    -TailscaleAuthKey "tskey-auth-..." `
    -DevopsPublicKeyPath "C:\keys\devops.pub" `
    -AnsiblePublicKeyPath "C:\keys\ansible.pub"
```

| Parameter | Required | Default | Notes |
|-----------|----------|---------|-------|
| `TailscaleAuthKey` | Yes | — | Reusable, non-ephemeral key |
| `DevopsPublicKeyPath` | Yes | — | Path to devops `.pub` file |
| `AnsiblePublicKeyPath` | Yes | — | Path to ansible `.pub` file |
| `Hostname` | No | — | Renames machine; script exits for reboot |
| `WslDistro` | No | `Ubuntu` | WSL distro to install |
| `PromptReboot` | No | off | Prompt before reboot when needed |

Runs all stages in order: preflight → machine → Tailscale → SSH → users → WSL.

**Reboots:** Hostname changes and WSL feature enablement may require a reboot. The script exits with instructions; rerun the same command after rebooting.

## Individual stages

Run from `scripts\windows\stages` (or pass the full path). Each stage validates its own work at the end.

### `00-preflight.ps1`

Checks admin rights, Windows version, internet, and SSH key files. Does not change the system.

| Parameter | Required |
|-----------|----------|
| `DevopsPublicKeyPath` | Yes |
| `AnsiblePublicKeyPath` | Yes |

```powershell
.\00-preflight.ps1 `
    -DevopsPublicKeyPath "C:\keys\devops.pub" `
    -AnsiblePublicKeyPath "C:\keys\ansible.pub"
```

### `01-machine.ps1`

Hostname (optional) and power settings (disable sleep/hibernate).

| Parameter | Required | Default |
|-----------|----------|---------|
| `Hostname` | No | — |
| `PromptReboot` | No | off |

```powershell
.\01-machine.ps1 -Hostname "homelab-node" -PromptReboot
```

### `02-tailscale.ps1`

Install Tailscale, start the service, join the tailnet.

| Parameter | Required |
|-----------|----------|
| `TailscaleAuthKey` | Yes |

```powershell
.\02-tailscale.ps1 -TailscaleAuthKey "tskey-auth-..."
```

### `03-ssh.ps1`

Install OpenSSH Server, firewall rule, disable password auth, configure ansible user to land in WSL on SSH.

| Parameter | Required | Default |
|-----------|----------|---------|
| `WslDistro` | No | `Ubuntu` |

```powershell
.\03-ssh.ps1 -WslDistro Ubuntu
```

### `04-users.ps1`

Create `devops` and `ansible` Windows users and install SSH keys.

Pass key **content** or key **file paths** (paths are typical when running standalone):

| Parameter | Required | Notes |
|-----------|----------|-------|
| `DevopsPublicKey` or `DevopsPublicKeyPath` | One of two | Content takes precedence |
| `AnsiblePublicKey` or `AnsiblePublicKeyPath` | One of two | Content takes precedence |

```powershell
.\04-users.ps1 `
    -DevopsPublicKeyPath "C:\keys\devops.pub" `
    -AnsiblePublicKeyPath "C:\keys\ansible.pub"
```

### `05-wsl.ps1`

Enable WSL2, install the distro, set up the Linux `ansible` user and packages inside WSL.

| Parameter | Required | Default |
|-----------|----------|---------|
| `AnsiblePublicKey` or `AnsiblePublicKeyPath` | One of two | — |
| `WslDistro` | No | `Ubuntu` |
| `PromptReboot` | No | off |

```powershell
.\05-wsl.ps1 `
    -AnsiblePublicKeyPath "C:\keys\ansible.pub" `
    -WslDistro Ubuntu `
    -PromptReboot
```

May exit for reboot after enabling WSL Windows features — rerun after rebooting.

## Suggested stage order

If not using `bootstrap.ps1`, run stages in numeric order. Later stages assume earlier ones are done (e.g. SSH before users, WSL install before WSL env is configured in stage 5).

## After bootstrap

From another machine on the same tailnet:

```text
ssh devops@<hostname>    # Windows PowerShell
ssh ansible@<hostname>   # WSL shell
```

Ansible inventory for this host:

```ini
<hostname> ansible_user=ansible ansible_shell_type=sh ansible_shell_executable=/bin/bash
```
