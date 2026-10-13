# Wi-Fi firmware: setup notes

Use this alongside [the main README](../README.md) and the [PDF guide](wifi_firmware_installation_documentation.pdf).

## Purpose
The installer detects common PCI/PCIe and identifiable USB Wi-Fi adapters on Debian-based PCs (including Raspberry Pi Desktop for PC on Dell hardware). It uses Debian's APT packages to install firmware; it does not install arbitrary third-party wireless drivers.

## Requirements
- Debian-based operating system with `apt-get`
- Root access for installation
- Temporary internet access via Ethernet or USB tethering
- A wireless adapter enabled in firmware/BIOS

## Commands

Read-only detection:

```bash
bash install-wifi-firmware.sh --diagnose
```

Install firmware:

```bash
sudo bash install-wifi-firmware.sh
sudo reboot
```

Prevent automatic APT source creation:

```bash
sudo bash install-wifi-firmware.sh --no-repo
```

## Recognized firmware families

| Vendor | Typical Debian firmware package |
| --- | --- |
| Intel | `firmware-iwlwifi` |
| Realtek | `firmware-realtek` |
| Broadcom | `firmware-brcm80211` |
| Qualcomm/Atheros | `firmware-atheros` |
| MediaTek/Ralink | `firmware-mediatek` or `firmware-misc-nonfree` depending on release |
| Marvell | `firmware-libertas` |

These are best-effort vendor matches, not guarantees of support for every device. The script may add an official Debian `non-free-firmware` source on Debian 12 or 13 if needed.

## Troubleshooting
If no device is found, confirm Wi-Fi is enabled in BIOS/UEFI and check `lspci -nnk` and `lsusb`. If installation fails, verify working internet and APT sources. If Wi-Fi remains unavailable after reboot, inspect `ip link`, `rfkill list wifi`, and `sudo dmesg | grep -Ei 'firmware|wifi|wlan'`.

Some devices need an additional kernel driver or newer kernel, and this script does not configure network credentials.