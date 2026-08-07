#!/usr/bin/env bash
#
# system-deep-scan.sh
# ----------------------------------------------------------------------------
# PHASE 2 — Deep system diagnostic scan for Ubuntu 26.04 LTS
# Companion to system-health-check.sh. Run this monthly, or whenever
# something feels subtly off, rather than on every boot — some sections
# here are slower and more invasive to inspect (full filesystem SUID scan,
# package checksum verification, optional rootkit scanners).
#
# READ-ONLY GUARANTEE — same policy as system-health-check.sh:
#   - This script never modifies system configuration, services, or data.
#   - The ONLY writes it can ever make are, with your explicit per-tool
#     consent: installing a diagnostic package via apt (debsums, rkhunter,
#     chkrootkit, deborphan). Decline any prompt to skip that check.
#   - rkhunter/chkrootkit, if you opt in, may write their OWN internal
#     log/database files under /var/lib/rkhunter or similar — that is
#     normal operation of those tools recording their own scan history,
#     NOT a modification to your actual system files. This script does
#     NOT run 'rkhunter --propupd' or any command that rewrites their
#     baseline against your current file state, since that could mask
#     a real compromise if run at the wrong time. You can do that
#     yourself later, deliberately, if you trust your current state.
#   - Nothing here touches package installs/removals, filesystems, boot
#     config, permissions, or any file outside the tools' own log dirs.
#
# Sections:
#   1. Kernel log (dmesg) errors/warnings
#   2. systemd journal priority-based error scan
#   3. Package integrity verification (debsums)
#   4. Broken / orphaned / half-configured packages
#   5. Deep SMART attributes (beyond simple PASS/FAIL)
#   6. Boot performance breakdown (systemd-analyze)
#   7. Thermal throttling history
#   8. GPU / display driver errors
#   9. Permission & security audit (SUID binaries, world-writable files, sudoers)
#  10. Optional rootkit/malware scan (rkhunter / chkrootkit) — opt-in, slow
#  11. Summary
#
# Usage:
#   sudo ./system-deep-scan.sh
#   (root strongly recommended — most sections need it for full data;
#   script will note which parts are skipped/limited without it)
# ----------------------------------------------------------------------------

set -uo pipefail

c_bold="\e[1m"; c_dim="\e[2m"; c_rst="\e[0m"
c_grn="\e[1;32m"; c_ylw="\e[1;33m"; c_red="\e[1;31m"; c_cyn="\e[1;36m"

WARNINGS=()
ISSUES=()

section() { echo; echo -e "${c_bold}${c_cyn}== $* ==${c_rst}"; }
subsection() { echo -e "${c_dim}-- $* --${c_rst}"; }
ok()   { echo -e "  ${c_grn}[OK]${c_rst}   $*"; }
warn() { echo -e "  ${c_ylw}[WARN]${c_rst} $*"; WARNINGS+=("$*"); }
bad()  { echo -e "  ${c_red}[FAIL]${c_rst} $*"; ISSUES+=("$*"); }
info() { echo -e "  ${c_dim}[INFO]${c_rst} $*"; }
skip() { echo -e "  ${c_dim}[SKIP]${c_rst} $*"; }

IS_ROOT=false
[[ $EUID -eq 0 ]] && IS_ROOT=true

ensure_tool() {
  local bin="$1" pkg="$2" purpose="$3"
  command -v "$bin" &>/dev/null && return 0
  echo
  echo -e "  ${c_ylw}'$bin' not found${c_rst} (needed to: $purpose)"
  read -r -p "  Install package '$pkg' now via sudo apt install? [y/N] " reply
  case "$reply" in
    [yY]|[yY][eE][sS])
      sudo apt-get update -qq && sudo apt-get install -y "$pkg"
      command -v "$bin" &>/dev/null && { ok "'$bin' installed"; return 0; }
      bad "Install attempted but '$bin' still not found"; return 1 ;;
    *) skip "Skipping checks that need '$bin'"; return 1 ;;
  esac
}

