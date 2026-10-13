#!/usr/bin/env bash
# Install x11vnc as a systemd service that follows the active local X11 user.
# Debian / Raspberry Pi Desktop for PC (x86/x86_64), not Raspberry Pi-specific.
set -euo pipefail

if [[ ${EUID} -ne 0 ]]; then
    echo 'Run this script with sudo: sudo bash install-x11vnc.sh [--lan]' >&2
    exit 1
fi

case "${1:-}" in
    '')      BIND_MODE=local ;;
    --lan)   BIND_MODE=lan ;;
    *)       echo 'Usage: sudo bash install-x11vnc.sh [--lan]' >&2; exit 1 ;;
esac
if (( $# > 1 )); then
    echo 'Usage: sudo bash install-x11vnc.sh [--lan]' >&2
    exit 1
fi

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y x11vnc xauth

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
            if [[ "${X11VNC_BIND:-local}" != lan ]]; then
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

systemctl daemon-reload
systemctl enable --now x11vnc-follow-session.service
systemctl restart x11vnc-follow-session.service

echo
echo 'Installed x11vnc-follow-session.service'
echo "Connection mode: $BIND_MODE"
echo 'Check: sudo systemctl status x11vnc-follow-session --no-pager'
echo 'Logs:  sudo journalctl -u x11vnc-follow-session -f'
if [[ "$BIND_MODE" == local ]]; then
    echo 'Connect using SSH tunneling (see instructions). VNC listens on 127.0.0.1:5900.'
else
    echo 'LAN MODE: VNC listens on TCP port 5900. Restrict access with your firewall.'
    echo 'Do NOT expose port 5900 directly to the internet; plain VNC is not encrypted.'
fi