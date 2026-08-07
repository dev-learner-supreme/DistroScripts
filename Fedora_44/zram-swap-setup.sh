#!/usr/bin/env bash
#
# Fedora / Fedora-family - zRAM + Swap Setup (ext4, xfs, and Btrfs aware)
#
# Features:
#   - 12 GiB (12288 MiB) zRAM (zstd, priority 100) via zram-generator
#   - 32 GiB swapfile (priority 10)
#   - Distro + package manager detection (Fedora/RHEL-likes with dnf5/dnf)
#   - Filesystem-aware swapfile creation:
#       * ext4 / xfs -> fallocate + mkswap at /swapfile
#       * Btrfs      -> dedicated, non-snapshotted subvolume (/swap) + native
#                       `btrfs filesystem mkswapfile` (falls back to manual
#                       truncate/chattr/fallocate sequence on older btrfs-progs),
#                       plus SELinux relabeling (swapfile_t context)
#   - Lazy metadata refresh (only refreshes dnf cache if packages are missing)
#   - Active kernel compression verification in verify mode
#   - Safe to run multiple times (idempotent with config backups)
#   - Standalone verification mode (--verify)
#
# References:
#   - btrfs Swapfile docs: https://btrfs.readthedocs.io/en/latest/Swapfile.html
#   - systemd/zram-generator: https://github.com/systemd/zram-generator
#

set -euo pipefail

########################################
# Configuration
########################################

ZRAM_SIZE_MB=12288
ZRAM_PRIORITY=100

SWAPFILE_NAME="swapfile"
SWAPFILE_PLAIN="/${SWAPFILE_NAME}"        # used on ext4 / xfs / other
BTRFS_SWAP_SUBVOL="/swap"                 # dedicated subvolume on Btrfs,
                                           # so the swapfile never blocks
                                           # (or gets dragged into) a
                                           # snapshot of the root subvolume
SWAPFILE_SIZE_GB=32
SWAPFILE_PRIORITY=10

SWAPPINESS=60
VFS_CACHE_PRESSURE=50
DIRTY_BG_RATIO=5
DIRTY_RATIO=15
PAGE_CLUSTER=0

########################################
# Generic helpers
########################################

backup() {
    if [[ -f "$1" ]]; then
        cp -a "$1" "$1.bak.$(date +%Y%m%d%H%M%S)"
    fi
    return 0
}

require_root() {
    [[ $EUID -eq 0 ]] || {
        echo "Please run as root (sudo)."
        exit 1
    }
}

########################################
# Distro + package manager detection
########################################

detect_distro() {

    if [[ ! -r /etc/os-release ]]; then
        echo "ERROR: /etc/os-release not found or unreadable. Cannot identify distro."
        exit 1
    fi

    # shellcheck disable=SC1091
    . /etc/os-release

    DISTRO_ID="${ID:-unknown}"
    DISTRO_ID_LIKE="${ID_LIKE:-}"
    DISTRO_VERSION="${VERSION_ID:-unknown}"
    DISTRO_NAME="${PRETTY_NAME:-$DISTRO_ID}"

    case "$DISTRO_ID" in
        fedora)
            DISTRO_FAMILY="fedora"
            ;;
        *)
            case " $DISTRO_ID_LIKE " in
                *" fedora "*|*" rhel "*)
                    DISTRO_FAMILY="fedora"
                    ;;
                *)
                    DISTRO_FAMILY="unsupported"
                    ;;
            esac
            ;;
    esac

    if [[ "$DISTRO_FAMILY" == "unsupported" ]]; then
        echo "ERROR: Unsupported distribution: ${DISTRO_NAME} (ID=${DISTRO_ID}, ID_LIKE=${DISTRO_ID_LIKE:-none})"
        echo "This script is purely for Fedora and Fedora-based distros (fedora, rhel, etc.)."
        exit 1
    fi
}

detect_pkg_manager() {

    if command -v dnf5 >/dev/null 2>&1; then
        PKG_MANAGER="dnf5"
    elif command -v dnf >/dev/null 2>&1; then
        PKG_MANAGER="dnf"
    else
        echo "ERROR: Neither dnf5 nor dnf found despite a Fedora-family os-release."
        exit 1
    fi
}