confirm() {
  local prompt="$1"
  read -r -p "  $prompt [y/N] " reply
  [[ "$reply" =~ ^[yY]([eE][sS])?$ ]]
}

echo -e "${c_bold}Ubuntu Deep System Scan (Phase 2)${c_rst}"
echo -e "${c_dim}Host: $(hostname)   User: $(whoami)   Date: $(date)${c_rst}"
if ! $IS_ROOT; then
  echo -e "${c_dim}Running as non-root — several sections need root for full data.${c_rst}"
  echo -e "${c_dim}Re-run with 'sudo ./system-deep-scan.sh' for complete results.${c_rst}"
fi
echo -e "${c_dim}This scan reads logs and file metadata only. It writes nothing to your${c_rst}"
echo -e "${c_dim}system except diagnostic tools you explicitly approve installing below.${c_rst}"

# ============================================================================
section "1. Kernel Log (dmesg) — Errors and Warnings"
# ============================================================================
if $IS_ROOT; then
  DMESG_ERR=$(dmesg --level=err,crit,alert,emerg -T 2>/dev/null)
  DMESG_WARN=$(dmesg --level=warn -T 2>/dev/null)
  ERR_COUNT=$(echo "$DMESG_ERR" | grep -c . 2>/dev/null || echo 0)
  WARN_COUNT=$(echo "$DMESG_WARN" | grep -c . 2>/dev/null || echo 0)

  if [[ "$ERR_COUNT" -gt 0 ]]; then
    bad "$ERR_COUNT kernel error/critical message(s) found since last boot"
    echo "$DMESG_ERR" | tail -15 | sed 's/^/  /'
    (( ERR_COUNT > 15 )) && info "...and $(( ERR_COUNT - 15 )) more (run 'sudo dmesg --level=err,crit -T' for full list)"
  else
    ok "No kernel error/critical messages since last boot"
  fi

  if [[ "$WARN_COUNT" -gt 0 ]]; then
    info "$WARN_COUNT kernel warning(s) present (informational — often benign ACPI/firmware notices)"
  fi
else
  skip "dmesg needs root — re-run with sudo for kernel log analysis"
fi

# ============================================================================
section "2. systemd Journal — Error-Priority Scan (current boot)"
# ============================================================================
if command -v journalctl &>/dev/null; then
  JOURNAL_ERRS=$(journalctl -b -p err..alert --no-pager 2>/dev/null)
  ERR_LINES=$(echo "$JOURNAL_ERRS" | grep -c . 2>/dev/null || echo 0)
  if [[ "$ERR_LINES" -gt 0 ]]; then
    warn "$ERR_LINES error-priority journal entries this boot (services can log errors while staying 'active')"
    echo "$JOURNAL_ERRS" | awk -F': ' '{print $NF}' | sort | uniq -c | sort -rn | head -10 | sed 's/^/  /'
    info "Above: most frequent distinct error messages this boot, with counts. Run 'journalctl -b -p err..alert' for full detail."
  else
    ok "No error-priority journal entries this boot"
  fi
else
  warn "journalctl not found — unexpected on Ubuntu"
fi

# ============================================================================
section "3. Package Integrity Verification (debsums)"
# ============================================================================
if ensure_tool debsums debsums "verify installed files against package checksums"; then
  info "Checking installed files against package checksums (read-only, may take a minute)..."
  DEBSUMS_OUT=$(debsums -c 2>/dev/null)
  CHANGED_COUNT=$(echo "$DEBSUMS_OUT" | grep -c . 2>/dev/null)
  CHANGED_COUNT=${CHANGED_COUNT:-0}
  if [[ "$CHANGED_COUNT" -eq 0 ]]; then
    ok "No modified files detected vs package checksums"
  else
    warn "$CHANGED_COUNT file(s) differ from their package checksum"
    echo "$DEBSUMS_OUT" | head -15 | sed 's/^/  /'
    info "Note: config files (/etc/*) commonly show here after legitimate edits — that's expected, not a compromise indicator by itself."
  fi
