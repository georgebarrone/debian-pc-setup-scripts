#!/usr/bin/env bash
# Install x11vnc as a systemd service that follows the active local X11 user.
# Debian / Raspberry Pi Desktop for PC (x86/x86_64), not Raspberry Pi-specific.
set -euo pipefail

if [[ ${EUID} -ne 0 ]]; then
    echo 'Run this script with sudo: sudo bash install-x11vnc.sh [--local]' >&2
    exit 1
fi

case "${1:-}" in
    '')        BIND_MODE=lan ;;
    --lan)     BIND_MODE=lan ;;
    --local)   BIND_MODE=local ;;
    *)         echo 'Usage: sudo bash install-x11vnc.sh [--local]' >&2; exit 1 ;;
esac
if (( $# > 1 )); then
    echo 'Usage: sudo bash install-x11vnc.sh [--local]' >&2
    exit 1
fi

export DEBIAN_FRONTEND=noninteractive

# Debian 11 (Bullseye) reached end of regular security support in 2026.
# Some Bullseye security mirrors still list packages that now return HTTP 404.
# Only if normal APT operations fail with a repository/archive-related error:
#   - back up affected official Debian source lists;
#   - switch bullseye-security to Debian's archived security mirror;
#   - refresh metadata with Valid-Until relaxed for THIS update command only;
#   - retry installation once.
# Do not change any sources for Debian 12/13+, or third-party repositories.
is_bullseye() {
    local VERSION_CODENAME='' VERSION_ID='' ID=''
    if [[ -r /etc/os-release ]]; then
        # shellcheck disable=SC1091
        . /etc/os-release
    fi
    [[ "$VERSION_CODENAME" == bullseye || "$VERSION_ID" == 11 ]]
}

apt_log="$(mktemp)"
trap 'rm -f "$apt_log"' EXIT

apt_run() {
    # Preserve the normal output while recording the error for targeted repair.
    apt-get "$@" 2>&1 | tee "$apt_log"
}

apt_archive_error() {
    grep -Eiq '404[[:space:]]+Not[[:space:]]+Found|Release file.*(expired|not valid)|does not have a Release file' "$apt_log"
}

repair_bullseye_security_sources() {
    local file backup stamp changed=0 tmp
    stamp="$(date +%Y%m%d-%H%M%S)"
    echo 'Debian 11 repository issue detected. Checking official Bullseye security sources...'
    echo 'WARNING: Debian 11 is end-of-life; archived packages do NOT provide ongoing security updates.'
    shopt -s nullglob
    for file in /etc/apt/sources.list /etc/apt/sources.list.d/*.list /etc/apt/sources.list.d/*.sources; do
        [[ -f "$file" ]] || continue
        # Only touch active Debian Bullseye security entries, not third-party entries.
        if [[ "$file" == *.sources ]]; then
            grep -Eq '^[[:space:]]*Suites:[[:space:]]*.*bullseye-security([[:space:]]|$)' "$file" || continue
            grep -Eq '^URIs:.*(deb.debian.org|security.debian.org)/debian-security' "$file" || continue
            # A mixed-release deb822 file cannot be changed safely wholesale.
            if grep -Eq '^[[:space:]]*Suites:.*(bookworm|trixie|forky|sid)' "$file"; then
                echo "Skipping mixed-release source file: $file" >&2
                continue
            fi
            tmp="$(mktemp)"
            sed -E 's#https?://(deb.debian.org|security.debian.org)/debian-security#http://archive.debian.org/debian-security#g' "$file" > "$tmp"
        else
            grep -Eq '^[[:space:]]*deb(-src)?[[:space:]].*bullseye-security' "$file" || continue
            tmp="$(mktemp)"
            sed -E '/^[[:space:]]*deb(-src)?[[:space:]].*bullseye-security/s#https?://(deb.debian.org|security.debian.org)/debian-security#http://archive.debian.org/debian-security#g' "$file" > "$tmp"
        fi
        if ! cmp -s "$file" "$tmp"; then
            backup="${file}.bak-x11vnc-${stamp}"
            cp -p "$file" "$backup"
            cat "$tmp" > "$file"
            echo "Repaired $file (backup: $backup)"
            changed=1
        fi
        rm -f "$tmp"
    done
    shopt -u nullglob
    if (( changed == 0 )); then
        echo 'No outdated official bullseye-security source URL needed changing.'
    fi
    return 0
}

retry_with_bullseye_archive() {
    if ! is_bullseye || ! apt_archive_error; then
        return 1
    fi
    repair_bullseye_security_sources
    echo 'Refreshing Debian 11 archive metadata (temporary Valid-Until exception)...'
    apt_run -o Acquire::Check-Valid-Until=false update || return 1
    echo 'Retrying VNC dependencies...'
    apt_run install -y x11vnc xauth
}

if apt_run update; then
    if ! apt_run install -y x11vnc xauth; then
        echo 'Initial VNC package installation failed.' >&2
        retry_with_bullseye_archive || {
            echo 'Installation failed. Inspect the APT messages above; no VNC service changes were made.' >&2
            exit 1
        }
    fi
else
    echo 'Initial APT update failed.' >&2
    retry_with_bullseye_archive || {
        echo 'APT could not update; no VNC service changes were made.' >&2
        exit 1
    }
fi

# x11vnc prompts for a VNC password, but does not place it on the command line.
PASSWORD_FILE=/etc/x11vnc.pass
if [[ ! -f "$PASSWORD_FILE" ]]; then
    echo 'Choose a VNC password (legacy VNC passwords use at most 8 characters).'
    x11vnc -storepasswd "$PASSWORD_FILE"
fi
chown root:root "$PASSWORD_FILE"
chmod 600 "$PASSWORD_FILE"

cat > /usr/local/sbin/x11vnc-follow-session <<'RUNNER'
#!/usr/bin/env bash
# Follow the foreground X11 user on the machine's physical/default seat.
set -u

PASSFILE=/etc/x11vnc.pass
child_pid=''
current_key=''

stop_vnc() {
    if [[ -n "$child_pid" ]]; then
        kill "$child_pid" 2>/dev/null || true
        wait "$child_pid" 2>/dev/null || true
        child_pid=''
    fi
}
trap 'exit 0' TERM INT
trap stop_vnc EXIT

# Read environment variables from the login session's leader when available.
leader_env() {
    local pid="$1" key="$2"
    if [[ "$pid" =~ ^[0-9]+$ && -r "/proc/$pid/environ" ]]; then
        tr '\0' '\n' < "/proc/$pid/environ" 2>/dev/null |
            sed -n "s/^${key}=//p" | head -n 1
    fi
}

# Print: session-id|UID|username|display|leader-PID
active_x11() {
    local sid line prop val active remote type seat class uid user display leader
    while read -r sid _; do
        [[ -n "$sid" ]] || continue
        active='' remote='' type='' seat='' class='' uid='' user='' display='' leader=''
        while IFS='=' read -r prop val; do
            case "$prop" in
                Active)  active="$val" ;;
                Remote)  remote="$val" ;;
                Type)    type="$val" ;;
                Seat)    seat="$val" ;;
                Class)   class="$val" ;;
                User)    uid="$val" ;;
                Name)    user="$val" ;;
                Display) display="$val" ;;
                Leader)  leader="$val" ;;
            esac
        done < <(loginctl show-session "$sid" --all \
            -p Active -p Remote -p Type -p Seat -p Class \
            -p User -p Name -p Display -p Leader 2>/dev/null)

        [[ "$active" == yes && "$remote" == no && "$type" == x11 && \
           "$seat" == seat0 && "$class" == user && -n "$uid" && -n "$user" ]] || continue
        [[ -n "$display" ]] || display="$(leader_env "$leader" DISPLAY)"
        # Most LightDM installations use :0; try that if logind does not report it.
        [[ -n "$display" ]] || display=:0
        printf '%s|%s|%s|%s|%s\n' "$sid" "$uid" "$user" "$display" "$leader"
        return 0
    done < <(loginctl list-sessions --no-legend 2>/dev/null)
    return 1
}

authority_for() {
    local uid="$1" user="$2" leader="$3" env_auth home path
    env_auth="$(leader_env "$leader" XAUTHORITY)"
    home="$(getent passwd "$user" | cut -d: -f6)"
    for path in "$env_auth" "/run/user/$uid/gdm/Xauthority" "$home/.Xauthority"; do
        if [[ -n "$path" && -f "$path" ]]; then
            printf '%s\n' "$path"
            return 0
        fi
    done
    return 1
}

while true; do
    session="$(active_x11)" || session=''
    key=''
    if [[ -n "$session" ]]; then
        IFS='|' read -r sid uid user display leader <<< "$session"
        auth="$(authority_for "$uid" "$user" "$leader")" || auth=''
        key="$sid|$display|$auth"
    fi

    if [[ "$key" != "$current_key" ]] || \
       { [[ -n "$child_pid" ]] && ! kill -0 "$child_pid" 2>/dev/null; }; then
        stop_vnc
        current_key="$key"
        if [[ -n "$key" ]]; then
            echo "Sharing active X11 session: user=$user session=$sid display=$display"
            args=(-display "$display" -rfbport 5900 -rfbauth "$PASSFILE"
                  -forever -shared -repeat -noxdamage)
            if [[ -n "$auth" ]]; then
                args+=(-auth "$auth")
            else
                args+=(-auth guess -env FD_XDM=1)
            fi
            if [[ "${X11VNC_BIND:-lan}" != lan ]]; then
                args+=(-localhost)
            fi
            /usr/bin/x11vnc "${args[@]}" &
            child_pid=$!
        else
            echo 'No active local X11 user session; waiting for desktop login.'
        fi
    fi
    sleep 3 &
    wait "$!" 2>/dev/null || true
done
RUNNER

chmod 755 /usr/local/sbin/x11vnc-follow-session

cat > /etc/default/x11vnc-follow-session <<CONFIG
X11VNC_BIND=$BIND_MODE
CONFIG
chmod 644 /etc/default/x11vnc-follow-session

cat > /etc/systemd/system/x11vnc-follow-session.service <<'UNIT'
[Unit]
Description=Share active local X11 desktop through x11vnc
After=systemd-logind.service display-manager.service
Wants=systemd-logind.service

[Service]
Type=simple
EnvironmentFile=-/etc/default/x11vnc-follow-session
ExecStart=/usr/local/sbin/x11vnc-follow-session
Restart=always
RestartSec=5
KillMode=control-group

[Install]
WantedBy=multi-user.target
UNIT

# Simple on-device command for checking and controlling VNC.
# The service itself starts automatically at boot, and only serves X11 after login.
cat > /usr/local/bin/vnc <<'VNC_HELPER'
#!/usr/bin/env bash
set -euo pipefail
SERVICE=x11vnc-follow-session.service
ACTION="${1:-status}"
if (( $# > 1 )); then
  echo "Usage: vnc [status|start|restart|stop|logs]" >&2
  exit 2
fi
case "$ACTION" in
  status)
    if ! systemctl is-active --quiet "$SERVICE"; then
      echo "VNC service: NOT running. Start with: sudo vnc start"
      exit 1
    fi
    echo "VNC service: running (auto-starts at boot)"
    if ! command -v ss >/dev/null 2>&1; then
      echo "Unable to check port 5900: 'ss' is not installed."
      exit 1
    fi
    LISTENERS="$(ss -H -ltn 'sport = :5900' 2>/dev/null || true)"
    if [[ -z "$LISTENERS" ]]; then
      echo "VNC port 5900: not listening yet."
      echo "Log into the physical X11 desktop; this service waits for a local X11 user session."
      echo "If already logged in, inspect: sudo vnc logs"
      exit 1
    fi
    echo "VNC port 5900: listening."
    MODE="$(sed -n 's/^X11VNC_BIND=//p' /etc/default/x11vnc-follow-session 2>/dev/null | head -n 1)"
    if [[ "$MODE" == local ]]; then
      echo "Mode: localhost only. Connect through an SSH tunnel to 127.0.0.1:5900."
    else
      IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
      if [[ -n "$IP" ]]; then
        echo "Mode: direct LAN. VNC Viewer address: $IP:5900"
      else
        echo "Mode: direct LAN, but no non-loopback IP address was found."
      fi
      echo "Use only on a trusted, restricted LAN. VM NAT needs port forwarding."
    fi
    ;;
  start|restart|stop)
    if (( EUID != 0 )); then
      echo "Run: sudo vnc $ACTION" >&2
      exit 1
    fi
    if [[ "$ACTION" == start ]]; then
      systemctl enable --now "$SERVICE"
    else
      systemctl "$ACTION" "$SERVICE"
    fi
    if [[ "$ACTION" != stop ]]; then
      "$0" status || true
    fi
    ;;
  logs)
    journalctl -u "$SERVICE" -n 40 --no-pager
    ;;
  *)
    echo "Usage: vnc [status|start|restart|stop|logs]" >&2
    exit 2
    ;;
esac
VNC_HELPER
chmod 755 /usr/local/bin/vnc

systemctl daemon-reload
systemctl enable --now x11vnc-follow-session.service
systemctl restart x11vnc-follow-session.service

echo
echo 'Installed x11vnc-follow-session.service'
echo "Connection mode: $BIND_MODE"
echo 'Quick commands: vnc status | sudo vnc restart | sudo vnc start | sudo vnc logs'
echo 'Automatically checking the VNC service and listening port...'
if ! /usr/local/bin/vnc status; then
    echo 'NOTE: VNC is installed and enabled, but the listener is not ready yet.'
    echo 'A local X11 user login may be required; check the logs with: sudo vnc logs'
fi
if [[ "$BIND_MODE" == local ]]; then
    echo 'LOCAL MODE: Connect using SSH tunneling. VNC listens on 127.0.0.1:5900.'
else
    echo 'LAN MODE (default): VNC listens on TCP port 5900 and accepts direct LAN connections.'
    echo 'Connect your VNC viewer to DEVICE_IP or DEVICE_IP:5900.'
    echo 'Restrict access with your firewall and do NOT expose port 5900 directly to the internet.'
fi