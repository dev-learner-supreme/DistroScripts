# DistroScripts

Automated, idempotent post-installation setup, memory tuning, Btrfs snapshot management, and read-only diagnostic scripts tailored for Linux distributions (Fedora & Ubuntu), along with modern Zsh shell configuration.

## Repository Overview

```text
DistroScripts/
├── Fedora_44/           # Post-install toolkit for Fedora 44 (Btrfs, Snapper, zRAM, Swap, Diagnostics)
├── Ubuntu_2604_LTS/     # Post-install toolkit for Ubuntu 26.04 LTS (zRAM, Swap, Diagnostics, Deep Scans)
├── zshrc/              # Modern Zsh shell configuration (Starship, Zoxide, eza, bat, fzf)
├── LICENSE             # MIT License
└── README.md
```

---

## Folder Summary & Toolkits

### 1. Fedora 44 Toolkit ([`Fedora_44/`](Fedora_44/README.md))

Designed for Fedora and RHEL-family distributions with `dnf5` and Btrfs root/home layouts.

| Script | Type | Key Features |
| :--- | :--- | :--- |
| `zram-swap-setup.sh` | Setup / Tuning | 12 GiB `zstd` zRAM + 32 GiB swapfile on dedicated `/swap` subvolume, SELinux `swapfile_t` relabeling, sysctl memory tuning. |
| `snapper-setup-v2.sh` | Setup / Snapshot | Automated Snapper setup for root `/`, DNF5 transaction snapshot hooks, Btrfs Assistant GUI, and `grub-btrfs` boot menu integration. |
| `fedora-health-check-full.sh` | Diagnostic | Read-only diagnostic check for dmesg/journal, Btrfs health & scrub, Snapper cadence, `rpm -Va` integrity, SELinux, and SMART hardware health. |

### 2. Ubuntu 26.04 LTS Toolkit ([`Ubuntu_2604_LTS/`](Ubuntu_2604_LTS/README.md))

Designed for Ubuntu 26.04 LTS and Debian-family distributions with `apt`.

| Script | Type | Key Features |
| :--- | :--- | :--- |
| `zram-swap-setup.sh` | Setup / Tuning | 6 GiB `zstd` zRAM + 32 GiB swapfile setup with kernel memory tuning (`swappiness=110`). |
| `zram_swap_generator.sh` | Setup / Tuning | Filesystem-aware 12 GiB zRAM + 32 GiB swapfile setup (creates `/swap` subvolume on Btrfs, `fallocate` on ext4/xfs). |
| `system-health-check.sh` | Diagnostic | Read-only hardware & system diagnostic (CPU temps, RAM/zRAM, SMART, AppArmor, Secure Boot, failed units, pending updates). |
| `system-deep-scan.sh` | Diagnostic | Read-only Phase 2 deep scan (`dmesg`, journal errors, `debsums` checksums, SUID/permission audit, `systemd-analyze` boot times, optional `rkhunter`/`chkrootkit`). |

### 3. Zsh Environment Setup ([`zshrc/`](zshrc/zshrc))

A productivity-focused `.zshrc` configuration featuring:
- **Prompt & Navigation**: [Starship](https://starship.rs/) prompt, [zoxide](https://github.com/ajeetdsouza/zoxide) (`z`) smart directory jumping.
- **Modern CLI Replacements**: `eza` aliases for `ls`, `bat` with dynamic GNOME light/dark mode theme switching.
- **Interactive Search**: Enhanced `fzf` keybindings with `fd` file discovery and live `bat` syntax-highlighted previews.
- **History & Utility Aliases**: Real-time multi-terminal Zsh history sync and common Git shorthand aliases.

---

## Core Design Principles

- **Idempotency & Safety**: All setup scripts inspect active system state before applying changes and create timestamped backups (`.bak.YYYYMMDDHHMMSS`) of overwritten configuration files.
- **Read-Only Guarantees**: Diagnostic scripts (`fedora-health-check-full.sh`, `system-health-check.sh`, `system-deep-scan.sh`) do not modify system state, services, or configurations.
- **Filesystem Awareness**: Swap management scripts detect Btrfs and automatically create non-snapshotted subvolumes (`/swap`) to ensure swapfiles never interfere with root snapshots.
- **Verification Modes**: Setup scripts include `--verify` flags to view active kernel parameters, compression algorithm state, and swap priorities without modifying anything or requiring root access.

---

## Getting Started

Refer to individual module documentation for detailed usage guidelines:

- [Fedora 44 Instructions](Fedora_44/README.md)
- [Ubuntu 26.04 LTS Instructions](Ubuntu_2604_LTS/README.md)

---

## License

This repository is licensed under the [MIT License](LICENSE).