else
  skip "Skipping package integrity check"
fi

# ============================================================================
section "4. Broken / Orphaned / Half-Configured Packages"
# ============================================================================
subsection "dpkg audit"
DPKG_AUDIT=$(dpkg --audit 2>/dev/null)
if [[ -z "$DPKG_AUDIT" ]]; then
  ok "No broken or half-configured packages"
else
  bad "dpkg reports package issues:"
  echo "$DPKG_AUDIT" | sed 's/^/  /'
fi

subsection "Held packages"
HELD=$(apt-mark showhold 2>/dev/null)
if [[ -z "$HELD" ]]; then
  ok "No packages on hold"
else
  info "Packages on hold (won't receive updates):"
  echo "$HELD" | sed 's/^/  /'
fi

subsection "Orphaned packages (installed as dependency, no longer needed)"
if command -v deborphan &>/dev/null; then
  ORPHANS=$(deborphan 2>/dev/null)
  if [[ -z "$ORPHANS" ]]; then
    ok "No orphaned packages found"
  else
    ORPHAN_COUNT=$(echo "$ORPHANS" | grep -c .)
    info "$ORPHAN_COUNT potentially orphaned package(s) — review before removing, deborphan is heuristic and can false-positive:"
    echo "$ORPHANS" | sed 's/^/  /'
  fi
else
  read -r -p "  'deborphan' not found. Install via sudo apt install? Note: it may be unavailable in this release's repos. [y/N] " reply
  if [[ "$reply" =~ ^[yY]([eE][sS])?$ ]]; then
    if sudo apt-get update -qq && sudo apt-get install -y deborphan 2>/dev/null && command -v deborphan &>/dev/null; then
      ok "'deborphan' installed"
      ORPHANS=$(deborphan 2>/dev/null)
      if [[ -z "$ORPHANS" ]]; then
        ok "No orphaned packages found"
      else
        info "Potentially orphaned packages (review before removing):"
        echo "$ORPHANS" | sed 's/^/  /'
      fi
    else
      info "'deborphan' is not available in this release's repositories — this is not a system problem, just an unavailable optional tool. Skipping this check."
    fi
  else
    skip "Skipping orphaned-package check"
  fi
fi

# ============================================================================
section "5. Deep SMART Attributes"
# ============================================================================
if command -v smartctl &>/dev/null; then
  for disk in /dev/nvme0n1 /dev/sda /dev/vda; do
    [[ -b "$disk" ]] || continue
    if ! $IS_ROOT; then
      skip "$disk — full SMART attributes need root, re-run with sudo"
      continue
    fi
    subsection "$disk"
    if [[ "$disk" == *nvme* ]]; then
      SMART_LOG=$(smartctl -A "$disk" 2>/dev/null)
      echo "$SMART_LOG" | grep -Ei "critical_warning|temperature|available_spare|percentage_used|media_errors|error_information_log_entries|power_on_hours|power_cycles" | sed 's/^/  /'

      PCT_USED=$(echo "$SMART_LOG" | awk -F: '/Percentage Used/{gsub(/[^0-9]/,"",$2); print $2}')
      SPARE=$(echo "$SMART_LOG" | awk -F: '/Available Spare:/{gsub(/[^0-9]/,"",$2); print $2}')
      MEDIA_ERR=$(echo "$SMART_LOG" | awk -F: '/Media and Data Integrity Errors/{gsub(/[^0-9]/,"",$2); print $2}')

      [[ -n "$PCT_USED" ]] && {
        if (( PCT_USED >= 80 )); then bad "NVMe wear: ${PCT_USED}% of rated life used"
        elif (( PCT_USED >= 50 )); then warn "NVMe wear: ${PCT_USED}% of rated life used"
        else ok "NVMe wear: ${PCT_USED}% of rated life used"; fi
      }
      [[ -n "$SPARE" ]] && {
        if (( SPARE < 90 )); then warn "Available spare blocks: ${SPARE}% (below 90%)"
        else ok "Available spare blocks: ${SPARE}%"; fi
      }
      [[ -n "$MEDIA_ERR" && "$MEDIA_ERR" -gt 0 ]] && bad "Media/data integrity errors logged: $MEDIA_ERR"
    else
      SMART_LOG=$(smartctl -A "$disk" 2>/dev/null)
      echo "$SMART_LOG" | grep -Ei "Reallocated_Sector|Current_Pending_Sector|Offline_Uncorrectable|Power_On_Hours|Wear_Leveling" | sed 's/^/  /'
      REALLOC=$(echo "$SMART_LOG" | awk '/Reallocated_Sector/{print $NF}')
      PENDING=$(echo "$SMART_LOG" | awk '/Current_Pending_Sector/{print $NF}')
      [[ -n "$REALLOC" && "$REALLOC" -gt 0 ]] && warn "Reallocated sectors: $REALLOC (early wear indicator)"
      [[ -n "$PENDING" && "$PENDING" -gt 0 ]] && bad "Pending sectors: $PENDING (sectors awaiting reallocation — monitor closely)"
    fi
  done
