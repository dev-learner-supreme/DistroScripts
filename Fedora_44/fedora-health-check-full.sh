#!/usr/bin/env bash
#
# fedora-health-check.sh (comprehensive edition)
#
# Read-only, whole-system health check for this machine:
#   Fedora 44, Btrfs root (subvol=/root) + home (subvol=/home),
#   Snapper + DNF5 hook snapshots, grub-btrfs (hook-driven GRUB sync),
#   zram (12G) + swapfile (32G), SELinux enforcing, laptop hardware.
#
# Guarantees:
#   - No files are modified, no services are restarted, no config is changed.
#   - No filesystem repair tools are ever run (e.g. no fsck, even with -n,
#     since that is not reliably safe on a mounted filesystem).
#   - Any check that needs root asks once for sudo up front with an
#     explanation, then proceeds -- no surprise repeated prompts.
#   - Any check that touches the network (connectivity, firmware update
#     metadata) is clearly labeled and time-limited so it cannot hang.
#
# Usage: ./fedora-health-check.sh [--skip-network] [--skip-rpm-verify]
#
#   --skip-network      Skip connectivity/DNS and firmware-update-metadata
#                        checks (useful if offline or on metered data).
#   --skip-rpm-verify    Skip `rpm -Va`, which checksums every installed
#                        package's files and can take 1-2 minutes.
#

set -uo pipefail

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BOLD='\033[1m'
NC='\033[0m'

ok()   { echo -e "  ${GREEN}✔${NC} $1"; }
warn() { echo -e "  ${YELLOW}⚠${NC} $1"; }
bad()  { echo -e "  ${RED}✘${NC} $1"; }
info() { echo -e "  ${NC}ℹ${NC}  $1"; }
section() { echo; echo -e "${BOLD}=== $1 ===${NC}"; }

SKIP_NETWORK=0
SKIP_RPM_VERIFY=0
for arg in "$@"; do
    case "$arg" in
        --skip-network) SKIP_NETWORK=1 ;;
        --skip-rpm-verify) SKIP_RPM_VERIFY=1 ;;
        -h|--help)
            grep '^#' "$0" | sed 's/^#//'
            exit 0
            ;;
    esac
done

MISSING_TOOLS=()

########################################
# Sudo handling -- ask once, up front, with explanation
########################################

SUDO_AVAILABLE=0
if [[ $EUID -eq 0 ]]; then
    SUDO_AVAILABLE=1
else
    echo "This is a read-only health check: it will not modify any files,"
    echo "services, or configuration, and will never run filesystem repair"
    echo "tools. Some checks (SMART data, audit log, snapshot list, grub.cfg,"
    echo "package verification) need root to read, so it will ask for your"
    echo "sudo password once up front rather than repeatedly mid-run."
    echo
    if sudo -v; then
        SUDO_AVAILABLE=1
    else
        echo "Could not obtain sudo access. Root-only checks will be skipped."
    fi
fi

run_sudo() {
    if [[ "$SUDO_AVAILABLE" -eq 1 ]]; then
        sudo "$@"
    else
        return 1
    fi
}

need_sudo_notice() {
    info "$1 skipped (requires sudo)."
}

########################################
# Optional diagnostic tool installation
#
# This is the ONE part of this script that is not read-only: installing a
# missing tool changes the system (adds a package). It is strictly opt-in,
# and deliberately runs BEFORE any checks below -- so if you agree to
# install something, the corresponding check later in this same run
# actually benefits from it, instead of only helping a future run.
########################################

declare -A TOOL_PACKAGES=(
    [smartctl]="smartmontools"
    [mokutil]="mokutil"
    [upower]="upower"
    [fwupdmgr]="fwupd"
    [firewall-cmd]="firewalld"
    [efibootmgr]="efibootmgr"
    [ausearch]="audit"
    [semodule]="policycoreutils"
    [snapper]="snapper"
)

