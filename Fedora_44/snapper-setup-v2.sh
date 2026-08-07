#!/usr/bin/env bash
#
# Fedora / Fedora-family - Snapper + DNF5 Snapshot Plugin + Btrfs Assistant Setup
# v2 - Hardened after live testing on Fedora 44
#
# Changelog from v1:
#   - Fixed COPR availability check: v1 ran `repoquery` for grub-btrfs BEFORE
#     the COPR was enabled, which always fails, forcing the confirm/enable
#     path every run. Now we enable the COPR first (idempotently) and verify
#     the enable actually succeeded before queueing the package, instead of
#     swallowing the exit code with `|| true` and queueing regardless.
#   - Replaced the inline `sh -c '...'` one-liners in the DNF5 actions file
#     with small standalone scripts under /usr/local/sbin. The DNF5 actions
#     plugin does naive whitespace tokenization of the action line, not real
#     shell parsing -- any embedded quotes or a second `-c`-looking token
#     (e.g. `snapper -c root`) breaks it with "unexpected EOF" errors. Script
#     files sidestep this: the actions file just contains a bare path plus one
#     unquoted variable substitution.
#   - Command capture now reads /proc/$PPID/cmdline (null-byte separated, no
#     shell-quoting involved at all) instead of `ps -o command`, which was the
#     original source of the quoting collision.
#   - grub-btrfs.path is NOT relied upon. On Fedora's default `subvol=/root`
#     layout (no separate .snapshots mount), the unit's auto-derived
#     `.snapshots.mount` dependency does not exist and the unit fails to
#     start. We install grub-btrfs but drive GRUB regeneration from the DNF5
#     post_transaction hook instead, which works regardless of subvolume
#     layout and needs no special mount unit.
#   - Added an optional daily systemd timer to regenerate GRUB independent of
#     DNF activity, so hourly timeline snapshots also become bootable rather
#     than only DNF-transaction snapshots (v1 gap: timeline snapshots existed
#     in Snapper but never appeared in the GRUB menu until the next dnf run).
#   - --verify now checks actual evidence of a working GRUB sync (hook script
#     presence + grub.cfg contents) rather than just grub-btrfs.path status,
#     which is expected to be inactive by design in this setup.
#
# References:
#   - Snapper Documentation: https://en.opensuse.org/Portal:Snapper
#   - Fedora Btrfs / Snapper guide: https://fedoraproject.org/wiki/Changes/BtrfsByDefault
#   - DNF5 Actions Plugin: https://dnf5.readthedocs.io/
#   - Btrfs Assistant: https://gitlab.com/btrfs-assistant/btrfs-assistant
#   - grub-btrfs COPR: https://copr.fedorainfracloud.org/coprs/kylegospo/grub-btrfs/
#

set -euo pipefail

########################################
# Configuration
########################################

CONFIG_NAME="root"
SUBVOLUME_PATH="/"

ALLOW_USERS="${ALLOW_USERS:-}"
ALLOW_GROUPS="${ALLOW_GROUPS:-wheel}"

ENABLE_TIMELINE="${ENABLE_TIMELINE:-yes}"
ENABLE_CLEANUP="${ENABLE_CLEANUP:-yes}"

NUMBER_LIMIT="${NUMBER_LIMIT:-10}"
NUMBER_LIMIT_IMPORTANT="${NUMBER_LIMIT_IMPORTANT:-10}"

TIMELINE_LIMIT_HOURLY="${TIMELINE_LIMIT_HOURLY:-5}"
TIMELINE_LIMIT_DAILY="${TIMELINE_LIMIT_DAILY:-7}"
TIMELINE_LIMIT_WEEKLY="${TIMELINE_LIMIT_WEEKLY:-4}"
TIMELINE_LIMIT_MONTHLY="${TIMELINE_LIMIT_MONTHLY:-3}"
TIMELINE_LIMIT_YEARLY="${TIMELINE_LIMIT_YEARLY:-0}"