pkg_refresh() {
    "$PKG_MANAGER" makecache
}

pkg_install() {
    "$PKG_MANAGER" install -y "$@"
}

pkg_installed() {
    rpm -q "$1" >/dev/null 2>&1
}

########################################
# Filesystem detection
########################################

detect_filesystem() {

    FS_TYPE=$(findmnt -no FSTYPE / 2>/dev/null || echo "unknown")

    case "$FS_TYPE" in
        ext4|xfs)
            SWAPFILE_PATH="$SWAPFILE_PLAIN"
            ;;
        btrfs)
            if command -v btrfs >/dev/null 2>&1; then
                if ! btrfs subvolume show / &>/dev/null; then
                    echo "ERROR: Root directory '/' is mounted on Btrfs, but 'btrfs subvolume show /' failed."
                    echo "Root '/' must be a valid Btrfs subvolume to safely manage subvolume swapfiles."
                    echo "Aborting setup to protect custom or non-subvolume installations."
                    exit 1
                fi
            fi
            SWAPFILE_PATH="${BTRFS_SWAP_SUBVOL}/${SWAPFILE_NAME}"
            ;;
        zfs)
            echo "ERROR: Unsupported root filesystem: ZFS."
            echo "ZFS requires a zvol-based swap device, not a swapfile."
            exit 1
            ;;
        *)
            echo "Warning: root filesystem '${FS_TYPE}' is not explicitly tested (tested: ext4, xfs, btrfs)."
            echo "Falling back to a plain fallocate()+mkswap swapfile at ${SWAPFILE_PLAIN}."
            SWAPFILE_PATH="$SWAPFILE_PLAIN"
            ;;
    esac
}

########################################
# Dependency installation
########################################

