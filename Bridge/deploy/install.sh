#!/usr/bin/env bash
# Install the Hermes bridge on the host that already runs Hermes.
#
#   sudo ./install.sh
#
# What it does, and why each step exists:
#   1. a dedicated unprivileged user — the bridge never needs root, and a compromise of it
#      must not be a compromise of the Hermes home
#   2. a 0600 env file holding the *gateway* token the bridge uses to reach the local gateway
#   3. a systemd unit bound to loopback only
#   4. `tailscale serve` for TLS + tailnet exposure, so there is no public listener at all
#
# The gateway the bridge talks to is a Hermes dashboard bound to loopback:
#      hermes dashboard --port 9120 --host 127.0.0.1
# with HERMES_DASHBOARD_SESSION_TOKEN set to the same value as GATEWAY_TOKEN below. Hermes
# accepts that token on a loopback WS upgrade; on any other bind it refuses it, which is why
# the dashboard must stay on 127.0.0.1 and tailscale serve must be the only front door.
set -euo pipefail

BRIDGE_HOME=${BRIDGE_HOME:-/opt/hermes-apps/Bridge}
STATE_DIR=${STATE_DIR:-/var/lib/hermes-bridge}
CONF_DIR=/etc/hermes-bridge
SERVICE_USER=${SERVICE_USER:-hermes-bridge}
TAILNET_PORT=${TAILNET_PORT:-8443}

if [ "$(id -u)" -ne 0 ]; then echo "run as root" >&2; exit 1; fi

id -u "$SERVICE_USER" >/dev/null 2>&1 || useradd --system --home "$STATE_DIR" --shell /usr/sbin/nologin "$SERVICE_USER"
install -d -m 0750 -o "$SERVICE_USER" -g "$SERVICE_USER" "$STATE_DIR"
install -d -m 0750 "$CONF_DIR"

if [ ! -f "$CONF_DIR/bridge.env" ]; then
  TOKEN=$(head -c 32 /dev/urandom | base64 | tr -d '\n/+=' | cut -c1-43)
  cat > "$CONF_DIR/bridge.env" <<EOF
# 127.0.0.1 only. Anything else is refused at startup on purpose.
HERMES_BRIDGE_HOST=127.0.0.1
HERMES_BRIDGE_PORT=8787
HERMES_BRIDGE_DB=$STATE_DIR/bridge.db
# The local Hermes gateway (dashboard) this bridge relays to.
HERMES_BRIDGE_GATEWAY_URL=ws://127.0.0.1:9120/api/ws
HERMES_BRIDGE_GATEWAY_TOKEN=$TOKEN
EOF
  chmod 0600 "$CONF_DIR/bridge.env"
  echo "wrote $CONF_DIR/bridge.env with a fresh gateway token"
  echo "start the gateway with the same value:"
  echo "  HERMES_DASHBOARD_SESSION_TOKEN=$TOKEN hermes dashboard --port 9120 --host 127.0.0.1"
fi

install -m 0644 "$BRIDGE_HOME/deploy/hermes-bridge.service" /etc/systemd/system/hermes-bridge.service
systemctl daemon-reload
systemctl enable --now hermes-bridge.service
systemctl --no-pager --lines=5 status hermes-bridge.service || true

echo
echo "Now expose it to the tailnet (TLS from Let's Encrypt via Tailscale, no public port):"
echo "  tailscale serve --bg --https=$TAILNET_PORT http://127.0.0.1:8787"
echo "  tailscale serve status"
echo
echo "Then pair the first device from this host:"
echo "  curl -s -X POST http://127.0.0.1:8787/v1/pair/start | jq"