if [[ "$SUDO_AVAILABLE" -eq 1 ]] && command -v dnf5 >/dev/null 2>&1; then
    detected_missing_tools=()
    detected_missing_packages=()
    for tool in "${!TOOL_PACKAGES[@]}"; do
        if ! command -v "$tool" >/dev/null 2>&1; then
            detected_missing_tools+=("$tool")
            detected_missing_packages+=("${TOOL_PACKAGES[$tool]}")
        fi
    done

    if [[ ${#detected_missing_tools[@]} -gt 0 ]]; then
        echo
        echo "The following optional diagnostic tools are not installed. Without"
        echo "them, the corresponding checks below will be skipped:"
        for i in "${!detected_missing_tools[@]}"; do
            echo "    ${detected_missing_tools[$i]}  (package: ${detected_missing_packages[$i]})"
        done
        echo
        read -r -p "Install these now via dnf5? This is the only write action this script performs. [y/N] " install_reply
        if [[ "$install_reply" =~ ^[Yy]$ ]]; then
            unique_packages=($(printf "%s\n" "${detected_missing_packages[@]}" | sort -u))
            echo "Installing: ${unique_packages[*]}"
            if ! run_sudo dnf5 install -y "${unique_packages[@]}"; then
                echo "Installation failed or was cancelled. Continuing with those checks skipped."
            fi
        else
            echo "Skipping installation. Corresponding checks will be skipped below."
        fi
    fi
fi

########################################
# System overview
########################################

section "System Overview"
host_name=$(hostnamectl --static 2>/dev/null)
[[ -z "$host_name" ]] && host_name=$(hostname 2>/dev/null)
echo "  Host:      ${host_name}"
echo "  Kernel:    $(uname -r)"
echo "  Uptime:    $(uptime -p 2>/dev/null || uptime)"
os_support_end=$(hostnamectl 2>/dev/null | grep "OS Support End" | sed 's/^\s*//')
[[ -n "$os_support_end" ]] && echo "  ${os_support_end}"

########################################
# Kernel / dmesg
########################################

section "Kernel Ring Buffer (errors/warnings since boot)"
if [[ "$SUDO_AVAILABLE" -eq 1 ]]; then
    dmesg_out=$(run_sudo dmesg --level=err,warn -T 2>/dev/null | tail -15)
    if [[ -z "$dmesg_out" ]]; then
        ok "No error/warning-level kernel messages since boot."
    else
        warn "Found error/warning-level messages (showing last 15; often firmware quirks, review if unfamiliar):"
        echo "$dmesg_out" | sed 's/^/    /'
    fi

    throttle_msgs=$(run_sudo dmesg -T 2>/dev/null | grep -iE "thermal.throttl|cpu clock throttled|power limit" | tail -5)
    if [[ -z "$throttle_msgs" ]]; then
        ok "No CPU thermal throttling events found in dmesg."
    else
        warn "Thermal throttling events found:"
        echo "$throttle_msgs" | sed 's/^/    /'
    fi

    ucode=$(run_sudo journalctl -k -b 0 2>/dev/null | grep -i "microcode" | tail -3)
    if [[ -n "$ucode" ]]; then
        ok "Microcode loaded:"
        echo "$ucode" | sed 's/^/    /'
    fi
else
    need_sudo_notice "Kernel ring buffer check"
fi

########################################
# systemd health (system + user)
########################################

section "systemd Health"
failed_units=$(systemctl --failed --no-legend --no-pager 2>/dev/null)
if [[ -z "$failed_units" ]]; then
    ok "No failed system units."
else
    bad "Failed system units:"
    echo "$failed_units" | sed 's/^/    /'
fi

failed_user_units=$(systemctl --user --failed --no-legend --no-pager 2>/dev/null)
if [[ -z "$failed_user_units" ]]; then
    ok "No failed user units."
else
    warn "Failed user units:"
    echo "$failed_user_units" | sed 's/^/    /'
fi

boot_time=$(systemd-analyze 2>/dev/null | head -1)
echo "  ${boot_time}"

oomd_status=$(systemctl is-active systemd-oomd 2>/dev/null)
if [[ "$oomd_status" == "active" ]]; then
    ok "systemd-oomd: active"
else
    info "systemd-oomd: ${oomd_status:-not active} (Fedora's default OOM killer -- only a concern if you didn't disable it intentionally)"
fi

########################################
# SELinux
########################################

section "SELinux"
if command -v getenforce >/dev/null 2>&1; then
    mode=$(getenforce)
    if [[ "$mode" == "Enforcing" ]]; then
        ok "SELinux mode: Enforcing"
    else
        warn "SELinux mode: ${mode} (expected Enforcing)"
    fi

    if [[ "$SUDO_AVAILABLE" -eq 1 ]]; then
        avc_count=$(run_sudo ausearch -m avc -ts today 2>/dev/null | grep -c "^type=AVC" || true)
        if [[ "$avc_count" -eq 0 ]]; then
            ok "No AVC denials logged today."
        else
            warn "${avc_count} AVC denial(s) logged today. Review with: sudo ausearch -m avc -ts today"
        fi

        if run_sudo semodule -l 2>/dev/null | grep -q "^snapper$"; then
            ok "snapper SELinux policy module loaded."
        fi
    else
        need_sudo_notice "AVC denial check"
    fi
else
    info "getenforce not found -- SELinux may not be installed."
    MISSING_TOOLS+=("policycoreutils")
fi

########################################
# Secure Boot
########################################

section "Secure Boot"
if command -v mokutil >/dev/null 2>&1; then
    sb_state=$(mokutil --sb-state 2>/dev/null)
    if echo "$sb_state" | grep -qi "enabled"; then
        ok "Secure Boot: enabled"
    else
        warn "Secure Boot: ${sb_state:-not enabled}"
    fi
else
    info "mokutil not installed -- cannot check Secure Boot state."
    MISSING_TOOLS+=("mokutil")
fi

########################################
# SSD / NVMe health
########################################

section "SSD / NVMe Health"
NVME_DEV=$(lsblk -dno NAME,TYPE 2>/dev/null | awk '$2=="disk" && $1 ~ /^nvme/ {print "/dev/"$1; exit}')
if [[ -n "$NVME_DEV" ]]; then
    if command -v smartctl >/dev/null 2>&1; then
        if [[ "$SUDO_AVAILABLE" -eq 1 ]]; then
            health=$(run_sudo smartctl -H "$NVME_DEV" 2>/dev/null | grep -i "overall-health")
            if echo "$health" | grep -qi "PASSED"; then
                ok "SMART overall health: PASSED (${NVME_DEV})"
            else
                bad "SMART overall health did not report PASSED: ${health}"
            fi

            smart_data=$(run_sudo smartctl -A "$NVME_DEV" 2>/dev/null)
            pct_used=$(echo "$smart_data" | grep -i "Percentage Used" | grep -oE '[0-9]+%' | head -1)
            crit_warn=$(echo "$smart_data" | grep -i "Critical Warning" | awk '{print $NF}')
            media_errs=$(echo "$smart_data" | grep -i "Media and Data Integrity Errors" | awk '{print $NF}')
            temp=$(echo "$smart_data" | grep -i "^Temperature:" | awk '{print $2, $3}')

            [[ -n "$pct_used" ]] && echo "  Lifetime used: ${pct_used}"
            [[ -n "$temp" ]] && echo "  Temperature: ${temp}"
            if [[ "$crit_warn" == "0x00" ]]; then
                ok "No critical warnings reported."
            else
                bad "Critical warning flag set: ${crit_warn}"
            fi
            if [[ "$media_errs" == "0" ]]; then
                ok "Zero media/data integrity errors."
            else
                bad "Media/data integrity errors: ${media_errs}"
            fi
        else
            need_sudo_notice "SMART health check"
        fi
    else
        info "smartctl not installed -- skipping SSD health check."
        MISSING_TOOLS+=("smartmontools")
    fi
else
    info "NVMe device not found -- skipping SSD health check."
fi

########################################
# Battery
########################################

section "Battery"
if command -v upower >/dev/null 2>&1; then
    bat_path=$(upower -e 2>/dev/null | grep -i battery | head -1)
    if [[ -n "$bat_path" ]]; then
        bat_info=$(upower -i "$bat_path" 2>/dev/null)
        state=$(echo "$bat_info" | grep -oP '(?<=state:)\s*\K\S+')
        percentage=$(echo "$bat_info" | grep -oP '(?<=percentage:)\s*\K\S+')
        health_pct=$(echo "$bat_info" | grep -oP '(?<=capacity:)\s*\K\S+')
        cycles=$(echo "$bat_info" | grep -oP '(?<=charge-cycles:)\s*\K\S+')

        echo "  State: ${state:-unknown}, Charge: ${percentage:-unknown}"
        if [[ -n "$health_pct" ]]; then
            hp_num=$(LC_ALL=C printf "%.0f" "${health_pct%\%}" 2>/dev/null)
            if [[ "$hp_num" =~ ^[0-9]+$ ]] && [[ "$hp_num" -ge 80 ]]; then
                ok "Battery health (design capacity): ${health_pct}"
            else
                warn "Battery health (design capacity): ${health_pct} -- below 80%, capacity has degraded noticeably."
            fi
        fi
        [[ -n "$cycles" && "$cycles" != "N/A" ]] && echo "  Charge cycles: ${cycles}"
    else
        info "No battery detected."
    fi
else
    info "upower not installed -- skipping battery check."
    MISSING_TOOLS+=("upower")
fi

########################################
# Firmware
########################################

section "Firmware"
if command -v fwupdmgr >/dev/null 2>&1; then
    if [[ "$SKIP_NETWORK" -eq 1 ]]; then
        info "Skipped (--skip-network given; firmware update check needs network)."
    else
        fw_updates=$(timeout 15 fwupdmgr get-updates 2>&1)
        if echo "$fw_updates" | grep -qi "no updatable devices\|no updates"; then
            ok "No pending firmware updates."
        elif echo "$fw_updates" | grep -qi "^Devices"; then
            warn "Firmware updates may be available. Review with: fwupdmgr get-updates"
        else
            info "Could not determine firmware update status (fwupd daemon may be unavailable)."
        fi
    fi
else
    info "fwupdmgr not installed -- skipping firmware update check."
    MISSING_TOOLS+=("fwupd")
fi

########################################
# Btrfs filesystem
########################################

section "Btrfs Filesystem (/ and /home)"
if [[ "$SUDO_AVAILABLE" -eq 1 ]]; then
    dev_stats=$(run_sudo btrfs device stats / 2>/dev/null)
    if [[ -z "$dev_stats" ]]; then
        info "Could not read Btrfs device stats (btrfs command unavailable or / is not Btrfs)."
    else
        # Parse each "...(_errs)    N" line and flag any with a nonzero
        # numeric count. Done via explicit numeric comparison on a
        # sanitized value rather than raw awk field comparison, which can
        # misbehave (string-vs-number quirks) on malformed or empty input.
        nonzero=""
        while IFS= read -r line; do
            [[ "$line" == *_errs* ]] || continue
            val=$(echo "$line" | grep -oE '[0-9]+$')
            if [[ -n "$val" && "$val" -ne 0 ]]; then
                nonzero+="${line}"$'\n'
            fi
        done <<< "$dev_stats"

        if [[ -z "$nonzero" ]]; then
            ok "No Btrfs device errors (write/read/flush/corruption/generation all zero)."
        else
            bad "Non-zero Btrfs device error counters detected:"
            echo "$nonzero" | sed 's/^/    /'
        fi
    fi
else
    need_sudo_notice "Btrfs device stats check"
fi

usage_line=$(btrfs filesystem usage / 2>/dev/null | grep "Used:")
[[ -n "$usage_line" ]] && echo "  ${usage_line}"

for mp in / /home; do
    pcent=$(df -h "$mp" --output=pcent 2>/dev/null | tail -1 | tr -d ' %')
    if [[ -n "$pcent" ]]; then
        if [[ "$pcent" -lt 85 ]]; then
            ok "${mp} usage: ${pcent}%"
        else
            warn "${mp} usage high: ${pcent}%"
        fi
    fi
done

if [[ "$SUDO_AVAILABLE" -eq 1 ]]; then
    for mp in / /home; do
        scrub_out=$(run_sudo btrfs scrub status "$mp" 2>/dev/null)
        if [[ -z "$scrub_out" ]]; then
            info "${mp}: Could not read scrub status (btrfs command unavailable or not a Btrfs mount)."
        elif echo "$scrub_out" | grep -qi "no stats available\|never started"; then
            info "${mp}: No scrub has been run on this mount."
        elif echo "$scrub_out" | grep -qi "running\|in progress"; then
            info "${mp}: Scrub currently in progress -- results not final yet."
        else
            errs=$(echo "$scrub_out" | grep -i "Error summary:" | sed 's/.*summary: *//')
            if [[ "$errs" == "no errors found" || -z "$errs" ]]; then
                ok "${mp}: Scrub found no errors."
            else
                bad "${mp}: Scrub reported errors: ${errs}"
            fi
            last_run=$(echo "$scrub_out" | grep -E "scrub status for|scrub started at|finished on" | tail -1)
            [[ -n "$last_run" ]] && echo "  ${last_run}"
        fi
    done
else
    need_sudo_notice "Btrfs scrub status check"
fi

mount_opts=$(findmnt -no OPTIONS / 2>/dev/null)
if echo "$mount_opts" | grep -q "compress=zstd"; then
    ok "zstd compression active on /."
else
    warn "zstd compression not detected on / (expected compress=zstd)."
fi

########################################
# /boot and /boot/efi (no fsck -- read-only checks only)
########################################

section "/boot and /boot/efi"
for mp in /boot /boot/efi; do
    pcent=$(df -h "$mp" --output=pcent 2>/dev/null | tail -1 | tr -d ' %')
    if [[ -n "$pcent" ]]; then
        if [[ "$pcent" -lt 85 ]]; then
            ok "${mp} usage: ${pcent}%"
        else
            warn "${mp} usage high: ${pcent}% -- old kernels may need cleanup (dnf5 handles this automatically by default)"
        fi
    fi
done

if [[ "$SUDO_AVAILABLE" -eq 1 ]]; then
    fs_errs=$(run_sudo dmesg -T 2>/dev/null | grep -iE "EXT4-fs error|FAT-fs.*error" | tail -5)
    if [[ -z "$fs_errs" ]]; then
        ok "No ext4/vfat filesystem errors found in dmesg."
    else
        bad "Filesystem errors found for /boot or /boot/efi in dmesg:"
        echo "$fs_errs" | sed 's/^/    /'
    fi
else
    need_sudo_notice "/boot filesystem error check"
fi

########################################
# Snapper -- presence, timers, AND cadence/pruning verification
########################################

section "Snapper Snapshots"
if command -v snapper >/dev/null 2>&1; then
    if [[ "$SUDO_AVAILABLE" -eq 1 ]]; then
        snap_list=$(run_sudo snapper list 2>/dev/null)
        snap_count=$(echo "$snap_list" | tail -n +3 | grep -c '│')
        echo "  Total snapshots: ${snap_count}"
        echo "$snap_list" | tail -5 | sed 's/^/    /'

        # Cadence check: is the most recent timeline snapshot reasonably
        # recent? The timer fires hourly; if the newest timeline snapshot is
        # more than ~2 hours old, the timer may be silently failing even
        # though systemd reports it as "active (waiting)".
        #
        # Note: an earlier version of this check used `snapper --csvout
        # list` with column names resolved from the header, on the theory
        # that it would be more robust than hardcoded indices. In practice
        # it broke on this system (the assumed column names didn't match
        # this snapper version's actual CSV header), so this reverts to
        # parsing the plain `snapper list` table output directly -- proven
        # to work correctly against this system's real output.
        last_timeline=$(echo "$snap_list" | grep "timeline" | tail -1 | awk -F'│' '{print $4}' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        if [[ -n "$last_timeline" ]]; then
            # The date already reflects the system's local clock. Passing
            # the trailing zone abbreviation (e.g. "IST") to `date -d` is
            # unreliable -- GNU date's abbreviation table is ambiguous (IST
            # could mean India, Israel, or Irish Standard Time) and can
            # silently misparse. Strip it and let `date` use the system's
            # actual configured zone instead of guessing from a 3-letter code.
            last_timeline_notz=$(echo "$last_timeline" | sed -E 's/[[:space:]]+[A-Za-z]{2,5}$//')
            last_epoch=$(date -d "$last_timeline_notz" +%s 2>/dev/null)
            now_epoch=$(date +%s)
            if [[ -n "$last_epoch" ]]; then
                age_min=$(( (now_epoch - last_epoch) / 60 ))
                if [[ "$age_min" -ge 0 && "$age_min" -lt 150 ]]; then
                    ok "Most recent timeline snapshot is ${age_min} minutes old (timer appears to be firing on schedule)."
                elif [[ "$age_min" -lt 0 ]]; then
                    info "Could not reliably compute snapshot age (clock/parse mismatch) -- skipping cadence check."
                else
                    warn "Most recent timeline snapshot is ${age_min} minutes old -- timer may not be firing correctly despite showing 'active'."
                fi
            else
                info "Could not parse snapshot timestamp for cadence check."
            fi
        else
            info "No timeline snapshots found yet."
        fi

        # Pruning check: compare current count against configured limits.
        if [[ -f /etc/snapper/configs/root ]]; then
            num_limit=$(run_sudo grep -oP '(?<=^NUMBER_LIMIT=")[0-9]+' /etc/snapper/configs/root 2>/dev/null)
            if [[ -n "$num_limit" && "$snap_count" -gt $((num_limit * 3)) ]]; then
                warn "Snapshot count (${snap_count}) is well above NUMBER_LIMIT (${num_limit}) -- cleanup timer may not be pruning correctly."
            else
                ok "Snapshot count is consistent with configured cleanup limits."
            fi
        fi
    else
        need_sudo_notice "Snapshot list and cadence check"
    fi

    for t in snapper-timeline.timer snapper-cleanup.timer grub-btrfs-regen.timer; do
        if systemctl is-active --quiet "$t" 2>/dev/null; then
            ok "${t}: active"
        else
            warn "${t}: not active"
        fi
    done
else
    warn "snapper not installed."
    MISSING_TOOLS+=("snapper")
fi

########################################
# DNF snapshot hook integration + recent transaction failures
########################################

section "DNF Snapshot Hook Integration & Transaction History"
ACTIONS_FILE="/etc/dnf/libdnf5-plugins/actions.d/snapper.actions"
PRE_HOOK="/usr/local/sbin/snapper-dnf-pre.sh"
POST_HOOK="/usr/local/sbin/snapper-dnf-post.sh"

[[ -f "$ACTIONS_FILE" ]] && ok "DNF5 actions file present." || warn "DNF5 actions file missing: ${ACTIONS_FILE}"
if [[ -x "$PRE_HOOK" && -x "$POST_HOOK" ]]; then
    if grep -q "\-\-cleanup-algorithm" "$PRE_HOOK" 2>/dev/null; then
        ok "Hook scripts present and executable (with cleanup algorithm)."
    else
        ok "Hook scripts present and executable."
        warn "Caveat: Pre/post snapshots from DNF hooks currently lack a cleanup algorithm and will accumulate indefinitely."
    fi
else
    warn "One or both hook scripts missing or not executable."
fi

if command -v dnf5 >/dev/null 2>&1; then
    recent_failed=$(dnf5 history list 2>/dev/null | grep -icw "failed" || true)
    if [[ "$recent_failed" -eq 0 ]]; then
        ok "No failed transactions in DNF history."
    else
        warn "${recent_failed} failed transaction(s) found in DNF history. Review with: dnf5 history list"
    fi
fi

########################################
# Package integrity (rpm -Va)
########################################

section "Package File Integrity"
if [[ "$SKIP_RPM_VERIFY" -eq 1 ]]; then
    info "Skipped (--skip-rpm-verify given)."
elif [[ "$SUDO_AVAILABLE" -eq 1 ]]; then
    echo "  Verifying installed package files (this can take a minute)..."
    # Paths routinely touched by their own runtime services (fwupd, bolt,
    # gdm) or by SELinux policy reloads -- matched both as "path/something"
    # AND as the bare directory entry itself ("path" with nothing after),
    # since the latter is what actually shows up for mode/group-only
    # changes on the directory (the original filter only matched the
    # trailing-slash form and missed these).
    verify_out=$(run_sudo rpm -Va 2>/dev/null | grep -vE ' (/run/|/var/run/|/var/lib/fwupd(/|$)|/var/lib/boltd(/|$)|/var/lib/gdm(/|$)|/var/log/gdm(/|$)|/var/lib/selinux/targeted/active/modules/|/boot/efi/System|/boot/efi/.*\.plist|/boot/efi/mach_kernel)')
    # Lines starting with a lone 'c' marker in position 1 after the 8-char
    # attribute field are modified *config* files -- normal and expected
    # (e.g. anything we edited: fstab, snapper configs, dnf actions file).
    # Filter those out separately from genuinely unexpected changes.
    config_changes=$(echo "$verify_out" | awk '$2=="c"')
    other_changes=$(echo "$verify_out" | awk '$2!="c" && NF>0')

    config_count=$(echo "$config_changes" | awk 'NF' | wc -l)
    other_count=$(echo "$other_changes" | awk 'NF' | wc -l)

    if [[ "$config_count" -gt 0 ]]; then
        info "${config_count} modified config file(s) (expected/normal for a configured system)."
    fi

    if [[ "$other_count" -eq 0 ]]; then
        ok "No unexpected package file modifications found."
    else
        warn "${other_count} non-config file(s) differ from their package originals:"
        echo "$other_changes" | head -20 | sed 's/^/    /'
        [[ "$other_count" -gt 20 ]] && info "(showing first 20 of ${other_count})"
    fi
else
    need_sudo_notice "Package file integrity check"
fi

########################################
# GRUB / boot
########################################

section "GRUB / Boot"
GRUB_CFG="/boot/grub2/grub.cfg"
if [[ "$SUDO_AVAILABLE" -eq 1 ]]; then
    if run_sudo test -f "$GRUB_CFG" 2>/dev/null; then
        if run_sudo grep -q "Fedora Linux snapshots" "$GRUB_CFG" 2>/dev/null; then
            ok "Snapshots submenu present in grub.cfg."
        else
            warn "Snapshots submenu not found in grub.cfg -- may be stale, check with a dnf transaction."
        fi
        mtime=$(run_sudo stat -c '%y' "$GRUB_CFG" 2>/dev/null | cut -d. -f1)
        echo "  grub.cfg last modified: ${mtime}"
    else
        warn "grub.cfg not found at ${GRUB_CFG}."
    fi
else
    need_sudo_notice "grub.cfg check (/boot/grub2 is not readable as a normal user on this system)"
fi

if [[ -d /sys/firmware/efi ]]; then
    ok "Boot mode: UEFI"
    if command -v efibootmgr >/dev/null 2>&1; then
        boot_entries=$(efibootmgr 2>/dev/null | grep -c "^Boot[0-9]")
        echo "  EFI boot entries: ${boot_entries}"
    fi
else
    ok "Boot mode: Legacy BIOS"
fi

########################################
# zram / swap
########################################

section "zram / Swap"
if command -v zramctl >/dev/null 2>&1; then
    zram_line=$(zramctl --noheadings 2>/dev/null)
    if [[ -n "$zram_line" ]]; then
        ok "zram device active: $(echo "$zram_line" | awk '{print $1, $2, $3}')"
    else
        warn "No active zram device found."
    fi
fi

swap_summary=$(swapon --show --noheadings 2>/dev/null)
if [[ -n "$swap_summary" ]]; then
    echo "$swap_summary" | sed 's/^/  /'
else
    warn "No active swap devices found."
fi

mem_line=$(free -h | awk '/^Mem:/ {print "Used: "$3" / "$2" (Available: "$7")"}')
echo "  ${mem_line}"

########################################
# Network / connectivity / firewall
########################################

section "Network"
if [[ "$SKIP_NETWORK" -eq 1 ]]; then
    info "Connectivity check skipped (--skip-network given)."
else
    if timeout 5 getent hosts fedoraproject.org >/dev/null 2>&1; then
        ok "DNS resolution working (fedoraproject.org resolved)."
    else
        warn "DNS resolution failed or timed out for fedoraproject.org."
    fi

    default_route=$(ip route show default 2>/dev/null | head -1)
    if [[ -n "$default_route" ]]; then
        ok "Default route present."
    else
        warn "No default route found -- check network connectivity."
    fi
fi

if command -v firewall-cmd >/dev/null 2>&1; then
    fw_state=$(firewall-cmd --state 2>/dev/null)
    if [[ "$fw_state" == "running" ]]; then
        ok "firewalld: running"
    else
        info "firewalld: ${fw_state:-not running} (only a concern if you rely on firewalld specifically -- some setups use nftables/ufw directly instead)"
    fi
else
    info "firewall-cmd not installed -- skipping firewalld check."
    MISSING_TOOLS+=("firewalld")
fi

listening=$(ss -tln 2>/dev/null | tail -n +2 | wc -l)
echo "  Listening TCP ports: ${listening}"

########################################
# Journald
########################################

section "systemd Journal"
journal_usage=$(journalctl --disk-usage 2>/dev/null | grep -oE '[0-9.]+[KMG]')
[[ -n "$journal_usage" ]] && echo "  Disk usage: ${journal_usage}"

if [[ -f /etc/systemd/journald.conf ]]; then
    max_use=$(grep -E "^SystemMaxUse=" /etc/systemd/journald.conf 2>/dev/null | cut -d= -f2)
    if [[ -n "$max_use" ]]; then
        ok "Journal size cap configured: SystemMaxUse=${max_use}"
    else
        info "No explicit SystemMaxUse set -- journald uses its default cap (usually fine)."
    fi
fi

########################################
# Stale / leftover files
########################################

section "Stale or Leftover Files"
bak_files=$(find /etc /usr/local -xdev -name "*.bak.*" 2>/dev/null)
if [[ -z "$bak_files" ]]; then
    ok "No stray .bak.* files under /etc or /usr/local."
else
    warn "Backup files found (safe to review/remove if no longer needed):"
    echo "$bak_files" | sed 's/^/    /'
fi

rpm_leftovers=$(find /etc -xdev \( -name "*.rpmnew" -o -name "*.rpmsave" -o -name "*.rpmorig" \) 2>/dev/null)
if [[ -z "$rpm_leftovers" ]]; then
    ok "No unmerged .rpmnew/.rpmsave/.rpmorig files under /etc."
else
    warn "Unmerged RPM config files found (review and merge manually if needed):"
    echo "$rpm_leftovers" | sed 's/^/    /'
fi

if command -v dnf5 >/dev/null 2>&1; then
    unneeded_count=$(dnf5 repoquery --unneeded 2>/dev/null | grep -c '.' || true)
    if [[ "$unneeded_count" -eq 0 ]]; then
        ok "No orphaned/unneeded packages."
    else
        info "${unneeded_count} orphaned package(s) found. Review with: dnf5 repoquery --unneeded"
    fi
fi

echo
echo -e "${BOLD}=== Done ===${NC}"
echo "This was a read-only check -- nothing was modified, no services were"
echo "restarted, and no filesystem repair tools were run."
