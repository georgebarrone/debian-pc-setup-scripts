#!/usr/bin/env bash
# Debian / Raspberry Pi Desktop (PC) Wi-Fi firmware installer
# Detects common PCIe and identifiable USB Wi-Fi chipsets, installs the
# appropriate firmware from Debian's signed APT repositories, then reports status.
set -Eeuo pipefail

MODE=install
AUTO_REPO=1
for arg in "$@"; do
    case "$arg" in
        --diagnose) MODE=diagnose ;;
        --no-repo) AUTO_REPO=0 ;;
        -h|--help)
            cat <<'HELP'
Usage:
  sudo bash install-wifi-firmware.sh            Detect and install firmware
  bash install-wifi-firmware.sh --diagnose      Only show detected hardware
  sudo bash install-wifi-firmware.sh --no-repo  Never add an APT source

Connect temporary Ethernet or USB tethering before installing.
On Debian 12/13, the installer may add an official Debian *firmware-only*
APT source if required. It never installs third-party driver scripts.
HELP
            exit 0 ;;
        *) printf 'Unknown option: %s\n' "$arg" >&2; exit 2 ;;
    esac
done

if [[ "$MODE" == install && "${EUID}" -ne 0 ]]; then
    echo 'Error: installation requires root. Run: sudo bash install-wifi-firmware.sh' >&2
    exit 1
fi
if [[ ! -r /etc/os-release ]] || ! command -v apt-get >/dev/null 2>&1; then
    echo 'Error: this script requires an APT-based Debian system.' >&2
    exit 1
fi
# shellcheck disable=SC1091
. /etc/os-release
CODENAME="${VERSION_CODENAME:-unknown}"

log()  { printf '\n==> %s\n' "$*"; }
warn() { printf 'Warning: %s\n' "$*" >&2; }

# Bash 4+ is standard on supported Debian releases.
declare -A chosen=()
declare -a detected=()
declare -a notes=()

choose() {
    chosen["$1"]=1
}

classify() {
    local vendor="$1" description="$2"
    case "${vendor,,}" in
        0x8086|8086) choose firmware-iwlwifi ;;
        0x10ec|10ec|0x0bda|0bda) choose firmware-realtek ;;
        0x14e4|14e4|0x0a5c|0a5c)
            choose firmware-brcm80211
            notes+=("Some Broadcom cards need a different driver (e.g., broadcom-sta-dkms) or b43 firmware. This installer will not guess or install proprietary kernel drivers.") ;;
        0x168c|168c|0x17cb|17cb|0x0cf3|0cf3) choose firmware-atheros ;;
        0x14c3|14c3|0x1814|1814|0x0e8d|0e8d|0x148f|148f)
            if [[ "$CODENAME" == bullseye || "$CODENAME" == bookworm ]]; then
                choose firmware-misc-nonfree
            else
                choose firmware-mediatek
            fi ;;
        0x11ab|11ab) choose firmware-libertas ;;
        *) notes+=("Unrecognized Wi-Fi chipset: ${description}. Check its exact model and kernel support.") ;;
    esac
}