INSTALL_GRUB_BTRFS="${INSTALL_GRUB_BTRFS:-1}"
ENABLE_DAILY_GRUB_REGEN="${ENABLE_DAILY_GRUB_REGEN:-1}"
ASSUME_YES="${ASSUME_YES:-0}"

HOOK_PRE_SCRIPT="/usr/local/sbin/snapper-dnf-pre.sh"
HOOK_POST_SCRIPT="/usr/local/sbin/snapper-dnf-post.sh"
DNF5_ACTIONS_FILE="/etc/dnf/libdnf5-plugins/actions.d/snapper.actions"

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

set_snapper_config_var() {
    local key="$1"
    local val="$2"
    local file="$3"

    if grep -q "^${key}=" "$file" 2>/dev/null; then
        sed -i "s|^${key}=.*|${key}=\"${val}\"|" "$file"
    else
        echo "${key}=\"${val}\"" >> "$file"
    fi
}

confirm_action() {
    local prompt_msg="$1"
    if [[ "$ASSUME_YES" -eq 1 ]]; then
        return 0
    fi
    if [[ ! -t 0 ]]; then
        return 0
    fi

    local response
    read -r -p "${prompt_msg} [Y/n] " response
    case "$response" in
        [nN][oO]|[nN])
            return 1
            ;;
        *)
            return 0
            ;;
    esac
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

    if [[ "$FS_TYPE" != "btrfs" ]]; then
        echo "ERROR: Unsupported root filesystem '${FS_TYPE}'."
        echo "Snapper Btrfs setup requires a Btrfs root filesystem."
        exit 1
    fi

    if ! command -v btrfs >/dev/null 2>&1; then
        pkg_install btrfs-progs
    fi

    if ! btrfs subvolume show / &>/dev/null; then
        echo "ERROR: Root directory '/' is mounted on Btrfs, but 'btrfs subvolume show /' failed."
        echo "Root '/' must be a valid Btrfs subvolume to configure Snapper snapshots."
        echo "Aborting setup to protect custom or non-subvolume installations."
        exit 1
    fi

    # Detect whether root uses a nested subvolume layout (e.g. subvol=/root),
    # in which case /.snapshots will also be nested and grub-btrfs.path's
    # auto-derived mount dependency will not exist. This informs later steps.
    ROOT_SUBVOL_OPT=$(findmnt -no OPTIONS / | tr ',' '\n' | grep '^subvol=' || true)
    if [[ -n "$ROOT_SUBVOL_OPT" && "$ROOT_SUBVOL_OPT" != "subvol=/" ]]; then
        NESTED_SUBVOL_LAYOUT=1
    else
        NESTED_SUBVOL_LAYOUT=0
    fi
}

########################################
# Dependency installation
########################################

