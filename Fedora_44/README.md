# Fedora 44 Post-Install Toolkit

Automated, idempotent post-installation setup, Btrfs snapshot management, memory tuning, and read-only diagnostic scripts for Fedora 44 and Fedora-based distributions.

## Directory Structure

```text
Fedora_44/
├── zram-swap-setup.sh          # Filesystem-aware (Btrfs subvolume + SELinux) zRAM & swap setup
├── snapper-setup-v2.sh          # Snapper Btrfs snapshots, DNF5 plugin, Btrfs Assistant & grub-btrfs
├── fedora-health-check-full.sh  # Comprehensive, read-only system health and hardware diagnostic check
└── README.md
```

## Features Overview

### `zram-swap-setup.sh` (Memory & Swap Management)
- **zRAM Configuration**: Provisions 12 GiB (12288 MiB) zRAM using `zstd` compression and priority 100 via `zram-generator`.
- **Swapfile Management**: Creates a 32 GiB swapfile (priority 10) on a dedicated `/swap` Btrfs subvolume to exclude swap data from root snapshots. Applies proper SELinux `swapfile_t` context.
- **Lazy Metadata Refresh**: Skips `dnf makecache` when required packages are already installed.
- **Kernel Tuning**: Optimizes `vm.swappiness=60`, `vm.vfs_cache_pressure=50`, dirty memory ratios, and `vm.page-cluster=0`.
- **Verification Mode**: Run with `--verify` to inspect active compression backend (`/sys/block/zram0/comp_algorithm`) and swap priority without root privileges.

### `snapper-setup-v2.sh` (Btrfs Snapshots & DNF5 Integration)
- **Snapper Automation**: Configures root `/` Snapper subvolume with automated timeline cleanup policies.
- **DNF5 Transaction Hooks**: Installs pre/post transaction hook scripts under `/usr/local/sbin` to automatically snapshot before package updates. Truncates long command lines to 75 characters for clean snapshot descriptions.
- **Btrfs Assistant**: Installs GUI utility for visual management of snapshots and subvolumes.
- **grub-btrfs & Boot Integration**: Configures COPR `kylegospo/grub-btrfs` integration, auto-detects UEFI vs Legacy BIOS, and sets up an optional daily GRUB menu regeneration timer for bootable hourly snapshots.
- **Verification Mode**: Run with `--verify` to check Snapper configurations and active GRUB sync mechanisms.

### `fedora-health-check-full.sh` (System Health Diagnostics)
- **Read-Only Guarantee**: Inspects system health without changing system settings, services, or configurations.
- **Diagnostics Covered**: Kernel (`dmesg`) errors, systemd failed units, NVMe SMART health, Btrfs device errors/scrub/zstd status, Snapper cadence, DNF hooks, package integrity (`rpm -Va`), SELinux enforcing/denial logs, Secure Boot, firmware updates (`fwupdmgr`), firewalld, and resource utilization.

## Usage

### 1. Memory Management

```bash
# Apply zRAM + swapfile setup
sudo ./zram-swap-setup.sh

# Verify active memory state
./zram-swap-setup.sh --verify
```

### 2. Btrfs Snapshots & DNF5 Integration

```bash
# Interactive setup
sudo ./snapper-setup-v2.sh

# Non-interactive setup (auto-accepts COPR prompt)
sudo ./snapper-setup-v2.sh -y

# Verify snapshot configuration and GRUB sync status
./snapper-setup-v2.sh --verify
```

### 3. System Health Check

```bash
# Run comprehensive health diagnostic
./fedora-health-check-full.sh

# Fast offline run (skips DNS & firmware metadata checks)
./fedora-health-check-full.sh --skip-network

# Fast diagnostic run (skips RPM checksum verification)
./fedora-health-check-full.sh --skip-rpm-verify
```

## License

This project is released under the [MIT License](../LICENSE).