install_dependencies() {

    local packages=()

    if ! pkg_installed zram-generator; then
        packages+=(zram-generator)
    fi

    if [[ "$FS_TYPE" == "btrfs" ]] && ! command -v btrfs >/dev/null 2>&1; then
        if ! pkg_installed btrfs-progs; then
            packages+=(btrfs-progs)
        fi
    fi

    if [[ ${#packages[@]} -gt 0 ]]; then
        echo "Refreshing package metadata (${PKG_MANAGER})..."
        pkg_refresh
        echo "Installing dependencies: ${packages[*]}"
        pkg_install "${packages[@]}"
    else
        echo "All required packages are already installed (skipping package refresh)."
    fi
}

########################################
# Btrfs-specific helpers
########################################

check_btrfs_progs_version() {

    if ! command -v btrfs >/dev/null 2>&1; then
        echo "ERROR: btrfs command still not available after package install."
        exit 1
    fi

    local ver major minor
    ver=$(btrfs --version | awk '{print $2}' | tr -d 'v')
    major=${ver%%.*}
    minor=${ver#*.}
    minor=${minor%%.*}

    if (( major > 6 || (major == 6 && minor >= 1) )); then
        BTRFS_MKSWAPFILE_SUPPORTED=1
    else
        BTRFS_MKSWAPFILE_SUPPORTED=0
        echo "Note: btrfs-progs ${ver} predates 6.1; using manual truncate/chattr/fallocate sequence."
    fi
}

check_btrfs_data_profile() {
    local profile_line
    profile_line=$(btrfs filesystem df / 2>/dev/null | grep '^Data' || true)

    if [[ -n "$profile_line" && "$profile_line" != *single* ]]; then
        echo
        echo "Warning: Btrfs data profile doesn't look like 'single' (${profile_line})."
        echo "Swapfiles require a single-device, single-profile filesystem and may fail to activate."
        echo
    fi
}

ensure_btrfs_subvolume() {

    if btrfs subvolume show "$BTRFS_SWAP_SUBVOL" &>/dev/null; then
        echo "Btrfs subvolume ${BTRFS_SWAP_SUBVOL} already exists."
    elif [[ -e "$BTRFS_SWAP_SUBVOL" ]]; then
        echo "ERROR: ${BTRFS_SWAP_SUBVOL} already exists and is not a Btrfs subvolume."
        echo "Refusing to touch it - move it aside or adjust BTRFS_SWAP_SUBVOL."
        exit 1
    else
        echo "Creating dedicated Btrfs subvolume ${BTRFS_SWAP_SUBVOL} (keeps swapfile out of snapshots)..."
        btrfs subvolume create "$BTRFS_SWAP_SUBVOL"
    fi
}

configure_selinux_swapfile() {

    command -v getenforce >/dev/null 2>&1 || return 0

    local mode
    mode=$(getenforce)
    [[ "$mode" == "Disabled" ]] && return 0

    echo "SELinux is ${mode}; labeling ${SWAPFILE_PATH} as swapfile_t..."

    if ! command -v semanage >/dev/null 2>&1; then
        pkg_install policycoreutils-python-utils
    fi

    if command -v semanage >/dev/null 2>&1; then
        if ! semanage fcontext -a -t swapfile_t "$SWAPFILE_PATH" 2>/dev/null; then
            semanage fcontext -m -t swapfile_t "$SWAPFILE_PATH" || \
                echo "Warning: semanage fcontext failed; check journalctl if swapon fails."
        fi
        restorecon -F "$SWAPFILE_PATH" || \
            echo "Warning: restorecon failed on ${SWAPFILE_PATH}."
    else
        echo "Warning: semanage unavailable; skipping SELinux relabel."
    fi
}

########################################
# Swapfile creation
########################################

create_swapfile_generic() {

    if [[ -f /swap.img ]]; then
        echo "Removing legacy /swap.img..."
        swapoff /swap.img 2>/dev/null || true
        backup /etc/fstab
        sed -i '\|^/swap.img|d' /etc/fstab
        rm -f /swap.img
    fi

    if swapon --show | grep -q "^${SWAPFILE_PATH}"; then
        echo "Swapfile already active."
        return
    fi

    if [[ ! -f "$SWAPFILE_PATH" ]]; then
        echo "Creating ${SWAPFILE_SIZE_GB}G swapfile at ${SWAPFILE_PATH}..."
        fallocate -l "${SWAPFILE_SIZE_GB}G" "$SWAPFILE_PATH"
        chmod 600 "$SWAPFILE_PATH"
        mkswap "$SWAPFILE_PATH"
    fi

    backup /etc/fstab
    sed -i "\|^${SWAPFILE_PATH}|d" /etc/fstab
    echo "${SWAPFILE_PATH} none swap defaults,pri=${SWAPFILE_PRIORITY} 0 0" >> /etc/fstab

    swapon "$SWAPFILE_PATH"
}

create_swapfile_btrfs() {

    check_btrfs_progs_version
    ensure_btrfs_subvolume
    check_btrfs_data_profile

    if swapon --show | grep -q "^${SWAPFILE_PATH}"; then
        echo "Swapfile already active."
        return
    fi

    if [[ ! -f "$SWAPFILE_PATH" ]]; then
        echo "Creating ${SWAPFILE_SIZE_GB}G Btrfs-native swapfile at ${SWAPFILE_PATH}..."

        if [[ "$BTRFS_MKSWAPFILE_SUPPORTED" == "1" ]]; then
            btrfs filesystem mkswapfile --size "${SWAPFILE_SIZE_GB}G" --uuid clear "$SWAPFILE_PATH"
        else
            command -v chattr >/dev/null 2>&1 || pkg_install e2fsprogs
            truncate -s 0 "$SWAPFILE_PATH"
            chattr +C "$SWAPFILE_PATH"
            fallocate -l "${SWAPFILE_SIZE_GB}G" "$SWAPFILE_PATH"
            chmod 600 "$SWAPFILE_PATH"
            mkswap "$SWAPFILE_PATH"
        fi

        chmod 600 "$SWAPFILE_PATH"
    fi

    configure_selinux_swapfile

    backup /etc/fstab
    sed -i "\|^${SWAPFILE_PATH}|d" /etc/fstab
    echo "${SWAPFILE_PATH} none swap defaults,pri=${SWAPFILE_PRIORITY} 0 0" >> /etc/fstab

    swapon "$SWAPFILE_PATH"
}

create_swapfile() {
    if [[ "$FS_TYPE" == "btrfs" ]]; then
        create_swapfile_btrfs
    else
        create_swapfile_generic
    fi
}

########################################
# zRAM
########################################

configure_zram() {

    mkdir -p /etc/systemd/zram-generator.conf.d

    cat >/etc/systemd/zram-generator.conf.d/99-zram.conf <<EOF
# Managed by 01-zram-swap-setup.sh
[zram0]
zram-size = ${ZRAM_SIZE_MB}
compression-algorithm = zstd
swap-priority = ${ZRAM_PRIORITY}
EOF
}

activate_zram() {

    echo
    echo "Attempting live zRAM activation..."

    systemctl daemon-reload

    if swapon --show | grep -q '^/dev/zram0'; then
        echo "zRAM already active; attempting a live reload..."
        if ! systemctl restart dev-zram0.swap 2>/dev/null; then
            echo "Live reload skipped (swapped data in active use). Reboot to apply new size."
        fi
        return
    fi

    systemctl start dev-zram0.swap 2>/dev/null || true
}

########################################
# sysctl
########################################

configure_sysctl() {

    cat >/etc/sysctl.d/99-swappiness.conf <<EOF
# Managed by 01-zram-swap-setup.sh
vm.swappiness=${SWAPPINESS}
vm.vfs_cache_pressure=${VFS_CACHE_PRESSURE}
vm.dirty_background_ratio=${DIRTY_BG_RATIO}
vm.dirty_ratio=${DIRTY_RATIO}
vm.page-cluster=${PAGE_CLUSTER}
EOF

    sysctl --system >/dev/null
}

########################################
# Verification
########################################

verify() {

    echo
    echo "==============================="
    echo "Verification"
    echo "==============================="
    echo

    echo "Distro:            ${DISTRO_NAME} (family: ${DISTRO_FAMILY}, pkg mgr: ${PKG_MANAGER})"
    echo "Root filesystem:   ${FS_TYPE}"
    echo "Swapfile path:     ${SWAPFILE_PATH}"
    if command -v getenforce >/dev/null 2>&1; then
        echo "SELinux:           $(getenforce)"
    fi
    echo

    echo "Swap devices:"
    swapon --show
    echo

    echo "zRAM Device:"
    zramctl || true
    echo

    if [[ -r /sys/block/zram0/comp_algorithm ]]; then
        local active_algo
        active_algo=$(grep -oP '(?<=\[)[a-z0-9_-]+(?=\])' /sys/block/zram0/comp_algorithm || true)
        if [[ -n "$active_algo" ]]; then
            echo "Active zRAM Compression Algorithm: ${active_algo}"
            if [[ "$active_algo" != "zstd" ]]; then
                echo "Warning: zram0 is running '${active_algo}', not 'zstd' as configured in zram-generator."
            fi
            echo
        fi
    fi

    echo "Memory:"
    free -h
    echo

    echo "vm.swappiness = $(sysctl -n vm.swappiness)"
    echo "vm.vfs_cache_pressure = $(sysctl -n vm.vfs_cache_pressure)"
    echo
}

########################################
# Main
########################################

show_help() {
    cat <<EOF
Usage: $0 [OPTIONS]

Fedora zRAM + Btrfs/ext4 Swapfile Setup Script

Options:
  --verify           Verify existing zRAM and swap status without making changes
  -h, --help         Show this help message and exit
EOF
}

main() {

    local verify_only=0

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --verify)
                verify_only=1
                shift
                ;;
            -h|--help)
                show_help
                exit 0
                ;;
            *)
                echo "Unknown option: $1"
                show_help
                exit 1
                ;;
        esac
    done

    if [[ "$verify_only" -eq 1 ]]; then
        detect_distro
        detect_pkg_manager
        detect_filesystem
        verify
        exit 0
    fi

    require_root

    detect_distro
    detect_pkg_manager
    detect_filesystem

    echo "==============================="
    echo "Detected environment"
    echo "==============================="
    echo "Distro:          ${DISTRO_NAME} (${DISTRO_ID} ${DISTRO_VERSION})"
    echo "Package manager: ${PKG_MANAGER}"
    echo "Root filesystem: ${FS_TYPE}"
    echo "Swapfile target: ${SWAPFILE_PATH}"
    echo "==============================="
    echo

    install_dependencies

    create_swapfile

    configure_zram

    activate_zram

    configure_sysctl

    verify
}

main "$@"