install_dependencies() {

    local packages=()

    if ! pkg_installed snapper; then
        packages+=(snapper)
    fi

    if ! pkg_installed btrfs-assistant; then
        packages+=(btrfs-assistant)
    fi

    if [[ "$PKG_MANAGER" == "dnf5" ]]; then
        if ! pkg_installed libdnf5-plugin-snapper && ! pkg_installed libdnf5-plugin-actions; then
            packages+=(libdnf5-plugin-actions)
        fi
    else
        if ! pkg_installed python3-dnf-plugin-snapper && ! pkg_installed dnf-plugin-snapper; then
            packages+=(python3-dnf-plugin-snapper)
        fi
    fi

    GRUB_BTRFS_AVAILABLE=0
    if [[ "${INSTALL_GRUB_BTRFS}" == "1" ]]; then
        if pkg_installed grub-btrfs || pkg_installed grub-btrfs-snapper; then
            GRUB_BTRFS_AVAILABLE=1
        else
            # v1 bug: this repoquery ran BEFORE the COPR was enabled, so it
            # always failed and forced the enable path on every run. Now we
            # just enable the COPR directly (idempotent; dnf5 no-ops if
            # already enabled) and check the actual exit status.
            if confirm_action "About to enable COPR repository 'kylegospo/grub-btrfs' for grub-btrfs. Continue?"; then
                echo "Enabling COPR kylegospo/grub-btrfs..."
                local copr_enable_ok=1
                if command -v dnf5 >/dev/null 2>&1; then
                    dnf5 copr enable -y kylegospo/grub-btrfs || copr_enable_ok=0
                else
                    dnf copr enable -y kylegospo/grub-btrfs || copr_enable_ok=0
                fi

                if [[ "$copr_enable_ok" -eq 1 ]]; then
                    packages+=(grub-btrfs)
                    GRUB_BTRFS_AVAILABLE=1
                else
                    echo "WARNING: Failed to enable kylegospo/grub-btrfs COPR."
                    echo "Skipping grub-btrfs installation. GRUB snapshot menu will not be configured."
                    INSTALL_GRUB_BTRFS=0
                fi
            else
                echo "Skipping COPR enablement and grub-btrfs installation."
                INSTALL_GRUB_BTRFS=0
            fi
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
# Snapper configuration
########################################

configure_snapper() {

    local snapper_conf="/etc/snapper/configs/${CONFIG_NAME}"

    if [[ ! -f "$snapper_conf" ]]; then
        echo "Creating Snapper configuration for root ('/')..."
        if [[ -d "/.snapshots" ]] && ! btrfs subvolume show /.snapshots &>/dev/null; then
            echo "Notice: /.snapshots exists as a standard directory. Removing it so Snapper can create the subvolume..."
            rmdir /.snapshots 2>/dev/null || rm -rf /.snapshots
        fi

        snapper -c "${CONFIG_NAME}" create-config "${SUBVOLUME_PATH}"
    else
        echo "Snapper configuration '${snapper_conf}' already exists."
    fi

    backup "$snapper_conf"

    echo "Updating Snapper root configuration settings..."
    set_snapper_config_var "ALLOW_GROUPS" "${ALLOW_GROUPS}" "$snapper_conf"
    if [[ -n "${ALLOW_USERS}" ]]; then
        set_snapper_config_var "ALLOW_USERS" "${ALLOW_USERS}" "$snapper_conf"
    fi

    set_snapper_config_var "TIMELINE_CREATE" "${ENABLE_TIMELINE}" "$snapper_conf"
    set_snapper_config_var "TIMELINE_CLEANUP" "${ENABLE_CLEANUP}" "$snapper_conf"
    set_snapper_config_var "NUMBER_CLEANUP" "${ENABLE_CLEANUP}" "$snapper_conf"

    set_snapper_config_var "NUMBER_LIMIT" "${NUMBER_LIMIT}" "$snapper_conf"
    set_snapper_config_var "NUMBER_LIMIT_IMPORTANT" "${NUMBER_LIMIT_IMPORTANT}" "$snapper_conf"

    set_snapper_config_var "TIMELINE_LIMIT_HOURLY" "${TIMELINE_LIMIT_HOURLY}" "$snapper_conf"
    set_snapper_config_var "TIMELINE_LIMIT_DAILY" "${TIMELINE_LIMIT_DAILY}" "$snapper_conf"
    set_snapper_config_var "TIMELINE_LIMIT_WEEKLY" "${TIMELINE_LIMIT_WEEKLY}" "$snapper_conf"
    set_snapper_config_var "TIMELINE_LIMIT_MONTHLY" "${TIMELINE_LIMIT_MONTHLY}" "$snapper_conf"
    set_snapper_config_var "TIMELINE_LIMIT_YEARLY" "${TIMELINE_LIMIT_YEARLY}" "$snapper_conf"

    if [[ -d "/.snapshots" ]]; then
        chmod 750 /.snapshots || true
        chown root:wheel /.snapshots 2>/dev/null || true

        if command -v getenforce >/dev/null 2>&1; then
            if [[ "$(getenforce)" != "Disabled" ]]; then
                echo "SELinux active; restoring security context on /.snapshots..."
                # Non-recursive by design. On a fresh /.snapshots this is
                # sufficient. On re-runs where prior snapshots already exist,
                # a recursive relabel walks INTO every old snapshot's nested
                # read-only subvolume tree (Btrfs nested subvolumes are
                # transparent to find/restorecon) and fails on every single
                # file with "Read-only file system" -- often thousands of
                # noisy, meaningless errors. Those old snapshot trees were
                # already correctly labeled when they were live and are
                # read-only now, so there is nothing useful to relabel there.
                restorecon -F /.snapshots || echo "Warning: restorecon on /.snapshots returned non-zero status."
            fi
        fi
    fi
}

########################################
# DNF hook scripts (replaces v1's inline sh -c one-liners)
########################################

install_hook_scripts() {

    echo "Installing Snapper DNF hook scripts to /usr/local/sbin..."

    backup "$HOOK_PRE_SCRIPT"
    cat > "$HOOK_PRE_SCRIPT" <<'EOF'
#!/usr/bin/env bash
# Managed by snapper-setup.sh v2 -- hand edits will be overwritten on re-run.
#
# Creates a pre-transaction Snapper snapshot and reports its number back to
# the DNF5 actions plugin via the tmp.snapper_pre_number variable.
#
# The transaction's command line is read from /proc/$PPID/cmdline, which is
# null-byte separated and involves no shell quoting at all -- this avoids the
# "unexpected EOF" failures caused by re-embedding `ps` output (which can
# contain spaces, quotes, and flag-like tokens such as a second `-c`) into a
# nested `sh -c '...'` string.
set -euo pipefail

cmdline=""
if [[ -r "/proc/$PPID/cmdline" ]]; then
    cmdline=$(tr '\0' ' ' < "/proc/$PPID/cmdline" 2>/dev/null | sed 's/ *$//')
    if [[ ${#cmdline} -gt 75 ]]; then
        cmdline="${cmdline:0:72}..."
    fi
fi
[[ -z "$cmdline" ]] && cmdline="dnf5 transaction"

num=$(snapper -c root create -t pre -p -d "$cmdline" --cleanup-algorithm number 2>/dev/null || echo "")
echo "tmp.snapper_pre_number=${num}"
EOF
    chmod 755 "$HOOK_PRE_SCRIPT"

    backup "$HOOK_POST_SCRIPT"
    cat > "$HOOK_POST_SCRIPT" <<'EOF'
#!/usr/bin/env bash
# Managed by snapper-setup.sh v2 -- hand edits will be overwritten on re-run.
#
# Creates a post-transaction Snapper snapshot linked to the pre-transaction
# snapshot number (passed as $1), then regenerates the GRUB config so the
# new snapshot pair appears in the "Fedora Linux snapshots" boot menu.
#
# grub-btrfs.path is intentionally NOT used to trigger this: on Fedora's
# default subvol=/root layout, that unit's auto-derived .snapshots.mount
# dependency does not exist and the unit fails to start. Driving the regen
# from this hook works regardless of subvolume layout.
set -uo pipefail

pre_num="${1:-}"
cmdline=""
if [[ -r "/proc/$PPID/cmdline" ]]; then
    cmdline=$(tr '\0' ' ' < "/proc/$PPID/cmdline" 2>/dev/null | sed 's/ *$//')
    if [[ ${#cmdline} -gt 75 ]]; then
        cmdline="${cmdline:0:72}..."
    fi
fi
[[ -z "$cmdline" ]] && cmdline="dnf5 transaction"

if [[ -n "$pre_num" ]]; then
    snapper -c root create -t post --pre-number "$pre_num" -d "$cmdline" --cleanup-algorithm number 2>/dev/null || true
fi

if command -v grub2-mkconfig >/dev/null 2>&1; then
    grub2-mkconfig -o /boot/grub2/grub.cfg >/dev/null 2>&1 || true
fi

exit 0
EOF
    chmod 755 "$HOOK_POST_SCRIPT"
}

configure_dnf_plugin() {

    if [[ "$PKG_MANAGER" == "dnf5" ]]; then
        if pkg_installed libdnf5-plugin-snapper; then
            echo "Native libdnf5-plugin-snapper package detected. Using native C++ DNF5 plugin."
            return 0
        fi

        install_hook_scripts

        echo "Configuring DNF5 pre/post snapshot action plugin..."
        local dnf5_actions_dir
        dnf5_actions_dir=$(dirname "$DNF5_ACTIONS_FILE")
        mkdir -p "$dnf5_actions_dir"
        backup "$DNF5_ACTIONS_FILE"

        cat > "$DNF5_ACTIONS_FILE" <<EOF
# Managed by snapper-setup.sh v2 -- hand edits will be overwritten on re-run.
# Triggers pre and post transaction snapshots for Snapper in DNF5, and
# regenerates the GRUB snapshot boot menu after each transaction.
#
# NOTE: these call standalone scripts rather than inline shell, because the
# DNF5 actions plugin does whitespace-based tokenization of the action line
# (not real shell parsing). Embedded quotes or a repeated flag-like token
# (e.g. "-c" appearing twice) will break inline commands with confusing
# "unexpected EOF" errors. Keep this file to bare script paths + unquoted
# variable substitution only.

pre_transaction::::${HOOK_PRE_SCRIPT}

post_transaction::::${HOOK_POST_SCRIPT} \${tmp.snapper_pre_number}
EOF
        echo "Wrote DNF5 snapshot actions configuration to ${DNF5_ACTIONS_FILE}"
    else
        echo "Configuring DNF4 snapper plugin..."
        local dnf4_snapper_conf="/etc/dnf/plugins/snapper.conf"
        if [[ -f "$dnf4_snapper_conf" ]]; then
            backup "$dnf4_snapper_conf"
            if grep -q "\[main\]" "$dnf4_snapper_conf"; then
                sed -i 's/^enabled=.*/enabled=1/' "$dnf4_snapper_conf"
            else
                cat >> "$dnf4_snapper_conf" <<EOF

[main]
enabled=1
EOF
            fi
        fi
    fi
}

########################################
# Systemd Timers & Services
########################################

configure_services() {

    echo "Enabling Snapper timeline and cleanup systemd timers..."
    systemctl daemon-reload

    systemctl enable --now snapper-timeline.timer
    systemctl enable --now snapper-cleanup.timer

    if [[ "${INSTALL_GRUB_BTRFS}" == "1" && "${GRUB_BTRFS_AVAILABLE:-0}" -eq 1 ]]; then

        # Determine the GRUB config path GRUB actually reads at boot.
        #
        # v1/early-v2 bug: this used to prioritize /boot/efi/EFI/fedora/grub.cfg
        # on UEFI systems. On modern Fedora (BLS -- BootLoaderSpec -- boot
        # entries, default since Fedora 30+), the real config consulted at
        # boot is /boot/grub2/grub.cfg regardless of UEFI/BIOS; the EFI
        # partition typically holds only a small stub or unrelated grub.cfg,
        # and writing there silently produces a config GRUB never reads. This
        # was confirmed live: grub2-mkconfig against the EFI path returned
        # non-zero, while /boot/grub2/grub.cfg is what every manual test in
        # this session actually used successfully.
        local grub_cfg="/boot/grub2/grub.cfg"
        if [[ -d /sys/firmware/efi ]]; then
            echo "Detected UEFI boot mode."
        else
            echo "Detected Legacy BIOS boot mode."
        fi
        if [[ ! -f "$grub_cfg" ]]; then
            # Fallback for unusual layouts where /boot/grub2/grub.cfg doesn't
            # exist yet.
            if [[ -f /boot/efi/EFI/fedora/grub.cfg ]]; then
                grub_cfg="/boot/efi/EFI/fedora/grub.cfg"
            elif [[ -f /etc/grub2.cfg ]]; then
                grub_cfg="/etc/grub2.cfg"
            fi
        fi
        GRUB_CFG_PATH="$grub_cfg"
        echo "Using GRUB config path: ${GRUB_CFG_PATH}"

        if [[ "$NESTED_SUBVOL_LAYOUT" -eq 1 ]]; then
            echo "Detected nested root subvolume layout (subvol option is not plain '/')."
            echo "grub-btrfs.path relies on an auto-derived mount dependency for /.snapshots"
            echo "that does not exist on this layout, and will fail to start. Skipping it;"
            echo "GRUB regeneration is instead driven by the DNF5 post_transaction hook"
            echo "installed above, which works independent of subvolume layout."
            systemctl disable grub-btrfs.path 2>/dev/null || true
        else
            if systemctl list-unit-files | grep -q "grub-btrfs.path"; then
                echo "Enabling grub-btrfs path monitoring service..."
                if ! systemctl enable --now grub-btrfs.path; then
                    echo "WARNING: grub-btrfs.path failed to start. Falling back to hook-driven regeneration."
                    systemctl disable grub-btrfs.path 2>/dev/null || true
                fi
            fi
        fi

        if command -v grub2-mkconfig >/dev/null 2>&1; then
            echo "Regenerating GRUB configuration for grub-btrfs menu entries (${grub_cfg})..."
            grub2-mkconfig -o "$grub_cfg" 2>/dev/null || echo "Notice: grub2-mkconfig returned non-zero status; check GRUB config."
        fi

        if [[ "${ENABLE_DAILY_GRUB_REGEN}" == "1" ]]; then
            configure_daily_grub_regen "$grub_cfg"
        fi
    fi
}

# Timeline (hourly) snapshots are not tied to a dnf transaction, so the
# post_transaction hook never regenerates GRUB for them. Without this, they
# exist in `snapper list` but never appear as bootable menu entries until the
# next dnf transaction happens to trigger a regen. This daily timer closes
# that gap independent of dnf activity.
configure_daily_grub_regen() {
    local grub_cfg="$1"

    echo "Configuring daily GRUB regeneration timer (covers timeline snapshots)..."

    cat > /etc/systemd/system/grub-btrfs-regen.service <<EOF
[Unit]
Description=Regenerate GRUB config to pick up new Snapper snapshots (incl. timeline)

[Service]
Type=oneshot
ExecStart=/usr/sbin/grub2-mkconfig -o ${grub_cfg}
EOF

    cat > /etc/systemd/system/grub-btrfs-regen.timer <<'EOF'
[Unit]
Description=Daily GRUB regen for snapshot menu sync

[Timer]
OnCalendar=daily
Persistent=true

[Install]
WantedBy=timers.target
EOF

    systemctl daemon-reload
    systemctl enable --now grub-btrfs-regen.timer
}

########################################
# Verification & Functional Testing
########################################

test_snapshot_functionality() {

    echo "Testing snapshot creation functionality..."
    local snap_num
    snap_num=$(snapper -c "${CONFIG_NAME}" create -d "Post-install baseline" --cleanup-algorithm number -p 2>/dev/null || echo "")

    if [[ -n "$snap_num" ]]; then
        echo "Successfully created baseline snapshot #${snap_num}."
        BASELINE_SNAPSHOT_NUM="$snap_num"
    else
        echo "Warning: Could not verify snapshot creation. Check Snapper logs."
        BASELINE_SNAPSHOT_NUM="Failed"
    fi
}

verify() {

    echo
    echo "==============================="
    echo "Verification"
    echo "==============================="
    echo

    echo "Distro:            ${DISTRO_NAME} (family: ${DISTRO_FAMILY}, pkg mgr: ${PKG_MANAGER})"
    echo "Root filesystem:   ${FS_TYPE}"
    echo "Boot mode:         $([[ -d /sys/firmware/efi ]] && echo "UEFI" || echo "Legacy BIOS")"
    if command -v getenforce >/dev/null 2>&1; then
        echo "SELinux:           $(getenforce)"
    fi
    echo

    echo "Snapper Configs:"
    if command -v snapper >/dev/null 2>&1; then
        snapper list-configs || true
    else
        echo "snapper not found"
    fi
    echo

    echo "Systemd Timers:"
    systemctl list-timers --no-pager | grep -E 'snapper|grub-btrfs' || true
    echo

    echo "DNF Snapshot Integration:"
    if [[ "$PKG_MANAGER" == "dnf5" ]]; then
        if pkg_installed libdnf5-plugin-snapper; then
            echo "DNF5 Plugin: Native libdnf5-plugin-snapper package"
        elif [[ -f "$DNF5_ACTIONS_FILE" ]]; then
            echo "DNF5 Plugin: Hook scripts active (${DNF5_ACTIONS_FILE})"
            if [[ -x "$HOOK_PRE_SCRIPT" && -x "$HOOK_POST_SCRIPT" ]]; then
                echo "Hook scripts:  OK (${HOOK_PRE_SCRIPT}, ${HOOK_POST_SCRIPT})"
            else
                echo "Hook scripts:  MISSING or not executable -- re-run setup"
            fi
        else
            echo "DNF5 Plugin: Missing"
        fi
    else
        if rpm -q python3-dnf-plugin-snapper >/dev/null 2>&1 || rpm -q dnf-plugin-snapper >/dev/null 2>&1; then
            echo "DNF4 Snapper Plugin: Installed"
        else
            echo "DNF4 Snapper Plugin: Not installed"
        fi
    fi
    echo

    echo "Btrfs Assistant:"
    if command -v btrfs-assistant >/dev/null 2>&1 || rpm -q btrfs-assistant >/dev/null 2>&1; then
        echo "Btrfs Assistant: Installed"
    else
        echo "Btrfs Assistant: Not installed"
    fi
    echo

    echo "GRUB Btrfs Status:"
    if rpm -q grub-btrfs >/dev/null 2>&1 || rpm -q grub-btrfs-snapper >/dev/null 2>&1; then
        echo "grub-btrfs package: Installed"
        if [[ "${NESTED_SUBVOL_LAYOUT:-0}" -eq 1 ]]; then
            echo "grub-btrfs.path:     Not used by design (nested subvolume layout; see script comments)"
        elif systemctl is-active --quiet grub-btrfs.path 2>/dev/null; then
            echo "grub-btrfs.path:     Active"
        else
            echo "grub-btrfs.path:     Inactive"
        fi
        # The real signal that matters: does the current grub.cfg actually
        # contain a snapshots submenu, and are the hook scripts wired in.
        if [[ -f "$GRUB_CFG_PATH" ]] && grep -q "Fedora Linux snapshots" "$GRUB_CFG_PATH" 2>/dev/null; then
            echo "GRUB menu sync:      OK (snapshots submenu present in ${GRUB_CFG_PATH})"
        else
            echo "GRUB menu sync:      Not confirmed -- run 'grub2-mkconfig' or trigger a dnf transaction"
        fi
        if systemctl is-active --quiet grub-btrfs-regen.timer 2>/dev/null; then
            echo "Daily regen timer:   Active (covers timeline snapshots)"
        else
            echo "Daily regen timer:   Not active"
        fi
    else
        echo "grub-btrfs: Not installed"
    fi
    echo

    echo "Current Snapper Snapshots:"
    if command -v snapper >/dev/null 2>&1; then
        snapper -c "${CONFIG_NAME}" list || true
    fi
    echo
}

print_summary() {

    local timeline_status="✘ Disabled"
    local cleanup_status="✘ Disabled"
    local dnf_status="✘ Inactive"
    local grub_status="✘ Inactive"
    local snap_status="✘ Not created"

    if systemctl is-active --quiet snapper-timeline.timer 2>/dev/null; then
        timeline_status="✔ Active"
    fi

    if systemctl is-active --quiet snapper-cleanup.timer 2>/dev/null; then
        cleanup_status="✔ Active"
    fi

    if [[ "$PKG_MANAGER" == "dnf5" ]]; then
        if pkg_installed libdnf5-plugin-snapper || [[ -f "$DNF5_ACTIONS_FILE" && -x "$HOOK_PRE_SCRIPT" ]]; then
            dnf_status="✔ Configured"
        fi
    else
        if rpm -q python3-dnf-plugin-snapper >/dev/null 2>&1 || rpm -q dnf-plugin-snapper >/dev/null 2>&1; then
            dnf_status="✔ Active"
        fi
    fi

    if [[ -f "${GRUB_CFG_PATH:-}" ]] && grep -q "Fedora Linux snapshots" "${GRUB_CFG_PATH:-/nonexistent}" 2>/dev/null; then
        grub_status="✔ Synced"
    fi

    if [[ "${BASELINE_SNAPSHOT_NUM:-Failed}" != "Failed" ]]; then
        snap_status="✔ Created (#${BASELINE_SNAPSHOT_NUM})"
    fi

    echo "=========================================="
    echo "Root configuration summary:"
    echo "  ${timeline_status} Timeline snapshots"
    echo "  ${cleanup_status} Cleanup timer"
    echo "  ${dnf_status} DNF snapshot integration"
    echo "  ${grub_status} GRUB menu sync"
    echo "  ${snap_status} Baseline snapshot test"
    echo "=========================================="
    echo
}

########################################
# Help & Main
########################################

show_help() {
    cat <<EOF
Usage: $0 [OPTIONS]

Fedora Snapper + DNF5 Snapshot Plugin + Btrfs Assistant Setup Script (v2)

Options:
  -y, --yes              Non-interactive mode (automatically answer yes to prompts)
  --verify                Verify existing Snapper and DNF setup without making changes
  --no-grub-btrfs          Skip installing and configuring grub-btrfs
  --grub-btrfs             Force installing and configuring grub-btrfs (default: enabled)
  --no-daily-grub-regen    Skip the daily timer that syncs timeline snapshots to GRUB
  -h, --help              Show this help message and exit

Environment Variables:
  ALLOW_USERS              Usernames granted snapper access (comma-separated)
  ALLOW_GROUPS              Group names granted snapper access (default: wheel)
  INSTALL_GRUB_BTRFS        Set to 1 to install grub-btrfs, 0 to skip (default: 1)
  ENABLE_DAILY_GRUB_REGEN   Set to 1 to enable daily GRUB regen timer, 0 to skip (default: 1)
  ENABLE_TIMELINE           Set to yes/no to enable/disable timeline snapshots (default: yes)
  ENABLE_CLEANUP            Set to yes/no to enable/disable snapshot cleanup (default: yes)
  ASSUME_YES                Set to 1 for non-interactive execution (default: 0)
EOF
}

main() {

    local verify_only=0

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -y|--yes)
                ASSUME_YES=1
                shift
                ;;
            --verify)
                verify_only=1
                shift
                ;;
            --no-grub-btrfs)
                INSTALL_GRUB_BTRFS=0
                shift
                ;;
            --grub-btrfs)
                INSTALL_GRUB_BTRFS=1
                shift
                ;;
            --no-daily-grub-regen)
                ENABLE_DAILY_GRUB_REGEN=0
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

    GRUB_CFG_PATH="/boot/grub2/grub.cfg"

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
    echo "Subvolume layout: $([[ "$NESTED_SUBVOL_LAYOUT" -eq 1 ]] && echo "Nested (${ROOT_SUBVOL_OPT})" || echo "Flat")"
    echo "grub-btrfs:      $([[ "$INSTALL_GRUB_BTRFS" == "1" ]] && echo "Enabled" || echo "Disabled")"
    echo "==============================="
    echo

    install_dependencies

    configure_snapper

    configure_dnf_plugin

    configure_services

    test_snapshot_functionality

    verify

    print_summary
}

main "$@"