else
  skip "smartctl not found — install via system-health-check.sh first, or: sudo apt install smartmontools"
fi

# ============================================================================
section "6. Boot Performance Breakdown"
# ============================================================================
if command -v systemd-analyze &>/dev/null; then
  BOOT_TIME=$(systemd-analyze 2>/dev/null | head -1)
  info "$BOOT_TIME"
  subsection "Slowest units to start (top 10)"
  systemd-analyze blame 2>/dev/null | head -10 | sed 's/^/  /'
else
  skip "systemd-analyze not found — unexpected on Ubuntu"
fi

# ============================================================================
section "7. Thermal Throttling History"
# ============================================================================
if $IS_ROOT; then
  THROTTLE_MSGS=$(dmesg -T 2>/dev/null | grep -Ei "thermal.*throttl|cpu.*throttl|reached tj.?max|clock.*throttl")
  if [[ -n "$THROTTLE_MSGS" ]]; then
    warn "Thermal throttling events found in kernel log:"
    echo "$THROTTLE_MSGS" | tail -10 | sed 's/^/  /'
  else
    ok "No thermal throttling events logged since last boot"
  fi
else
  skip "dmesg needs root — re-run with sudo to check throttle history"
fi

# ============================================================================
section "8. GPU / Display Driver Errors"
# ============================================================================
if $IS_ROOT; then
  GPU_ERRS=$(dmesg -T 2>/dev/null | grep -Ei "\[drm\].*error|i915.*error|gpu hang|gpu reset")
  if [[ -n "$GPU_ERRS" ]]; then
    warn "GPU/DRM error messages found in kernel log:"
    echo "$GPU_ERRS" | tail -10 | sed 's/^/  /'
  else
    ok "No GPU/DRM error messages since last boot"
  fi
else
  skip "dmesg needs root — re-run with sudo to check GPU driver log"
fi

# ============================================================================
section "9. Permission & Security Audit"
# ============================================================================
subsection "SUID/SGID binaries outside standard package locations"
info "Scanning common system paths for SUID/SGID binaries (read-only, may take ~30s)..."
SUID_FILES=$(find /usr/bin /usr/sbin /usr/local/bin /usr/local/sbin /bin /sbin \
  -xdev -type f \( -perm -4000 -o -perm -2000 \) 2>/dev/null)
SUID_COUNT=$(echo "$SUID_FILES" | grep -c . 2>/dev/null || echo 0)
info "$SUID_COUNT SUID/SGID binaries found in standard system paths (expected — sudo, su, mount, ping, etc. all need this)"
UNUSUAL_SUID=$(find /home /tmp /var/tmp -xdev -type f \( -perm -4000 -o -perm -2000 \) 2>/dev/null)
if [[ -n "$UNUSUAL_SUID" ]]; then
  bad "SUID/SGID binaries found in unusual locations (home/tmp) — review immediately:"
  echo "$UNUSUAL_SUID" | sed 's/^/  /'
