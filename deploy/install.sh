#!/usr/bin/env bash
# Deploy a full Aegis node on a plain VPS, entirely from the console — no GUI.
#
#   curl -fsSL https://raw.githubusercontent.com/monxley/Aegis/main/deploy/install.sh | \
#     sudo PUBLIC_HOST=your.host BOOTSTRAP=seed.example:5078 bash
#
# or, from a checkout:
#   sudo PUBLIC_HOST=your.host BOOTSTRAP=seed.example:5078 deploy/install.sh
#
# Env vars:
#   PUBLIC_HOST  (required) the address other nodes/clients reach this VPS at
#   BOOTSTRAP    (optional) an existing node's mix addr to join; omit for the
#                first seed node of a new network
#   MAILBOX_PORT (default 5077)   MIX_PORT (default 5078)   REPO (default the
#   monxley/Aegis GitHub repo)    DATA_DIR (default /var/lib/aegis)
set -euo pipefail

PUBLIC_HOST="${PUBLIC_HOST:?set PUBLIC_HOST to the address clients reach this VPS at}"
BOOTSTRAP="${BOOTSTRAP:-}"
MAILBOX_PORT="${MAILBOX_PORT:-5077}"
MIX_PORT="${MIX_PORT:-5078}"
DATA_DIR="${DATA_DIR:-/var/lib/aegis}"
REPO="${REPO:-https://github.com/monxley/Aegis}"

log() { printf '\033[36m==>\033[0m %s\n' "$*"; }

if [ "$(id -u)" -ne 0 ]; then
  echo "run as root (sudo)"; exit 1
fi

# 1. Toolchain: install Rust if cargo is absent.
if ! command -v cargo >/dev/null 2>&1; then
  log "installing Rust toolchain"
  curl -fsSL https://sh.rustup.rs | sh -s -- -y --profile minimal
  # shellcheck disable=SC1091
  . "$HOME/.cargo/env"
fi

# 2. Build the node binary.
WORK="$(mktemp -d)"
log "building aegis-relay-server (this takes a few minutes)"
if [ -f "Cargo.toml" ] && grep -q "aegis-relay-server" Cargo.toml 2>/dev/null; then
  SRC="$PWD"
else
  git clone --depth 1 "$REPO" "$WORK/src"
  SRC="$WORK/src"
fi
( cd "$SRC" && cargo build --release -p aegis-relay-server )
install -m 0755 "$SRC/target/release/aegis-relay-server" /usr/local/bin/aegis-relay-server

# 3. Service user + data dir.
id aegis >/dev/null 2>&1 || useradd -r -s /usr/sbin/nologin aegis
mkdir -p "$DATA_DIR"
chown aegis:aegis "$DATA_DIR"

# 4. systemd unit.
BOOT_ARG=""
[ -n "$BOOTSTRAP" ] && BOOT_ARG="--bootstrap $BOOTSTRAP"
log "installing systemd service"
cat > /etc/systemd/system/aegis-node.service <<UNIT
[Unit]
Description=Aegis node (blind mailbox + mixnet)
After=network-online.target
Wants=network-online.target

[Service]
User=aegis
Group=aegis
ExecStart=/usr/local/bin/aegis-relay-server \\
  --listen 0.0.0.0:${MAILBOX_PORT} --mix 0.0.0.0:${MIX_PORT} --data ${DATA_DIR} \\
  --advertise-mix ${PUBLIC_HOST}:${MIX_PORT} \\
  --advertise-provider ${PUBLIC_HOST}:${MAILBOX_PORT} ${BOOT_ARG}
Restart=on-failure
RestartSec=5
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=${DATA_DIR}
PrivateTmp=true

[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload
systemctl enable --now aegis-node
rm -rf "$WORK"

log "Aegis node is up."
echo "  mailbox : ${PUBLIC_HOST}:${MAILBOX_PORT}"
echo "  mix     : ${PUBLIC_HOST}:${MIX_PORT}   (bootstrap clients/nodes here)"
echo "  open ports ${MAILBOX_PORT} and ${MIX_PORT} in your firewall."
echo "  logs: journalctl -u aegis-node -f"
