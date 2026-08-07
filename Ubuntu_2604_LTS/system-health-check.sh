#!/usr/bin/env bash
#
# system-health-check.sh
# ----------------------------------------------------------------------------
# Comprehensive READ-ONLY system health check for Ubuntu 26.04 LTS
# Target reference hardware: i5-13500H / 16GB DDR5 / NVMe (Acer Swift Go 14)
#
# GUARANTEE: This script never modifies system state, configs, services, or
# data. The ONLY writes it can perform are, with your explicit per-package
# consent: installing a missing read-only diagnostic tool via `apt install`
# (e.g. lm-sensors, smartmontools). Every such install is opt-in, one at a
# time, and clearly announced before it happens. Decline any prompt to skip
# that check instead.
#
# Sections covered:
#   1. OS / Kernel / Boot
#   2. CPU (info, load, temps, frequency scaling)
#   3. Memory, Swap, and zram
#   4. Battery
#   5. Filesystem & Disk health (usage, SMART, TRIM)
#   6. AppArmor
#   7. Secure Boot
#   8. Hibernate / Resume readiness
#   9. systemd failed units
#  10. Updates available (apt + snap)
#  11. Installed software inventory (dpkg / snap / flatpak counts)
#  12. Network summary
#  13. Overall summary of warnings/issues found
#
# Usage:
#   ./system-health-check.sh            # run with your own user; some
#                                        # sections will note they need root
#   sudo ./system-health-check.sh       # run fully privileged (recommended
#                                        # for complete SMART/dmidecode data)
#
# Safe to re-run any time. No files are written, no services touched, no
# config changed.
# ----------------------------------------------------------------------------

set -uo pipefail

# ---- Output helpers -----------------------------------------------------
c_bold="\e[1m"; c_dim="\e[2m"; c_rst="\e[0m"
c_grn="\e[1;32m"; c_ylw="\e[1;33m"; c_red="\e[1;31m"; c_cyn="\e[1;36m"

WARNINGS=()
ISSUES=()

section() {
  echo
  echo -e "${c_bold}${c_cyn}== $* ==${c_rst}"
}
subsection() {
  echo -e "${c_dim}-- $* --${c_rst}"
}
ok()   { echo -e "  ${c_grn}[OK]${c_rst}   $*"; }
warn() { echo -e "  ${c_ylw}[WARN]${c_rst} $*"; WARNINGS+=("$*"); }
bad()  { echo -e "  ${c_red}[FAIL]${c_rst} $*"; ISSUES+=("$*"); }
info() { echo -e "  ${c_dim}[INFO]${c_rst} $*"; }
skip() { echo -e "  ${c_dim}[SKIP]${c_rst} $*"; }

IS_ROOT=false
if [[ $EUID -eq 0 ]]; then IS_ROOT=true; fi

# ---- Consent-based optional-tool installer -------------------------------
# Never installs silently. Always asks. Always skippable. Only ever
# installs read-only diagnostic/reporting tools, never anything that
# changes system behavior.
ensure_tool() {
  local bin="$1" pkg="$2" purpose="$3"
  if command -v "$bin" &>/dev/null; then
    return 0
  fi
  echo
  echo -e "  ${c_ylw}'$bin' not found${c_rst} (needed to: $purpose)"
  read -r -p "  Install package '$pkg' now via sudo apt install? [y/N] " reply
  case "$reply" in
    [yY]|[yY][eE][sS])
      sudo apt-get update -qq && sudo apt-get install -y "$pkg"
      if command -v "$bin" &>/dev/null; then
        ok "'$bin' installed"
        return 0
      else
        bad "Install attempted but '$bin' still not found"
        return 1
      fi
      ;;
    *)
      skip "Skipping checks that need '$bin'"
      return 1
      ;;
  esac
}

echo -e "${c_bold}Ubuntu System Health Check${c_rst}"
echo -e "${c_dim}Host: $(hostname)   User: $(whoami)   Date: $(date)${c_rst}"
if ! $IS_ROOT; then
  echo -e "${c_dim}Running as non-root — some sections (full SMART, dmidecode, secure boot detail) will be limited.${c_rst}"
  echo -e "${c_dim}Re-run with 'sudo ./system-health-check.sh' for complete results.${c_rst}"
fi

# ============================================================================
section "1. OS / Kernel / Boot"
# ============================================================================
if [[ -f /etc/os-release ]]; then
  . /etc/os-release
  info "OS: ${PRETTY_NAME:-unknown}"
else
  warn "Could not read /etc/os-release"
