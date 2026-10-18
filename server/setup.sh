#!/usr/bin/env bash
# Bamado browser server for Claude
# Usage (as root, on Ubuntu 22.04/24.04 x64):
#   curl -fsSL https://raw.githubusercontent.com/khodaverdianderik/bamado-media/main/server/setup.sh | sudo bash -s YOUR.DOMAIN.COM
# The domain's DNS A record must already point to this server, and ports 80/443 must be open.
set -euo pipefail

DOMAIN="${1:-}"
if [[ -z "$DOMAIN" ]]; then
  echo "Usage: sudo bash setup.sh your.domain.com" >&2
  exit 1
fi
if [[ $EUID -ne 0 ]]; then
  echo "Run as root (sudo)." >&2
  exit 1
fi

APP_USER=bamado
STATE_DIR=/etc/bamado-browser
mkdir -p "$STATE_DIR"

# Keep secrets stable across re-runs
if [[ ! -f "$STATE_DIR/secret" ]]; then
  head -c 24 /dev/urandom | od -An -tx1 | tr -d ' \n' > "$STATE_DIR/secret"
fi
if [[ ! -f "$STATE_DIR/vncpass" ]]; then
  head -c 6 /dev/urandom | od -An -tx1 | tr -d ' \n' > "$STATE_DIR/vncpass"
fi
SECRET="$(cat "$STATE_DIR/secret")"
VNCPASS="$(cat "$STATE_DIR/vncpass")"
chmod 600 "$STATE_DIR"/*

echo "==> Installing packages"
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y curl ca-certificates xvfb x11vnc novnc websockify fonts-noto fonts-noto-color-emoji

if ! command -v caddy >/dev/null 2>&1; then
  apt-get install -y debian-keyring debian-archive-keyring apt-transport-https gnupg
  curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg --yes
  curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' > /etc/apt/sources.list.d/caddy-stable.list
  apt-get update -y
  apt-get install -y caddy
fi

if ! command -v node >/dev/null 2>&1 || [[ "$(node -v | cut -d. -f1 | tr -d v)" -lt 20 ]]; then
  curl -fsSL https://deb.nodesource.com/setup_22.x | bash -
  apt-get install -y nodejs
fi

echo "==> Installing Playwright MCP + Chrome"
npm install -g @playwright/mcp@latest
npx -y playwright install --with-deps chrome

id -u "$APP_USER" >/dev/null 2>&1 || useradd -m -s /bin/bash "$APP_USER"
mkdir -p /home/$APP_USER/browser-profile
chown -R $APP_USER:$APP_USER /home/$APP_USER

echo "==> Creating services"
cat > /etc/systemd/system/bamado-xvfb.service <<EOF
[Unit]
Description=Virtual display for Bamado browser
After=network.target

[Service]
User=$APP_USER
ExecStart=/usr/bin/Xvfb :99 -screen 0 1366x900x24 -nolisten tcp
Restart=always

[Install]
WantedBy=multi-user.target
EOF

cat > /etc/systemd/system/bamado-mcp.service <<EOF
[Unit]
Description=Playwright MCP browser for Claude
After=bamado-xvfb.service
Requires=bamado-xvfb.service

[Service]
User=$APP_USER
Environment=DISPLAY=:99
Environment=HOME=/home/$APP_USER
ExecStart=$(command -v node) $(npm root -g)/@playwright/mcp/cli.js --browser chrome --user-data-dir /home/$APP_USER/browser-profile --viewport-size 1366x860 --host 127.0.0.1 --port 8931 --allowed-hosts $DOMAIN,localhost,127.0.0.1
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

cat > /etc/systemd/system/bamado-vnc.service <<EOF
[Unit]
Description=VNC view of Bamado browser (for one-time logins)
After=bamado-xvfb.service
Requires=bamado-xvfb.service

[Service]
User=$APP_USER
ExecStart=/usr/bin/x11vnc -display :99 -forever -shared -localhost -rfbport 5900 -passwd $VNCPASS
Restart=always

[Install]
WantedBy=multi-user.target
EOF

cat > /etc/systemd/system/bamado-novnc.service <<EOF
[Unit]
Description=noVNC web viewer
After=bamado-vnc.service

[Service]
User=$APP_USER
ExecStart=/usr/bin/websockify --web /usr/share/novnc 127.0.0.1:6080 127.0.0.1:5900
Restart=always

[Install]
WantedBy=multi-user.target
EOF

echo "==> Configuring HTTPS (Caddy)"
cat > /etc/caddy/Caddyfile <<EOF
$DOMAIN {
	handle_path /$SECRET/vnc/* {
		reverse_proxy 127.0.0.1:6080
	}
	handle_path /$SECRET/* {
		reverse_proxy 127.0.0.1:8931 {
			flush_interval -1
		}
	}
	handle {
		respond 404
	}
}
EOF

systemctl daemon-reload
systemctl enable --now bamado-xvfb bamado-mcp bamado-vnc bamado-novnc
systemctl restart caddy

sleep 5
echo
echo "=============================================================="
echo " DONE. Send these two lines back to Claude (keep them private):"
echo
echo " Connector URL:  https://$DOMAIN/$SECRET/mcp"
echo " Login screen:   https://$DOMAIN/$SECRET/vnc/vnc.html?path=$SECRET/vnc/websockify&autoconnect=1&resize=scale"
echo " Screen password: $VNCPASS"
echo "=============================================================="
