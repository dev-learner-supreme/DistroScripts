# Ubuntu 26.04 LTS Post-Install Toolkit

Automated, idempotent memory management and swap setup scripts specifically tailored for Ubuntu and Debian-based distributions.

## Directory Structure

```text
Ubuntu 26.04 LTS/
├── zram-swap-setup.sh      # Dedicated 12 GiB zRAM + 32 GiB swapfile setup for Ubuntu 26.04 LTS
├── zram_swap_generator.sh  # Filesystem-aware (ext4, xfs, Btrfs) zRAM & swap setup for Ubuntu/Debian
└── README.md
```

## Features

- **zRAM Configuration**: 12 GiB (12288 MiB) zRAM device with `zstd` compression and priority 100 via `systemd-zram-generator`.
- **Swapfile Management**: 32 GiB swapfile with priority 10 (hosted on a dedicated `/swap` subvolume on Btrfs systems to keep swap out of root snapshots).
- **Kernel Tuning**: Optimizes `vm.swappiness=60`, `vm.vfs_cache_pressure=50`, dirty memory ratios, and `vm.page-cluster=0`.
- **Lazy APT Refresh**: Only runs `apt-get update` when required packages (`systemd-zram-generator`, `btrfs-progs`) are missing.
- **Kernel Compression Inspection**: Verifies live active compression algorithm (`/sys/block/zram0/comp_algorithm`) during verification.
- **Idempotence & Safety**: Safe for repeated execution with timestamped configuration backups (`.bak.YYYYMMDDHHMMSS`).

## Usage

### Apply Setup

```bash
# Run Ubuntu 26.04 LTS setup script
sudo ./zram-swap-setup.sh

# Or run the filesystem-aware generator script
sudo ./zram_swap_generator.sh
```

### Standalone Verification

```bash
# Check current zRAM, swap, and sysctl status without making changes
./zram-swap-setup.sh --verify
./zram_swap_generator.sh --verify
```