fi
info "Kernel: $(uname -r)"
info "Architecture: $(uname -m)"

UPTIME_H=$(awk '{print int($1/3600)}' /proc/uptime 2>/dev/null || echo "?")
info "Uptime: $(uptime -p 2>/dev/null || echo "${UPTIME_H}h")"

if [[ -d /run/systemd/system ]]; then
  ok "systemd is init system (PID 1: $(ps -p 1 -o comm= 2>/dev/null))"
else
  warn "systemd not detected as init — unexpected on stock Ubuntu"
fi

BOOT_MODE="Unknown"
if [[ -d /sys/firmware/efi ]]; then
  BOOT_MODE="UEFI"
  ok "Boot mode: UEFI"
else
  BOOT_MODE="Legacy BIOS"
  info "Boot mode: Legacy BIOS"
fi

# ============================================================================
section "2. CPU"
# ============================================================================
if command -v lscpu &>/dev/null; then
  MODEL=$(lscpu | awk -F: '/Model name/{gsub(/^ +/,"",$2); print $2; exit}')
  CORES=$(lscpu | awk -F: '/^CPU\(s\)/{gsub(/^ +/,"",$2); print $2; exit}')
  info "Model: ${MODEL:-unknown}"
  info "Logical CPUs: ${CORES:-unknown}"
else
  warn "lscpu not found (part of util-linux, should be preinstalled)"
fi

if [[ -r /proc/loadavg ]]; then
  LOAD=$(cut -d' ' -f1-3 /proc/loadavg)
  NPROC=$(nproc 2>/dev/null || echo 1)
  LOAD1=$(cut -d' ' -f1 /proc/loadavg)
  # Compare load to core count (integer-safe comparison)
  LOAD1_INT=${LOAD1%.*}
  if (( LOAD1_INT >= NPROC )); then
    warn "Load average (1/5/15 min): $LOAD  — 1-min load meets/exceeds core count ($NPROC)"
  else
    ok "Load average (1/5/15 min): $LOAD  (cores: $NPROC)"
  fi
fi

subsection "Temperature"
if ensure_tool sensors lm-sensors "read CPU/system temperatures"; then
  SENSOR_OUT=$(sensors 2>/dev/null)
  if [[ -n "$SENSOR_OUT" ]]; then
    echo "$SENSOR_OUT" | grep -Ei "core|package|temp" | sed 's/^/  /'
    # Take only the FIRST +NN.N°C on each Core/Package line (the actual
    # live reading), not the "(high = +100.0°C, crit = ...)" threshold
    # values that follow it on the same line.
    HIGH_TEMP=$(echo "$SENSOR_OUT" | grep -Ei "^(Core|Package)" | sed -E 's/^[^+]*\+([0-9]+\.[0-9])°C.*/\1/' | sort -rn | head -1)
    if [[ -n "$HIGH_TEMP" ]] && (( $(echo "$HIGH_TEMP > 90" | bc -l 2>/dev/null || echo 0) )); then
      warn "Peak sensor reading ${HIGH_TEMP}°C is high (>90°C)"
    elif [[ -n "$HIGH_TEMP" ]]; then
      ok "Peak sensor reading: ${HIGH_TEMP}°C"
    fi
  else
    info "sensors ran but returned no data — may need 'sudo sensors-detect' (not run automatically, it modifies kernel module config)"
  fi
fi

subsection "CPU frequency scaling / governor"
if [[ -r /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor ]]; then
  GOV=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor)
  info "Governor: $GOV"
else
  info "cpufreq scaling info not available (may be using intel_pstate passive/active without this interface)"
fi

# ============================================================================
section "3. Memory, Swap, and zram"
# ============================================================================
if command -v free &>/dev/null; then
  free -h | sed 's/^/  /'
  MEM_AVAIL_PCT=$(free | awk '/Mem:/{printf "%.0f", $7/$2*100}')
  if (( MEM_AVAIL_PCT < 10 )); then
    bad "Available memory is critically low (${MEM_AVAIL_PCT}%)"
  elif (( MEM_AVAIL_PCT < 20 )); then
    warn "Available memory is low (${MEM_AVAIL_PCT}%)"
  else
    ok "Available memory: ${MEM_AVAIL_PCT}%"
  fi
fi

subsection "Swap devices"
if command -v swapon &>/dev/null; then
  SWAP_LIST=$(swapon --show 2>/dev/null)
  if [[ -n "$SWAP_LIST" ]]; then
    echo "$SWAP_LIST" | sed 's/^/  /'
    ok "Swap is configured"
  else
    warn "No active swap devices found"
  fi
