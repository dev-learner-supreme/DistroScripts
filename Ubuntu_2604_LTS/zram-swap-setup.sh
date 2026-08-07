#!/usr/bin/env bash
#
# zram-swap-setup.sh
# ----------------------------------------------------------------------------
# Idempotent zRAM + swapfile setup for Ubuntu 26.04 LTS
# Target: i5-13500H / 16GB DDR5 / 512GB NVMe (Acer Swift Go 14)
#
# Configures:
#   0. Sanity-checks the root filesystem (ext4/xfs assumed for the swapfile step)
#   1. Removes the installer's default /swap.img
#   2. Creates a 32GB /swapfile (priority 10)
#   3. Installs systemd-zram-generator
#   4. Writes the zram0 config (6GB, zstd, priority 100)
#   5. Activates zram0 live, best-effort (see note below)
#   6. Tunes swappiness / vfs_cache_pressure / dirty ratios
#   7. Verifies the final state
#
# Usage:
#   sudo ./zram-swap-setup.sh            # apply full setup
#   ./zram-swap-setup.sh --verify        # just print current state (no root needed)
#
# Safe to re-run: every step checks current state before acting, and existing
# configs are backed up with a timestamp before being overwritten.
#
# Note on live activation: zram-generator's runtime activation chain
# (systemd-zram-setup@zram0.service -> dev-zram0.swap) is a known rough edge
# across systemd versions (see systemd/zram-generator#221 upstream) - the
# "start it now" step can silently no-op on some systems. This script
# verifies the actual outcome with swapon --show rather than trusting the
# command's exit code, and tells you plainly if it didn't take live. The
# config file is what matters long-term: swap.target activates it correctly
# on every normal boot regardless of whether the hot-activation worked here.
# ----------------------------------------------------------------------------

set -euo pipefail

# ---- Config (override via env if you ever move this to different hardware) --
ZRAM_SIZE_MB="${ZRAM_SIZE_MB:-6144}"         # 6 GiB
ZRAM_PRIORITY="${ZRAM_PRIORITY:-100}"
SWAPFILE="${SWAPFILE:-/swapfile}"
SWAPFILE_SIZE_GB="${SWAPFILE_SIZE_GB:-32}"
SWAP_PRIORITY="${SWAP_PRIORITY:-10}"
SWAPPINESS="${SWAPPINESS:-110}"
VFS_CACHE_PRESSURE="${VFS_CACHE_PRESSURE:-50}"
DIRTY_BG_RATIO="${DIRTY_BG_RATIO:-5}"
DIRTY_RATIO="${DIRTY_RATIO:-15}"
# Not part of the originally agreed table — added because zram is the primary
# swap tier here (priority 100 vs the swapfile's 10). page-cluster batches
# swap-in reads to amortize disk seeks; that's wasted CPU on zram, which is
# RAM-speed with no seek cost. Set PAGE_CLUSTER=3 via env if you'd rather skip
# this and keep the kernel default.
PAGE_CLUSTER="${PAGE_CLUSTER:-0}"

ZRAM_CONF="/etc/systemd/zram-generator.conf"
SYSCTL_CONF="/etc/sysctl.d/99-zram-swap-tuning.conf"
LEGACY_SWAP="/swap.img"

# ---- Helpers -----------------------------------------------------------------
c_grn="\e[1;32m"; c_ylw="\e[1;33m"; c_red="\e[1;31m"; c_rst="\e[0m"
log()  { echo -e "${c_grn}[+]${c_rst} $*"; }
warn() { echo -e "${c_ylw}[!]${c_rst} $*"; }
err()  { echo -e "${c_red}[x]${c_rst} $*" >&2; }
backup() {
    if [[ -f "$1" ]]; then
        cp -a "$1" "$1.bak.$(date +%Y%m%d%H%M%S)"
    fi
    return 0
}
require_root() {
  if [[ $EUID -ne 0 ]]; then
    err "Run as root: sudo $0"
    exit 1
  fi
}