log "System: ${PRETTY_NAME:-Debian} | Kernel: $(uname -r) | Architecture: $(uname -m)"
log 'Detecting PCI/PCIe Wi-Fi devices using sysfs'
shopt -s nullglob
for device in /sys/bus/pci/devices/*; do
    [[ -r "$device/class" && -r "$device/vendor" ]] || continue
    class=$(<"$device/class")
    # PCI class 0280 = Network controller (the usual class for Wi-Fi cards).
    [[ "$class" == 0x0280* ]] || continue
    vendor=$(<"$device/vendor")
    model=$(<"$device/device")
    driver='none'
    if [[ -L "$device/driver" ]]; then
        driver=$(basename "$(readlink -f "$device/driver")")
    fi
    label="PCI $(basename "$device"): ${vendor}:${model} (kernel driver: ${driver})"
    printf '  %s\n' "$label"
    detected+=("$label")
    classify "$vendor" "$label"
done

log 'Detecting identifiable USB Wi-Fi adapters'
for device in /sys/bus/usb/devices/*; do
    [[ -r "$device/idVendor" && -r "$device/idProduct" ]] || continue
    vendor=$(<"$device/idVendor")
    model=$(<"$device/idProduct")
    product=''
    manufacturer=''
    [[ -r "$device/product" ]] && product=$(<"$device/product")
    [[ -r "$device/manufacturer" ]] && manufacturer=$(<"$device/manufacturer")
    desc="$manufacturer $product"
    # Only identify it as wireless when the descriptor states a Wi-Fi
    # technology/chipset. Brand-only USB IDs can also be webcams/Bluetooth.
    if [[ ! "$desc" =~ [Ww]ireless|[Ww][Ii]-?[Ff][Ii]|WLAN|wlan|802\.11|RTL8[0-9]|MT76[0-9]|RT[235][0-9][0-9][0-9] ]]; then
        continue
    fi
    label="USB ${vendor}:${model}: ${desc}"
    printf '  %s\n' "$label"
    detected+=("$label")
    classify "$vendor" "$label"
done

if command -v lspci >/dev/null 2>&1; then
    echo
    echo 'PCI device details:'
    lspci -nnk | grep -A 3 -iE 'Network controller|Wireless|Wi-Fi|WLAN' || true
fi
if command -v lsusb >/dev/null 2>&1; then
    echo
    echo 'USB devices (for manual identification if needed):'
    lsusb || true
fi

log 'Existing wireless network interfaces'
found_interface=0
for iface in /sys/class/net/*; do
    if [[ -d "$iface/wireless" || -L "$iface/phy80211" ]]; then
        printf '  %s\n' "$(basename "$iface")"
        found_interface=1
    fi
done
if [[ "$found_interface" -eq 0 ]]; then
    echo '  None detected yet.'
fi

if (( ${#detected[@]} == 0 )); then
    warn 'No PCI Wi-Fi controller or identifiable USB Wi-Fi device was detected.'
    warn 'Check BIOS/UEFI wireless settings, USB adapter identity, or whether hardware is physically installed.'
    notes+=("Some USB adapters only expose a generic description. Run lsusb (package: usbutils) to identify its exact USB ID.")
fi
for note in "${notes[@]}"; do warn "$note"; done

if [[ "$MODE" == diagnose ]]; then
    log 'Diagnostic-only mode: nothing was changed.'
    if (( ${#chosen[@]} )); then
        printf 'Suggested packages: %s\n' "${!chosen[*]}"
    else
        echo 'Suggested packages: none'
    fi
    exit 0
fi
if (( ${#chosen[@]} == 0 )); then
    warn 'No reliable firmware package match. Nothing was installed.'
    exit 2
fi

log 'Refreshing package lists (requires temporary internet access)'
if ! apt-get update; then
    warn 'APT update failed. Check Ethernet/USB tethering, APT sources, system date, and Debian release support.'
    exit 1
fi

candidate_exists() {
    local candidate
    candidate=$(apt-cache policy "$1" | awk '/^[[:space:]]*Candidate:/ {print $2; exit}')
    [[ -n "$candidate" && "$candidate" != '(none)' ]]
}

# Bookworm and Trixie may ship without non-free-firmware enabled.
# Add only an official, version-pinned, signed Debian firmware component,
# and only when needed. Never replace the user's existing repositories.
missing=0
for pkg in "${!chosen[@]}"; do
    if ! candidate_exists "$pkg"; then missing=1; fi
done

if (( missing )) && (( AUTO_REPO )) && [[ "$ID" == debian ]] \
    && [[ "$CODENAME" == bookworm || "$CODENAME" == trixie ]]; then
    REPO_FILE=/etc/apt/sources.list.d/wifi-firmware-autosetup.list
    if [[ ! -e "$REPO_FILE" ]]; then
        log "Adding the Debian ${CODENAME} non-free-firmware component (firmware packages only)"
        # Match Signed-By from an existing official Debian source so APT
        # does not reject two entries for the same suite with differing keys.
        signed_by=''
        for source_file in /etc/apt/sources.list.d/*.sources; do
            [[ -f "$source_file" ]] || continue
            candidate_key=$(awk -v release="$CODENAME" '
                BEGIN { RS=""; FS="\n" }
                /URIs:[^\n]*deb\.debian\.org\/debian/ && index($0, release) {
                    for (i=1; i<=NF; i++) if ($i ~ /^Signed-By:[[:space:]]*\//) {
                        sub(/^Signed-By:[[:space:]]*/, "", $i); print $i; exit
                    }
                }
            ' "$source_file")
            if [[ -n "$candidate_key" ]]; then signed_by="$candidate_key"; break; fi
        done
        if [[ -z "$signed_by" ]]; then
            for source_file in /etc/apt/sources.list /etc/apt/sources.list.d/*.list; do
                [[ -f "$source_file" ]] || continue
                candidate_key=$(sed -n -E "/^[[:space:]]*deb .*deb\.debian\.org\/debian[[:space:]]+${CODENAME}[[:space:]]/s/.*signed-by=([^] ]+).*/\1/p" "$source_file" | head -n 1)
                if [[ -n "$candidate_key" ]]; then signed_by="$candidate_key"; break; fi
            done
        fi
        if [[ -z "$signed_by" && -r /usr/share/keyrings/debian-archive-keyring.gpg ]]; then
            signed_by=/usr/share/keyrings/debian-archive-keyring.gpg
        fi
        if [[ -n "$signed_by" ]]; then
            printf 'deb [signed-by=%s] https://deb.debian.org/debian %s non-free-firmware\n' "$signed_by" "$CODENAME" > "$REPO_FILE"
        else
            printf 'deb https://deb.debian.org/debian %s non-free-firmware\n' "$CODENAME" > "$REPO_FILE"
        fi
        echo "Added: $REPO_FILE"
        if ! apt-get update; then
            warn "APT rejected the new source or another repository failed. Removing $REPO_FILE."
            rm -f "$REPO_FILE"
            exit 1
        fi
    fi
fi

packages=()
for pkg in "${!chosen[@]}"; do
    if candidate_exists "$pkg"; then
        packages+=("$pkg")
    else
        warn "Firmware package unavailable: $pkg"
        warn "Check firmware repository components for ${CODENAME}, or upgrade an unsupported Debian release."
    fi
done
if (( ${#packages[@]} == 0 )); then
    warn 'No matching firmware package is available from configured repositories.'
    exit 1
fi

log "Installing Debian firmware: ${packages[*]}"
if ! apt-get install -y "${packages[@]}"; then
    warn 'Firmware installation failed. Review APT errors above.'
    exit 1
fi

log 'Checking wireless interfaces after installation'
found_interface=0
for iface in /sys/class/net/*; do
    if [[ -d "$iface/wireless" || -L "$iface/phy80211" ]]; then
        printf '  Found: %s\n' "$(basename "$iface")"
        found_interface=1
    fi
done
if command -v rfkill >/dev/null 2>&1; then
    echo
    rfkill list wifi || true
fi
if (( found_interface )); then
    echo 'A wireless interface is present. You can configure Wi-Fi through the desktop network manager.'
else
    warn 'No wireless interface is present yet. Reboot to allow kernel modules to reload the new firmware.'
    warn 'If it is still missing afterward, the card may need a newer kernel or a separate driver.'
fi
log 'Done. Recommended next step: reboot when convenient (sudo reboot).'