else
  warn "swapon not found (should be preinstalled via util-linux)"
fi

subsection "zram"
if [[ -e /dev/zram0 ]]; then
  if command -v zramctl &>/dev/null; then
    zramctl 2>/dev/null | sed 's/^/  /'
  fi
  if [[ -r /sys/block/zram0/comp_algorithm ]]; then
    ALGO=$(grep -oP '(?<=\[)[a-z0-9_-]+(?=\])' /sys/block/zram0/comp_algorithm 2>/dev/null)
    info "Active compression: ${ALGO:-unknown}"
  fi
  ok "zram0 present and active"
else
  info "No zram device active (zram0 not found)"
fi

subsection "vm tuning"
for key in swappiness vfs_cache_pressure dirty_ratio dirty_background_ratio page-cluster; do
  val=$(sysctl -n "vm.${key}" 2>/dev/null)
  info "vm.${key} = ${val:-unavailable}"
done

# ============================================================================
section "4. Battery"
# ============================================================================
if command -v upower &>/dev/null; then
  BAT_PATH=$(upower -e 2>/dev/null | grep -i battery | head -1)
  if [[ -n "$BAT_PATH" ]]; then
    BAT_INFO=$(upower -i "$BAT_PATH" 2>/dev/null)
    STATE=$(echo "$BAT_INFO" | awk -F: '/state/{gsub(/^ +/,"",$2); print $2; exit}')
    PCT=$(echo "$BAT_INFO" | awk -F: '/percentage/{gsub(/^ +/,"",$2); print $2; exit}')
    HEALTH_PCT=$(echo "$BAT_INFO" | awk -F: '/capacity/{gsub(/^ +/,"",$2); print $2; exit}')
    CYCLES=$(echo "$BAT_INFO" | awk -F: '/charge-cycles/{gsub(/^ +/,"",$2); print $2; exit}')
    info "State: ${STATE:-unknown}   Charge: ${PCT:-unknown}"
    if [[ -n "$HEALTH_PCT" ]]; then
      HP_NUM=${HEALTH_PCT%\%}
      HP_NUM=${HP_NUM%.*}
      if [[ "$HP_NUM" =~ ^[0-9]+$ ]]; then
        if (( HP_NUM < 70 )); then
          warn "Battery health (design capacity retained): ${HEALTH_PCT} — significantly degraded"
        elif (( HP_NUM < 85 )); then
          info "Battery health: ${HEALTH_PCT} — normal wear for an aged battery"
        else
          ok "Battery health: ${HEALTH_PCT}"
        fi
      else
        info "Battery health (reported): ${HEALTH_PCT}"
      fi
    fi
    [[ -n "$CYCLES" && "$CYCLES" != "N/A" ]] && info "Charge cycles: $CYCLES"
  else
    info "No battery detected (desktop system, or upower found no power_supply battery)"
  fi
else
  ensure_tool upower upower "report battery health and charge state"
fi

# ============================================================================
section "5. Filesystem & Disk Health"
# ============================================================================
subsection "Mounted filesystem usage"
df -hT -x tmpfs -x devtmpfs -x squashfs 2>/dev/null | sed 's/^/  /'
# efivarfs is excluded below: it's a tiny (~KB-sized) virtual filesystem
# exposing UEFI NVRAM variables, not real storage. It's normal and expected
# for it to sit near-full — that reflects firmware-allocated NVRAM space,
# not disk pressure, so it's not a meaningful health signal.
while read -r fs size used avail pct mount; do
  [[ "$fs" == "Filesystem" ]] && continue
  [[ "$mount" == "/sys/firmware/efi/efivars" ]] && continue
  pct_num=${pct%\%}
  [[ "$pct_num" =~ ^[0-9]+$ ]] || continue
  if (( pct_num >= 90 )); then
    bad "$mount is ${pct} full ($fs)"
  elif (( pct_num >= 80 )); then
    warn "$mount is ${pct} full ($fs)"
  fi
done < <(df -h --output=source,size,used,avail,pcent,target -x tmpfs -x devtmpfs -x squashfs 2>/dev/null)

subsection "TRIM (fstrim) status — relevant for NVMe/SSD longevity"
if command -v fstrim &>/dev/null; then
  if systemctl is-enabled fstrim.timer &>/dev/null; then
    ok "fstrim.timer is enabled"
    systemctl status fstrim.timer --no-pager 2>/dev/null | grep -E "Active|Trigger" | sed 's/^/  /'
  else
    warn "fstrim.timer is not enabled — periodic TRIM not scheduled"
  fi