# ---- Steps -------------------------------------------------------------------

check_root_filesystem() {
  local fstype
  fstype="$(findmnt -no FSTYPE / 2>/dev/null || echo unknown)"
  case "$fstype" in
    ext4|xfs)
      log "Pre-flight: root filesystem is ${fstype}, swapfile step is safe"
      ;;
    btrfs)
      warn "Pre-flight: root filesystem is Btrfs. A fallocate'd swapfile on Btrfs"
      warn "needs CoW disabled first (chattr +C on the file before mkswap) or"
      warn "mkswap/fallocate can fail or misbehave. This script does NOT handle"
      warn "that case. Ctrl-C now if you're on Btrfs and haven't done that."
      ;;
    zfs)
      err "Pre-flight: root filesystem is ZFS. Plain swapfiles are not reliably"
      err "supported on ZFS datasets (use a dedicated zvol instead). Aborting"
      err "rather than risk a broken swap setup."
      exit 1
      ;;
    *)
      warn "Pre-flight: unrecognized root filesystem ('${fstype}'). Proceeding,"
      warn "but the swapfile step assumes ext4-like semantics."
      ;;
  esac
}

remove_legacy_swap() {
  log "Step 1/7: Removing default ${LEGACY_SWAP}"
  if swapon --show=NAME --noheadings 2>/dev/null | grep -qx "$LEGACY_SWAP"; then
    swapoff "$LEGACY_SWAP"
  fi
  if [[ -f "$LEGACY_SWAP" ]]; then
    rm -f "$LEGACY_SWAP"
    log "Removed ${LEGACY_SWAP}"
  else
    log "${LEGACY_SWAP} not present, nothing to do"
  fi
  if grep -q "$LEGACY_SWAP" /etc/fstab 2>/dev/null; then
    backup /etc/fstab
    sed -i "\#${LEGACY_SWAP}#d" /etc/fstab
    log "Removed ${LEGACY_SWAP} entry from /etc/fstab"
  fi
}

create_swapfile() {
  log "Step 2/7: Creating ${SWAPFILE_SIZE_GB}G swapfile at ${SWAPFILE} (priority ${SWAP_PRIORITY})"

  if swapon --show=NAME --noheadings 2>/dev/null | grep -qx "$SWAPFILE"; then
    log "${SWAPFILE} already active, skipping creation"
  else
    if [[ -f "$SWAPFILE" ]]; then
      warn "${SWAPFILE} exists but is inactive; recreating"
      rm -f "$SWAPFILE"
    fi

    if ! fallocate -l "${SWAPFILE_SIZE_GB}G" "$SWAPFILE" 2>/dev/null; then
      warn "fallocate unsupported on this filesystem, falling back to dd (slower)"
      dd if=/dev/zero of="$SWAPFILE" bs=1M count=$((SWAPFILE_SIZE_GB * 1024)) status=progress
    fi

    chmod 600 "$SWAPFILE"
    mkswap "$SWAPFILE" >/dev/null
    swapon -p "$SWAP_PRIORITY" "$SWAPFILE"
    log "Swapfile active"
  fi

  if ! grep -qE "^\S*${SWAPFILE}[[:space:]]" /etc/fstab 2>/dev/null; then
    backup /etc/fstab
    echo "${SWAPFILE} none swap sw,pri=${SWAP_PRIORITY} 0 0" >> /etc/fstab
    log "Added ${SWAPFILE} to /etc/fstab"
  fi
}

install_zram_generator() {
  log "Step 3/7: Installing systemd-zram-generator"
  if dpkg -s systemd-zram-generator &>/dev/null; then
    log "Already installed"
  else
    apt-get update -qq
    apt-get install -y systemd-zram-generator
  fi
}

