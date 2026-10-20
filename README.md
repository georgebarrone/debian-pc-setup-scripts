# Debian PC Setup Scripts

Post-install utilities for **Debian-based PCs**, especially Dell desktops/laptops running **Raspberry Pi Desktop for PC** (x86/x86_64). No Raspberry Pi hardware is required.

This repository provides two **independent** Bash installers:

| Installer | Purpose |
| --- | --- |
| `install-wifi-firmware.sh` | Detect common Wi-Fi chipsets and install suitable Debian firmware packages |
| `install-x11vnc.sh` | Install x11vnc as a systemd service that shares the **currently active local X11 desktop** |

Both scripts require root privileges for installation. Read them before running on devices you manage. Neither utility guarantees compatibility with every machine, adapter, or desktop environment.

## Requirements

- Debian-based OS using `apt` and `systemd` for the VNC installer.
- `sudo` access.
- **Internet access** (for example Ethernet or USB tethering) during package installation.
- For VNC, a **local X11 desktop session**. Wayland is not supported by this x11vnc setup.

## 1. Wi-Fi firmware installer

Run a **read-only hardware check** first:

```bash
bash install-wifi-firmware.sh --diagnose
```

Then, with temporary working internet access:

```bash
sudo bash install-wifi-firmware.sh
sudo reboot
```

After reboot, check the desktop Wi-Fi menu or inspect interfaces with `ip link`.

The script attempts to identify PCI/PCIe and some recognizable USB Wi-Fi adapters and install matching firmware using official Debian APT packages. Supported families include common Intel, Realtek, Broadcom, Qualcomm/Atheros, MediaTek, and Marvell devices. **It does not download arbitrary third-party driver scripts**, and some adapters may need other kernel drivers.

On Debian 12/13, the script may add an official `non-free-firmware` package source if needed. To prevent it from adding a repository:

```bash
sudo bash install-wifi-firmware.sh --no-repo
```

Further details: [Wi-Fi notes](docs/wifi-firmware-notes.md) | [Wi-Fi installation PDF](docs/wifi_firmware_installation_documentation.pdf).

## 2. x11vnc installer (share the logged-in user's desktop)

First, **from the graphical desktop**, confirm the display server:

```bash
echo "$XDG_SESSION_TYPE"
```

It must report `x11`. The installer uses `loginctl` to find the active local X11 session on `seat0`. It does not create a new virtual desktop or connect to a Wayland session.

Install with the **secure, localhost-only default**:

```bash
sudo bash install-x11vnc.sh
```

**Debian 11 (Bullseye):** If the normal APT update or dependency download fails with a recognized archived-repository error (such as an HTTP 404), the installer automatically backs up affected official Bullseye security source files, redirects those entries to Debian's security archive, refreshes indexes with a one-command expiry exception, and retries. It does not modify repositories on newer Debian releases. Debian 11 no longer receives regular security updates; upgrading is recommended.

The installer prompts you to create a VNC password (classic VNC authentication uses only the first eight password characters). It sets up and enables `x11vnc-follow-session.service`, which remains running and watches for desktop login/session changes.

Check its status or recent logs:

```bash
sudo systemctl status x11vnc-follow-session
sudo journalctl -u x11vnc-follow-session -f
```

### Connect securely using an SSH tunnel (recommended)

You must already have an **SSH server** running on the Debian PC. From your *other computer*, create the tunnel:

```bash
ssh -L 5900:localhost:5900 username@DELL_IP
```

Then connect a VNC viewer on that other computer to `127.0.0.1:5900` and enter the VNC password.

### Optional: direct LAN access

```bash
sudo bash install-x11vnc.sh --lan
```

This exposes VNC on TCP port **5900** to reachable network clients, so a viewer can connect to `DELL_IP:5900`. **Direct VNC traffic is not encrypted.** Only use this mode on a trusted, restricted LAN, protect port 5900 with a firewall, and never expose it to the public internet.

Documentation: [x11vnc installation PDF](docs/x11vnc_installation_documentation.pdf).

## Common checks and troubleshooting

**Wi-Fi adapter still missing:** Verify the adapter is enabled in BIOS/UEFI, rerun `--diagnose`, inspect `lspci -nnk` / `lsusb` (if available), and look at firmware errors with `sudo dmesg | grep -Ei 'wifi|wlan|firmware|iwlwifi|brcm|rtl|ath|mt76'`. Some cards require a different driver or kernel version.

**VNC viewer cannot connect:** Confirm the GUI is running under **X11**, inspect the service logs, and check that a user is locally logged in. The default mode does **not** accept direct remote connections; use an SSH tunnel or deliberately choose `--lan`.

**No desktop session currently logged in:** The VNC service can be running while no desktop is shared. It connects when a supported active X11 session becomes available.

## Repository files

```text
debian-pc-setup-scripts/
├── README.md
├── install-wifi-firmware.sh
├── install-x11vnc.sh
└── docs/
    ├── wifi-firmware-notes.md
    ├── wifi_firmware_installation_documentation.pdf
    └── x11vnc_installation_documentation.pdf
```

## Notes

These scripts are intended for managed PCs and tested deployment workflows. Installation modifies system packages; the Wi-Fi utility may add an official firmware APT source, and the VNC utility installs a systemd service and a password file under `/etc`. Review scripts and test on one device before rolling out to multiple computers.