else
  info "fstrim not found (part of util-linux, should be preinstalled)"
fi

subsection "Disk SMART health"
if ensure_tool smartctl smartmontools "read SMART disk health data"; then
  for disk in /dev/nvme0n1 /dev/sda /dev/vda; do
    [[ -b "$disk" ]] || continue
    if $IS_ROOT; then
      SMART_OUT=$(smartctl -H "$disk" 2>/dev/null)
      if echo "$SMART_OUT" | grep -qi "PASSED\|OK"; then
        ok "$disk SMART overall health: PASSED"
      elif echo "$SMART_OUT" | grep -qi "FAILED"; then
        bad "$disk SMART overall health: FAILED — back up data immediately"
      else
        info "$disk SMART check returned no clear PASS/FAIL (may need -d flag for this drive type)"
      fi
    else
      info "$disk found, but reading SMART data needs root — re-run with sudo"
    fi
  done
fi

# ============================================================================
section "6. AppArmor"
# ============================================================================
if command -v aa-status &>/dev/null; then
  if $IS_ROOT; then
    AA_OUT=$(aa-status 2>/dev/null)
    SUMMARY_LINE=$(echo "$AA_OUT" | head -1)
    ENFORCE_COUNT=$(echo "$AA_OUT" | grep -oP '\d+(?= profiles are in enforce mode)')
    COMPLAIN_COUNT=$(echo "$AA_OUT" | grep -oP '\d+(?= profiles are in complain mode)')
    info "$SUMMARY_LINE"
    info "Profiles in enforce mode: ${ENFORCE_COUNT:-0}"
    info "Profiles in complain mode: ${COMPLAIN_COUNT:-0}"
    if systemctl is-active apparmor &>/dev/null || systemctl is-active apparmor.service &>/dev/null; then
      ok "AppArmor service is active"
    else
      warn "AppArmor service does not appear active"
    fi
  else
    info "aa-status needs root for full profile detail — re-run with sudo"
    if [[ -r /sys/module/apparmor/parameters/enabled ]]; then
      EN=$(cat /sys/module/apparmor/parameters/enabled 2>/dev/null)
      info "AppArmor kernel module enabled: ${EN:-unknown}"
    fi
  fi
else
  warn "aa-status not found — apparmor-utils may not be installed"
fi

# ============================================================================
section "7. Secure Boot"
# ============================================================================
if [[ "$BOOT_MODE" == "UEFI" ]]; then
  if ensure_tool mokutil mokutil "check Secure Boot enrollment state"; then
    SB_STATE=$(mokutil --sb-state 2>/dev/null)
    if echo "$SB_STATE" | grep -qi "enabled"; then
      ok "Secure Boot: enabled"
    elif echo "$SB_STATE" | grep -qi "disabled"; then
      info "Secure Boot: disabled"
    else
      info "Secure Boot state: $SB_STATE"
    fi
  fi
else
  info "System is not booted in UEFI mode — Secure Boot not applicable"
fi

# ============================================================================
section "8. Hibernate / Resume Readiness"
# ============================================================================
TOTAL_RAM_KB=$(awk '/MemTotal/{print $2}' /proc/meminfo)
TOTAL_RAM_GB=$(( TOTAL_RAM_KB / 1024 / 1024 ))
info "Total RAM: ${TOTAL_RAM_GB} GiB"

SWAP_TOTAL_KB=$(awk '/SwapTotal/{print $2}' /proc/meminfo)
SWAP_TOTAL_GB=$(( SWAP_TOTAL_KB / 1024 / 1024 ))
info "Total swap (all devices, incl. zram): ${SWAP_TOTAL_GB} GiB"

if (( SWAP_TOTAL_KB >= TOTAL_RAM_KB )); then
  ok "Swap capacity (${SWAP_TOTAL_GB}GiB) is >= RAM (${TOTAL_RAM_GB}GiB) — sufficient size for hibernate"
else
  warn "Swap capacity (${SWAP_TOTAL_GB}GiB) is less than RAM (${TOTAL_RAM_GB}GiB) — insufficient for full hibernate image"
fi

RESUME_PARAM=$(cat /proc/cmdline 2>/dev/null | grep -o 'resume=[^ ]*')
if [[ -n "$RESUME_PARAM" ]]; then
  ok "Kernel resume= parameter set: $RESUME_PARAM"
else
  warn "No resume= kernel parameter set — hibernate resume is not configured, even if swap is large enough"
fi