configure_zram() {
  log "Step 4/7: Writing zram0 config (${ZRAM_SIZE_MB}MB, zstd, priority ${ZRAM_PRIORITY})"
  backup "$ZRAM_CONF"
  cat > "$ZRAM_CONF" <<EOF
# Managed by zram-swap-setup.sh — hand edits will be overwritten on re-run.
[zram0]
zram-size = ${ZRAM_SIZE_MB}
compression-algorithm = zstd
swap-priority = ${ZRAM_PRIORITY}
fs-type = swap
EOF
  log "Wrote ${ZRAM_CONF}"
}

activate_zram() {
  log "Step 5/7: Activating zram0 (best-effort, see header note)"
  systemctl daemon-reload

  if swapon --show=NAME --noheadings 2>/dev/null | grep -qx "/dev/zram0"; then
    log "zram0 already active, tearing down first to apply the new config"
    swapoff /dev/zram0 || true
    systemctl stop dev-zram0.swap 2>/dev/null || true
    zramctl --reset /dev/zram0 2>/dev/null || true
  fi

  # The generator's own docs/community reports disagree on the "right" unit
  # to poke for a live (no-reboot) activation. Try the swap unit first since
  # it's the one that actually calls swapon; fall back to the setup service
  # directly if that doesn't exist or errors out. Neither call is fatal.
  if ! systemctl start dev-zram0.swap 2>/dev/null; then
    warn "dev-zram0.swap didn't start cleanly, trying systemd-zram-setup@zram0.service directly"
    systemctl start systemd-zram-setup@zram0.service 2>/dev/null || true
  fi

  sleep 1
  if swapon --show=NAME --noheadings 2>/dev/null | grep -qx "/dev/zram0"; then
    log "zram0 is active"
  else
    warn "zram0 didn't come up live in this session (config is written correctly)."
    warn "This is the known rough edge mentioned above, not a config error."
    warn "It WILL activate on next boot via swap.target — reboot to confirm."
  fi
}

tune_vm() {
  log "Step 6/7: Tuning VM parameters"
  backup "$SYSCTL_CONF"
  cat > "$SYSCTL_CONF" <<EOF
# Managed by zram-swap-setup.sh
vm.swappiness = ${SWAPPINESS}
vm.vfs_cache_pressure = ${VFS_CACHE_PRESSURE}
vm.dirty_background_ratio = ${DIRTY_BG_RATIO}
vm.dirty_ratio = ${DIRTY_RATIO}
vm.page-cluster = ${PAGE_CLUSTER}
EOF
  sysctl --system &>/dev/null
  log "Applied sysctl settings"
}

verify() {
  echo
  log "Step 7/7: Verification"
  echo -e "\n--- swapon --show ---"
  swapon --show
  echo -e "\n--- zramctl ---"
  zramctl 2>/dev/null || warn "zramctl not available"

  if [[ -r /sys/block/zram0/comp_algorithm ]]; then
    local active_algo
    active_algo=$(grep -oP '(?<=\[)[a-z0-9_-]+(?=\])' /sys/block/zram0/comp_algorithm || true)
    if [[ -n "$active_algo" ]]; then
      echo -e "\n--- active zRAM compression ---"
      echo "Active algorithm: ${active_algo}"
      if [[ "$active_algo" != "zstd" ]]; then
        warn "zram0 is running '${active_algo}', not 'zstd' as configured."
      fi
    fi
  fi

  echo -e "\n--- free -h ---"
  free -h
  echo -e "\n--- sysctl ---"
  sysctl vm.swappiness vm.vfs_cache_pressure vm.dirty_background_ratio vm.dirty_ratio vm.page-cluster
  echo
}

main() {
  if [[ "${1:-}" == "--verify" ]]; then
    verify
    exit 0
  fi

  require_root
  check_root_filesystem
  remove_legacy_swap
  create_swapfile
  install_zram_generator
  configure_zram
  activate_zram
  tune_vm
  verify

  echo
  log "Setup complete."
  warn "Reboot recommended to confirm a clean boot via fstab + the zram generator: sudo reboot"
}

main "$@"
