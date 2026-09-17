#!/usr/bin/env bash
# Deploy a full Shoal node on a plain VPS, entirely from the console — no GUI.
# Zero-config: it auto-detects this VPS's public IP and uses the built-in seed
# nodes, so the usual case is just:
#
#   curl -fsSL https://raw.githubusercontent.com/monxley/shoal/main/deploy/install.sh | sudo bash
#
# Override anything if you need to:
#   PUBLIC_HOST  the address others reach this VPS at   (default: auto-detected)
#   BOOTSTRAP    an existing node's mix addr to join    (default: built-in seeds,
#                or self-seed if there are none)
#   MAILBOX_PORT (default 5077)   MIX_PORT (default 5078)   REPO   DATA_DIR
set -euo pipefail

# The project's built-in seed node. A fresh VPS joins it automatically; override
# with BOOTSTRAP= to point elsewhere, or BOOTSTRAP=" " (a space) to self-seed a
# brand-new independent network.
DEFAULT_BOOTSTRAP="135.181.125.178:5078"

MAILBOX_PORT="${MAILBOX_PORT:-5077}"
MIX_PORT="${MIX_PORT:-5078}"
DATA_DIR="${DATA_DIR:-/var/lib/shoal}"
REPO="${REPO:-https://github.com/monxley/shoal}"

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

# --- Migration from the Shoal name -------------------------------------------
#
# The project was renamed, and a node's identity lives in its data directory:
# relay_key, mix_key and the sealed mailbox. Creating the new directory and
# walking away would hand the node fresh keys, and to the rest of the network it
# would be a different node -- the old one simply gone, its queued mail with it.
#
# So the old directory is MOVED, never copied and never left behind to rot as a
# second source of truth. If anything is already at the new path we stop instead
# of merging two identities, because picking one silently is how a node ends up
# with a key that does not match the address it advertises.

migrate_from_aegis() {
  local old=/var/lib/aegis
  [ -d "$old" ] || return 0
  if [ -e "$DATA_DIR" ] && [ -n "$(ls -A "$DATA_DIR" 2>/dev/null)" ]; then
    echo "Both $old and $DATA_DIR exist and are non-empty." >&2
    echo "Refusing to guess which identity this node should keep. Move the one" >&2
    echo "you do not want aside, then re-run." >&2
    exit 1
  fi
  log "migrating the node's identity: $old -> $DATA_DIR"
  systemctl stop aegis-node 2>/dev/null || true
  systemctl disable aegis-node >/dev/null 2>&1 || true
  rm -f /etc/systemd/system/aegis-node.service
  systemctl daemon-reload 2>/dev/null || true
  mkdir -p "$(dirname "$DATA_DIR")"
  # `mv src dst` puts src INSIDE dst when dst already exists as a directory, so
  # an empty $DATA_DIR left behind by an earlier failed run would silently give
  # us /var/lib/shoal/aegis and a node that starts with no keys. rmdir only
  # succeeds on an empty directory, which is exactly the case we want to clear.
  rmdir "$DATA_DIR" 2>/dev/null || true
  mv "$old" "$DATA_DIR"
  chown -R shoal:shoal "$DATA_DIR" 2>/dev/null || true
  rm -f /usr/local/bin/aegis-relay-server
  log "the node keeps its keys and its queued mail; it is the same node to the network"
}