else
  ok "No SUID/SGID binaries in /home, /tmp, or /var/tmp"
fi

subsection "World-writable files in sensitive system directories"
WW_FILES=$(find /etc /usr/bin /usr/sbin /bin /sbin -xdev -type f -perm -002 2>/dev/null)
if [[ -n "$WW_FILES" ]]; then
  warn "World-writable files found in system directories:"
  echo "$WW_FILES" | head -15 | sed 's/^/  /'
else
  ok "No world-writable files in /etc, /usr/bin, /usr/sbin, /bin, /sbin"
fi

subsection "Sudoers configuration"
if $IS_ROOT; then
  SUDOERS_CUSTOM=$(find /etc/sudoers.d -type f ! -name "README" 2>/dev/null)
  if [[ -n "$SUDOERS_CUSTOM" ]]; then
    info "Custom sudoers.d entries present:"
    echo "$SUDOERS_CUSTOM" | sed 's/^/  /'
  else
    ok "No custom sudoers.d entries beyond defaults"
  fi
else
  skip "sudoers.d needs root to read — re-run with sudo"
fi

# ============================================================================
section "10. Optional Rootkit / Malware Scan"
# ============================================================================
echo -e "  ${c_dim}This section is opt-in and can take several minutes. It only reads your"
echo -e "  filesystem and compares against known-signature databases — it does not"
echo -e "  modify anything, and this script will NOT run any 'update baseline'"
echo -e "  command that could overwrite the tool's reference state.${c_rst}"
echo
echo -e "  ${c_ylw}Heads up: installing rkhunter pulls in mail-sending dependencies"
echo -e "  (bsd-mailx), which on Ubuntu triggers apt to also install and START"
echo -e "  postfix (a local mail server) as a background service. It only binds"
echo -e "  to localhost by default, but it is a real running service you didn't"
echo -e "  explicitly ask for. You can remove it afterward with:"
echo -e "  sudo apt purge postfix bsd-mailx${c_rst}"
echo
if confirm "Run a rootkit/malware scan now (rkhunter)? This can take several minutes."; then
  if ! command -v rkhunter &>/dev/null; then
    echo
    echo -e "  ${c_ylw}'rkhunter' not found${c_rst} (needed to: scan for known rootkit signatures)"
    read -r -p "  Install package 'rkhunter' now via sudo apt install (using --no-install-recommends to avoid pulling in mail-server dependencies like postfix)? [y/N] " reply
    if [[ "$reply" =~ ^[yY]([eE][sS])?$ ]]; then
      sudo apt-get update -qq && sudo apt-get install -y --no-install-recommends rkhunter
    fi
  fi
  if command -v rkhunter &>/dev/null; then
    ok "'rkhunter' available"
    info "Running rkhunter (read-only check mode, no baseline updates)..."
    sudo rkhunter --check --sk --nocolors 2>/dev/null | grep -Ei "warning|not found|infected" | grep -vi "^none" | sed 's/^/  /'
    info "Full log at /var/log/rkhunter.log if you want to review details"
  else
    skip "rkhunter unavailable, skipping scan"
  fi
else
  skip "Rootkit scan skipped by choice"
fi

# ============================================================================
section "11. Summary"
# ============================================================================
echo
if [[ ${#ISSUES[@]} -eq 0 && ${#WARNINGS[@]} -eq 0 ]]; then
  echo -e "  ${c_grn}${c_bold}Deep scan found no issues or warnings.${c_rst}"
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
echo -e "${c_dim}Deep scan complete. This script made no changes to your system"
echo -e "(aside from any diagnostic tool installs you explicitly approved above).${c_rst}"