if [[ -f /etc/default/grub ]]; then
  if grep -q "resume=" /etc/default/grub 2>/dev/null; then
    info "/etc/default/grub references resume="
  fi
fi

# ============================================================================
section "9. systemd Failed Units"
# ============================================================================
if command -v systemctl &>/dev/null; then
  FAILED=$(systemctl --failed --no-legend --no-pager 2>/dev/null)
  if [[ -z "$FAILED" ]]; then
    ok "No failed systemd units"
  else
    bad "Failed units detected:"
    echo "$FAILED" | sed 's/^/  /'
  fi
else
  warn "systemctl not found — unexpected on Ubuntu"
fi

# ============================================================================
section "10. Updates Available"
# ============================================================================
subsection "APT"
if command -v apt &>/dev/null; then
  APT_LIST=$(apt list --upgradable 2>/dev/null | grep -v "^Listing")
  APT_COUNT=$(echo "$APT_LIST" | grep -c . 2>/dev/null || echo 0)
  if [[ "$APT_COUNT" -eq 0 ]]; then
    ok "No APT package updates pending"
  else
    warn "$APT_COUNT APT package(s) have updates available"
    echo "$APT_LIST" | head -10 | sed 's/^/  /'
    (( APT_COUNT > 10 )) && info "...and $(( APT_COUNT - 10 )) more"
  fi
else
  warn "apt not found — unexpected on Ubuntu"
fi

subsection "Snap"
if command -v snap &>/dev/null; then
  SNAP_REFRESH=$(snap refresh --list 2>/dev/null)
  if [[ -z "$SNAP_REFRESH" ]] || echo "$SNAP_REFRESH" | grep -qi "all snaps up to date"; then
    ok "All snaps up to date"
  else
    warn "Snap updates available:"
    echo "$SNAP_REFRESH" | sed 's/^/  /'
  fi
fi

subsection "Unattended-upgrades"
if dpkg -s unattended-upgrades &>/dev/null; then
  if systemctl is-enabled unattended-upgrades &>/dev/null; then
    ok "unattended-upgrades installed and enabled"
  else
    info "unattended-upgrades installed but not enabled as a service"
  fi
else
  info "unattended-upgrades not installed (security patches require manual apt upgrade)"
fi

# ============================================================================
section "11. Installed Software Inventory"
# ============================================================================
if command -v dpkg &>/dev/null; then
  DPKG_COUNT=$(dpkg -l 2>/dev/null | grep -c '^ii')
  info "APT/dpkg packages installed: $DPKG_COUNT"
fi
if command -v snap &>/dev/null; then
  SNAP_COUNT=$(snap list 2>/dev/null | tail -n +2 | wc -l)
  info "Snap packages installed: $SNAP_COUNT"
fi
if command -v flatpak &>/dev/null; then
  FLATPAK_COUNT=$(flatpak list 2>/dev/null | wc -l)
  info "Flatpak apps installed: $FLATPAK_COUNT"
else
  info "flatpak not installed"
fi

# ============================================================================
section "12. Network Summary"
# ============================================================================
if command -v ip &>/dev/null; then
  subsection "Interfaces"
  ip -brief addr show 2>/dev/null | sed 's/^/  /'
fi
if command -v resolvectl &>/dev/null; then
  subsection "DNS"
  resolvectl status 2>/dev/null | grep -E "Current DNS Server|DNS Servers" | head -4 | sed 's/^/  /'
fi

# ============================================================================
section "13. Summary"
# ============================================================================
echo
if [[ ${#ISSUES[@]} -eq 0 && ${#WARNINGS[@]} -eq 0 ]]; then
  echo -e "  ${c_grn}${c_bold}System looks healthy — no issues or warnings flagged.${c_rst}"
else
  if [[ ${#ISSUES[@]} -gt 0 ]]; then
    echo -e "  ${c_red}${c_bold}${#ISSUES[@]} issue(s) needing attention:${c_rst}"
    for i in "${ISSUES[@]}"; do echo -e "    ${c_red}•${c_rst} $i"; done
  fi
  if [[ ${#WARNINGS[@]} -gt 0 ]]; then
    echo -e "  ${c_ylw}${c_bold}${#WARNINGS[@]} warning(s) worth reviewing:${c_rst}"
    for w in "${WARNINGS[@]}"; do echo -e "    ${c_ylw}•${c_rst} $w"; done
  fi
fi
echo
echo -e "${c_dim}Check complete. This script made no changes to your system"
echo -e "(aside from any diagnostic tool installs you explicitly approved above).${c_rst}"
