# Ubuntu 26.04 LTS Post-Install Toolkit

Automated, idempotent post-installation setup, memory management, and read-only diagnostic scripts for Ubuntu 26.04 LTS and Debian-based Linux systems.

## Directory Structure

```text
Ubuntu_2604_LTS/
├── zram-swap-setup.sh      # Dedicated 6 GiB zRAM + 32 GiB swapfile setup for Ubuntu 26.04 LTS
├── zram_swap_generator.sh  # Filesystem-aware (ext4, xfs, Btrfs) 12 GiB zRAM + 32 GiB swapfile setup
├── system-health-check.sh  # Fast, read-only system health and hardware diagnostic scan
├── system-deep-scan.sh    # Phase 2 deep security, package integrity, and boot diagnostic scan
└── README.md
```

## Features Overview

### Memory & Swap Management

#### `zram-swap-setup.sh` (Standard Setup)
- **zRAM**: Configures 6 GiB zRAM (`zstd`, priority 100) via `systemd-zram-generator`.
- **Swapfile**: Provisions 32 GiB `/swapfile` (priority 10).
- **Kernel Tuning**: Sets `vm.swappiness=110`, `vm.vfs_cache_pressure=50`, and dirty memory ratios.
- **Verification**: Run with `--verify` to view active zRAM, swap, and sysctl state without changes.

#### `zram_swap_generator.sh` (Filesystem-Aware Setup)
- **zRAM**: Configures 12 GiB zRAM (`zstd`, priority 100) via `systemd-zram-generator`.
- **Btrfs Integration**: Creates a dedicated, non-snapshotted `/swap` subvolume to prevent swapfiles from cluttering root snapshots.
- **ext4 / XFS Support**: Automated `fallocate` + `mkswap` setup on standard filesystems.
- **Kernel Tuning**: Sets `vm.swappiness=60`, `vm.vfs_cache_pressure=50`, and dirty memory ratios.
- **Verification**: Run with `--verify` to inspect compression backend (`/sys/block/zram0/comp_algorithm`) and active memory pools.

### System Diagnostics

#### `system-health-check.sh` (Quick System Diagnostic)
- **Read-Only Guarantee**: Makes no system or service changes. Prompted opt-in tool installation (`smartmontools`, `lm-sensors`) if missing.
- **Coverage**: System hardware (CPU temps, RAM, NVMe SMART), battery status, AppArmor, Secure Boot, hibernate readiness, failed `systemd` units, pending APT/Snap updates, and installed package inventory.

#### `system-deep-scan.sh` (Phase 2 Deep Scan)
- **Read-Only Guarantee**: Inspects logs and file metadata. Never alters system configuration or services.
- **Coverage**: Kernel (`dmesg`) and `systemd` journal error scans, `debsums` package file integrity checks, broken/orphaned packages, deep SMART attributes, boot sequence breakdown (`systemd-analyze`), thermal throttling, GPU driver errors, SUID/world-writable security audit, and opt-in rootkit scans (`rkhunter`/`chkrootkit`).

## Usage

### 1. Memory & Swap Setup

```bash
# Apply standard Ubuntu 26.04 LTS memory configuration
sudo ./zram-swap-setup.sh

# Or apply filesystem-aware (Btrfs subvolume aware) memory configuration
sudo ./zram_swap_generator.sh

# Verify active state without making changes
./zram-swap-setup.sh --verify
./zram_swap_generator.sh --verify
```

### 2. System Diagnostics

```bash
# Run standard system health check
sudo ./system-health-check.sh

# Run deep system diagnostic scan
sudo ./system-deep-scan.sh
```

## License

This project is released under the [MIT License](../LICENSE).
