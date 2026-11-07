# System administration scripts

This repository contains Windows remote access helpers and a Proxmox VE GPU passthrough helper. Review each script before running it; some commands change system configuration and require administrative privileges.

## Proxmox VE GPU passthrough

`proxmox-gpu-passthrough.sh` provides the `gpupt` command for Intel and AMD Proxmox hosts. It lists GPUs and IOMMU groups, checks host and VM passthrough setup, configures VFIO and VM settings, creates rollback points, and produces a diagnostic report.

Run it as root on the Proxmox node. For example, copy the script to the node, make it executable, and invoke it directly (or install it as `/usr/local/sbin/gpupt`):

```sh
chmod +x proxmox-gpu-passthrough.sh
./proxmox-gpu-passthrough.sh --help
```

Typical workflow, using the actual GPU PCI address and VM ID for your system:

```sh
./proxmox-gpu-passthrough.sh list
./proxmox-gpu-passthrough.sh check --gpu 01:00
./proxmox-gpu-passthrough.sh configure node --gpu 01:00
# Reboot the Proxmox node after host configuration.
./proxmox-gpu-passthrough.sh configure vm 101 --gpu 01:00
# Stop and start the VM for its updated configuration to take effect.
qm stop 101 && qm start 101
```

The script detects the host CPU and bootloader, and remembers the selected GPU. Use `--dry-run` to preview changes. Configuration writes tool-owned files, updates initramfs/bootloader configuration, or edits the VM config; it creates rollback points first. Inspect them with `backups`, and undo with `rollback last` or a specific rollback ID. Host changes require a reboot to take full effect. Use `--help` for options such as EFI storage, Secure Boot, and `--x-vga`. `--yes` approves ordinary prompts; risky boot-framebuffer and reboot prompts still require confirmation. The `--unsafe-interrupts` option weakens interrupt isolation and should only be used if hardware does not support interrupt remapping.

## Windows remote access helpers

Run the relevant `.bat` file from an **Administrator** Command Prompt on the Windows machine.

## Remote Desktop

`win-enable-rdp.bat` enables RDP, requires Network Level Authentication (NLA), and enables Windows' built-in Remote Desktop firewall rules. Windows Home editions cannot host incoming Microsoft RDP sessions. Use a strong password on every account allowed to sign in, and grant access only to the users who need it.

## WinRM

`win-enable-winrm.bat` changes connected **Public** profiles to **Private**, then runs `Enable-PSRemoting`, checks the local listener, and scopes enabled WinRM HTTP inbound firewall rules to the local subnet. Run it only when those connected Public networks are trusted; a laptop connected to public Wi-Fi should not use this profile change. Existing Private and Domain profiles are left as they are. Avoid exposing TCP 5985 to the internet.

The default listener uses HTTP on TCP 5985. For workgroup or non-domain clients, this repository's client uses NTLM; use a strong Windows account password and configure the client's TrustedHosts narrowly if required. For broader or untrusted networks, use a managed HTTPS listener and appropriate certificate/authentication policy instead of opening HTTP broadly.

## Test from Linux/macOS

Install the client dependency:

```sh
python -m pip install pywinrm
```

Run the connectivity check; it prompts for the password rather than storing it in the file:

```sh
python test-winrm.py 192.168.1.141 --username 'COMPUTERNAME\username'
```

You can omit `--username` to be prompted for it. The test runs `whoami`; a successful local `Test-WSMan` on Windows alone does not prove a remote client can connect.

## Notes

- Local firewall policy or domain Group Policy can override these settings.
- Enabling either service increases remote access to the machine. Use only when needed and review firewall scope and allowed accounts.
