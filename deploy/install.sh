#!/usr/bin/env bash
# Deploy a full Aegis node on a plain VPS, entirely from the console — no GUI.
# Zero-config: it auto-detects this VPS's public IP and uses the built-in seed
# nodes, so the usual case is just:
#
#   curl -fsSL https://raw.githubusercontent.com/monxley/Aegis/main/deploy/install.sh | sudo bash
#
# Override anything if you need to:
#   PUBLIC_HOST  the address others reach this VPS at   (default: auto-detected)
#   BOOTSTRAP    an existing node's mix addr to join    (default: built-in seeds,
#                or self-seed if there are none)
#   MAILBOX_PORT (default 5077)   MIX_PORT (default 5078)   REPO   DATA_DIR
set -euo pipefail

# The project's built-in seed nodes. A fresh VPS joins these automatically; the
# very first node of a brand-new network leaves this empty and self-seeds. Fill
# in real hosts here (or override with BOOTSTRAP=) once seeds are running.
DEFAULT_BOOTSTRAP=""

MAILBOX_PORT="${MAILBOX_PORT:-5077}"
MIX_PORT="${MIX_PORT:-5078}"
DATA_DIR="${DATA_DIR:-/var/lib/aegis}"
REPO="${REPO:-https://github.com/monxley/Aegis}"

log() { printf '\033[36m==>\033[0m %s\n' "$*"; }

# Auto-detect the public IP if PUBLIC_HOST wasn't given: ask a few IP echo
# services, then fall back to the default-route interface address.
detect_public_host() {
  local ip
  for url in https://api.ipify.org https://ifconfig.me https://icanhazip.com; do
    ip="$(curl -fsSL --max-time 5 "$url" 2>/dev/null | tr -d '[:space:]')" || true
    if printf '%s' "$ip" | grep -qE '^[0-9a-fA-F.:]+$'; then
      printf '%s' "$ip"; return 0
    fi
  done
  ip="$(ip -4 route get 1.1.1.1 2>/dev/null | grep -oE 'src [0-9.]+' | awk '{print $2}')" || true
  [ -n "$ip" ] && { printf '%s' "$ip"; return 0; }
  return 1
}

PUBLIC_HOST="${PUBLIC_HOST:-}"
if [ -z "$PUBLIC_HOST" ]; then
  log "detecting this VPS's public address"
  PUBLIC_HOST="$(detect_public_host)" || {
    echo "could not auto-detect a public address; set PUBLIC_HOST=your.host"; exit 1; }
  log "using PUBLIC_HOST=$PUBLIC_HOST"
fi
BOOTSTRAP="${BOOTSTRAP:-$DEFAULT_BOOTSTRAP}"

# 1. Toolchain: ensure a MODERN Rust via rustup. A distro-packaged `cargo` is
#    often too old to read the workspace lock file (lock version 4), so we key off
#    rustup's own binary and prefer it — never a system cargo.
if [ ! -x "$HOME/.cargo/bin/cargo" ]; then
  log "installing Rust toolchain (rustup)"
  curl -fsSL https://sh.rustup.rs | sh -s -- -y --profile minimal --default-toolchain stable
fi
# shellcheck disable=SC1091
[ -f "$HOME/.cargo/env" ] && . "$HOME/.cargo/env"
export PATH="$HOME/.cargo/bin:$PATH"
rustup default stable >/dev/null 2>&1 || true
CARGO="$HOME/.cargo/bin/cargo"
if [ ! -x "$CARGO" ]; then
  echo "Rust toolchain install failed; is curl to sh.rustup.rs blocked?"; exit 1
fi
log "using $("$CARGO" --version)"

# 2. Build the node binary.
WORK="$(mktemp -d)"
log "building aegis-relay-server (this takes a few minutes)"
if [ -f "Cargo.toml" ] && grep -q "aegis-relay-server" Cargo.toml 2>/dev/null; then
  SRC="$PWD"
else
  git clone --depth 1 "$REPO" "$WORK/src"
  SRC="$WORK/src"
fi
# Regenerate the lock file with THIS cargo, so an unexpected version mismatch
# can never block the build.
rm -f "$SRC/Cargo.lock"
( cd "$SRC" && "$CARGO" build --release -p aegis-relay-server )
BIN="$SRC/target/release/aegis-relay-server"

# 3. Install + run. Root → system-wide + system systemd; non-root → under $HOME
#    with a user systemd service (no root needed).
BOOT_ARG=""
[ -n "$BOOTSTRAP" ] && BOOT_ARG="--bootstrap $BOOTSTRAP"

if [ "$(id -u)" -eq 0 ]; then
  install -m 0755 "$BIN" /usr/local/bin/aegis-relay-server
  id aegis >/dev/null 2>&1 || useradd -r -s /usr/sbin/nologin aegis
  mkdir -p "$DATA_DIR"; chown aegis:aegis "$DATA_DIR"
  log "installing system service"
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
  LOGS="journalctl -u aegis-node -f"
else
  log "no root — installing under \$HOME (rootless)"
  BIN_DIR="$HOME/.local/bin"; DATA_DIR="$HOME/.local/share/aegis"
  mkdir -p "$BIN_DIR" "$DATA_DIR" "$HOME/.config/systemd/user"
  install -m 0755 "$BIN" "$BIN_DIR/aegis-relay-server"
  RUN_CMD="$BIN_DIR/aegis-relay-server --listen 0.0.0.0:${MAILBOX_PORT} --mix 0.0.0.0:${MIX_PORT} --data ${DATA_DIR} --advertise-mix ${PUBLIC_HOST}:${MIX_PORT} --advertise-provider ${PUBLIC_HOST}:${MAILBOX_PORT} ${BOOT_ARG}"
  if systemctl --user show-environment >/dev/null 2>&1; then
    log "installing user service"
    cat > "$HOME/.config/systemd/user/aegis-node.service" <<UNIT
[Unit]
Description=Aegis node (blind mailbox + mixnet)

[Service]
ExecStart=${RUN_CMD}
Restart=on-failure
RestartSec=5

[Install]
WantedBy=default.target
UNIT
    systemctl --user daemon-reload
    systemctl --user enable --now aegis-node
    loginctl enable-linger "$USER" >/dev/null 2>&1 || \
      echo "  (run 'loginctl enable-linger $USER' so it survives logout)"
    LOGS="journalctl --user -u aegis-node -f"
  else
    log "no user systemd — starting in the background with nohup"
    nohup $RUN_CMD >"$DATA_DIR/aegis-node.log" 2>&1 &
    echo "  to run it again later: $RUN_CMD"
    LOGS="tail -f $DATA_DIR/aegis-node.log"
  fi
fi
rm -rf "$WORK"

log "Aegis node is up."
echo "  mailbox : ${PUBLIC_HOST}:${MAILBOX_PORT}"
echo "  mix     : ${PUBLIC_HOST}:${MIX_PORT}   (bootstrap clients/nodes here)"
echo "  open ports ${MAILBOX_PORT} and ${MIX_PORT} in your firewall."
echo "  logs: ${LOGS}"
