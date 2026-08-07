# Fedora 44 Post-Install Toolkit

Automated, idempotent post-installation setup and diagnostic scripts specifically tailored for Fedora and Fedora-based distributions.

## Directory Structure

```text
Fedora_44/
├── fedora-health-check-full.sh  # Comprehensive, read-only system health check
├── snapper-setup-v2.sh          # Snapper root snapshots, DNF5 plugin, Btrfs Assistant & grub-btrfs
├── zram-swap-setup.sh           # 12 GiB zRAM (zstd) + 32 GiB swapfile (Btrfs/ext4/xfs aware) + sysctl tuning
└── README.md
```

## Features Overview

### zram-swap-setup.sh (Memory & Swap)
- **zRAM Configuration**: 12 GiB (12288 MiB) zRAM device using `zstd` compression and priority 100 via `zram-generator`.
- **Swapfile Management**: 32 GiB swapfile with priority 10 (hosted on a dedicated `/swap` subvolume on Btrfs with SELinux `swapfile_t` context).
- **Lazy DNF Refresh**: Skips package metadata refresh (`dnf makecache`) when all required RPM dependencies are already present.
- **Kernel Verification**: Inspects `/sys/block/zram0/comp_algorithm` in verify mode to confirm active `zstd` kernel backend execution.
- **Kernel Tuning**: Optimizes `vm.swappiness=60`, `vm.vfs_cache_pressure=50`, dirty ratios, and `vm.page-cluster=0`.

### snapper-setup-v2.sh (Btrfs Snapshots & DNF5 Integration)
- **Snapper Configuration**: Automates root `/` Snapper subvolume setup and configures timeline/cleanup retention policies.
- **DNF5 Snapshot Integration**: Provisions custom pre/post transaction hook scripts (`/usr/local/sbin/snapper-dnf-pre.sh`, etc.), including logic to truncate long DNF commands to 75 characters for cleaner logs.
- **Btrfs Assistant**: Installs GUI utility for managing snapshots and subvolumes.
- **grub-btrfs & Boot Mode Detection**: Prompts before enabling the third-party `kylegospo/grub-btrfs` COPR repository, detects UEFI vs Legacy BIOS boot modes, and sets up a daily GRUB regeneration timer.
- **Functional Testing**: Automatically creates and verifies a baseline snapshot upon installation.
- **Summary Dashboard**: Displays a high-visibility health check report upon completion.

### fedora-health-check-full.sh (System Health Diagnostics)
- **Read-Only Guarantees**: Makes no system modifications. Optionally installs missing diagnostic tools only if approved via prompt.
- **Kernel & Boot**: Checks dmesg for errors/warnings, thermal throttling, microcode, systemd failed units, and boot time.
- **Storage & Btrfs**: Verifies NVMe SMART health/temperature, Btrfs device errors, scrub status, zstd compression, and disk usage for `/` and `/home`.
- **Snapshots & Integrations**: Verifies Snapper cadence, active timers, snapshot counts, DNF hook presence, and package integrity (`rpm -Va`).
- **Hardware & Security**: Checks SELinux enforcing state/denials, Secure Boot, Battery health/cycles, and pending Firmware updates.
- **Network & Resources**: Verifies DNS, routes, firewalld, listening ports, zRAM/Swap usage, and systemd journal size.

## Usage

### 1. Memory Management

```bash
sudo ./zram-swap-setup.sh

# Standalone status verification mode
./zram-swap-setup.sh --verify
```

### 2. Btrfs Snapshots & DNF5 Integration

```bash
sudo ./snapper-setup-v2.sh

# Non-interactive mode (automatically accepts COPR prompts)
sudo ./snapper-setup-v2.sh -y

# Verification mode
./snapper-setup-v2.sh --verify
```

### 3. System Health Check

```bash
./fedora-health-check-full.sh

# Skip checks that require internet (firmware metadata, DNS)
./fedora-health-check-full.sh --skip-network

# Skip slow package integrity verification
./fedora-health-check-full.sh --skip-rpm-verify
```