migrate_from_aegis_rootless() {
  local old="$HOME/.local/share/aegis"
  [ -d "$old" ] || return 0
  if [ -e "$DATA_DIR" ] && [ -n "$(ls -A "$DATA_DIR" 2>/dev/null)" ]; then
    echo "Both $old and $DATA_DIR exist and are non-empty; refusing to guess." >&2
    exit 1
  fi
  log "migrating the node's identity: $old -> $DATA_DIR"
  systemctl --user stop aegis-node 2>/dev/null || true
  systemctl --user disable aegis-node >/dev/null 2>&1 || true
  rm -f "$HOME/.config/systemd/user/aegis-node.service"
  systemctl --user daemon-reload 2>/dev/null || true
  pkill -f aegis-relay-server >/dev/null 2>&1 || true
  mkdir -p "$(dirname "$DATA_DIR")"
  rmdir "$DATA_DIR" 2>/dev/null || true   # see the note above
  mv "$old" "$DATA_DIR"
  rm -f "$HOME/.local/bin/aegis-relay-server"
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

# 2. Build the node binary — ALWAYS from a fresh clone of the repo. Reusing a
#    checkout in $PWD (the old behaviour) silently deployed whatever stale code
#    happened to be there, so a re-deploy could ship an old binary while looking
#    like it updated. (To build a local working tree instead, run
#    `cargo build --release -p shoal-relay-server` yourself.)
WORK="$(mktemp -d)"
log "cloning $REPO (fresh, so the deployed node is always current)"
git clone --depth 1 "$REPO" "$WORK/src"
SRC="$WORK/src"
log "building shoal-relay-server @ $(cd "$SRC" && git rev-parse --short HEAD) (a few minutes)"
# Regenerate the lock file with THIS cargo, so an unexpected version mismatch
# can never block the build.
rm -f "$SRC/Cargo.lock"
( cd "$SRC" && "$CARGO" build --release -p shoal-relay-server )
BIN="$SRC/target/release/shoal-relay-server"

# 3. Install + run. Root → system-wide + system systemd; non-root → under $HOME
#    with a user systemd service (no root needed).
BOOT_ARG=""
[ -n "$BOOTSTRAP" ] && BOOT_ARG="--bootstrap $BOOTSTRAP"

if [ "$(id -u)" -eq 0 ]; then
  install -m 0755 "$BIN" /usr/local/bin/shoal-relay-server
  id shoal >/dev/null 2>&1 || useradd -r -s /usr/sbin/nologin shoal
  migrate_from_aegis
  mkdir -p "$DATA_DIR"; chown -R shoal:shoal "$DATA_DIR"
  log "installing system service"
  cat > /etc/systemd/system/shoal-node.service <<UNIT
[Unit]
Description=Shoal node (blind mailbox + mixnet)
After=network-online.target
Wants=network-online.target

[Service]
User=shoal
Group=shoal
ExecStart=/usr/local/bin/shoal-relay-server \\
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
  systemctl enable shoal-node >/dev/null 2>&1 || true
  systemctl restart shoal-node          # restart, so a re-run picks up the new binary
  LOGS="journalctl -u shoal-node -f"
else
  log "no root — installing under \$HOME (rootless)"
  BIN_DIR="$HOME/.local/bin"; DATA_DIR="$HOME/.local/share/shoal"
  migrate_from_aegis_rootless
  mkdir -p "$BIN_DIR" "$DATA_DIR" "$HOME/.config/systemd/user"
  install -m 0755 "$BIN" "$BIN_DIR/shoal-relay-server"
  RUN_CMD="$BIN_DIR/shoal-relay-server --listen 0.0.0.0:${MAILBOX_PORT} --mix 0.0.0.0:${MIX_PORT} --data ${DATA_DIR} --advertise-mix ${PUBLIC_HOST}:${MIX_PORT} --advertise-provider ${PUBLIC_HOST}:${MAILBOX_PORT} ${BOOT_ARG}"
  if systemctl --user show-environment >/dev/null 2>&1; then
    log "installing user service"
    cat > "$HOME/.config/systemd/user/shoal-node.service" <<UNIT
[Unit]
Description=Shoal node (blind mailbox + mixnet)

[Service]
ExecStart=${RUN_CMD}
Restart=on-failure
RestartSec=5

[Install]
WantedBy=default.target
UNIT
    systemctl --user daemon-reload
    systemctl --user enable shoal-node >/dev/null 2>&1 || true
    systemctl --user restart shoal-node   # restart, so a re-run picks up the new binary
    loginctl enable-linger "$USER" >/dev/null 2>&1 || \
      echo "  (run 'loginctl enable-linger $USER' so it survives logout)"
    LOGS="journalctl --user -u shoal-node -f"
  else
    log "no user systemd — starting in the background with nohup"
    # Stop a previous instance first, or it keeps the old binary and holds the
    # ports (the new process would fail to bind).
    pkill -f shoal-relay-server >/dev/null 2>&1 && { log "stopped the previous node"; sleep 1; } || true
    nohup $RUN_CMD >"$DATA_DIR/shoal-node.log" 2>&1 &
    echo "  to run it again later: $RUN_CMD"
    LOGS="tail -f $DATA_DIR/shoal-node.log"
  fi
fi
rm -rf "$WORK"

log "Shoal node is up."
echo "  mailbox : ${PUBLIC_HOST}:${MAILBOX_PORT}"
echo "  mix     : ${PUBLIC_HOST}:${MIX_PORT}   (bootstrap clients/nodes here)"
echo "  open ports ${MAILBOX_PORT} and ${MIX_PORT} in your firewall."
echo "  logs: ${LOGS}"
