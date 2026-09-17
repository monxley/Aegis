#!/usr/bin/env bash
# Give back the disk that deploy/build-apk.sh took, and leave the node running.
#
#   curl -fsSL https://raw.githubusercontent.com/monxley/Aegis/main/deploy/clean-build-toolchain.sh | bash
#
# build-apk.sh downloads about 10 GB of Android toolchain -- NDK, Flutter SDK,
# Gradle, the Android SDK, a JDK, a pub cache -- and leaves all of it under
# $HOME so a second build is fast. On a VPS that is running a node and nothing
# else, that is 10 GB of a disk that probably only has 20, and none of it is
# needed once the APK is off the box. This removes it.
#
# WHAT IT WILL NOT TOUCH, and checks before every delete:
#
#   the node binary        /usr/local/bin/shoal-relay-server
#                          (or ~/.local/bin/shoal-relay-server)
#   the node's data dir    /var/lib/shoal  (or ~/.local/share/shoal)
#                          -- the relay key, the mix key and every queued
#                          envelope. Deleting it makes this node a stranger to
#                          the network and loses undelivered mail.
#   the systemd unit       /etc/systemd/system/shoal-node.service
#                          (or ~/.config/systemd/user/shoal-node.service)
#
# Everything it does remove is downloadable again: re-running build-apk.sh
# rebuilds the whole toolchain from scratch.
#
#   DRY_RUN=1    list what would go, with sizes, and delete nothing
#   PURGE_RUST=1 also remove ~/.cargo and ~/.rustup entirely. Off by default
#                because install.sh needs cargo to update the node, and
#                re-downloading the toolchain is ~400 MB. Either way the
#                Android cross-compile targets (~600 MB) are removed.
set -euo pipefail

DRY_RUN="${DRY_RUN:-0}"
PURGE_RUST="${PURGE_RUST:-0}"

log()  { printf '\033[36m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[33m!!\033[0m %s\n' "$*" >&2; }

# --- 1. Find the node, so the report says what is being protected ------------

NODE_BIN=""; NODE_DATA=""; NODE_UNIT=""; NODE_HOW="not found"
if [ -x /usr/local/bin/shoal-relay-server ]; then
  NODE_BIN=/usr/local/bin/shoal-relay-server
  NODE_DATA="${DATA_DIR:-/var/lib/shoal}"
  NODE_UNIT=/etc/systemd/system/shoal-node.service
  NODE_HOW="system (root install)"
elif [ -x "$HOME/.local/bin/shoal-relay-server" ]; then
  NODE_BIN="$HOME/.local/bin/shoal-relay-server"
  NODE_DATA="${DATA_DIR:-$HOME/.local/share/shoal}"
  NODE_UNIT="$HOME/.config/systemd/user/shoal-node.service"
  NODE_HOW="rootless (under \$HOME)"
fi

# The data dir named in the unit file wins over the guess above: an install with
# DATA_DIR= set elsewhere must be protected at the path it actually uses.
if [ -n "$NODE_UNIT" ] && [ -f "$NODE_UNIT" ]; then
  unit_data="$(grep -oE -- '--data[= ]+[^ \\]+' "$NODE_UNIT" | head -1 | sed -E 's/--data[= ]+//')" || true
  [ -n "${unit_data:-}" ] && NODE_DATA="$unit_data"
fi

log "Shoal node: $NODE_HOW"
if [ -n "$NODE_BIN" ]; then
  echo "    binary : $NODE_BIN"
  echo "    data   : $NODE_DATA   (never touched by this script)"
  if systemctl is-active --quiet shoal-node 2>/dev/null; then
    echo "    status : running (system service)"
  elif systemctl --user is-active --quiet shoal-node 2>/dev/null; then
    echo "    status : running (user service)"
  elif pgrep -x shoal-relay-server >/dev/null 2>&1; then
    echo "    status : running (started directly, no systemd unit)"
  else
    warn "    status : NOT running -- this cleanup is not the cause, but check it"
    warn "             afterwards with: journalctl -u shoal-node -n 50 --no-pager"
  fi
else
  warn "No node found on this box. Nothing here will install one; this script"
  warn "only frees space. To install or update the node afterwards:"
  warn "  curl -fsSL https://raw.githubusercontent.com/monxley/Aegis/main/deploy/install.sh | sudo bash"
fi
echo

# --- 2. Refuse to remove anything the node depends on ------------------------

PROTECTED=()
for p in "$NODE_BIN" "$NODE_DATA" "$NODE_UNIT" /var/lib/shoal "$HOME/.local/share/shoal"; do
  [ -n "$p" ] && [ -e "$p" ] && PROTECTED+=("$(readlink -f "$p")")
done

# True if $1 is, or contains, anything in PROTECTED.
endangers_node() {
  local cand; cand="$(readlink -f "$1" 2>/dev/null || printf '%s' "$1")"
  # An empty or root path is always refused: a bad expansion above must not turn
  # into `rm -rf /`.
  if [ -z "$cand" ] || [ "$cand" = "/" ] || [ "$cand" = "$HOME" ]; then return 0; fi
  local p
  for p in ${PROTECTED[@]+"${PROTECTED[@]}"}; do
    case "$p/" in "$cand"/*) return 0 ;; esac
    [ "$p" = "$cand" ] && return 0
  done
  return 1
}

# --- 3. What build-apk.sh leaves behind --------------------------------------

CANDIDATES=(
  "${WORK:-$HOME/shoal-build}"                       # the build's fresh clone + build output
  "${ANDROID_SDK_ROOT:-$HOME/android-sdk}"           # SDK + NDK: the single biggest item
  "${FLUTTER_DIR:-$HOME/flutter}"                    # Flutter SDK + downloaded engine artifacts
  "$HOME/.gradle"                                    # Gradle distribution + build caches
  "$HOME/.pub-cache"                                 # Dart package cache
  "$HOME/jdk"                                        # only present if build-apk.sh installed one
)
[ "$PURGE_RUST" = "1" ] && CANDIDATES+=( "$HOME/.cargo" "$HOME/.rustup" )

# A half-finished install.sh run leaves its clone and its target/ dir in /tmp.
# Matched by content, not by name, so this cannot wander into someone else's
# temporary directory.
for d in /tmp/tmp.*/src; do
  [ -d "$d" ] || continue
  grep -qs 'shoal-relay-server' "$d/Cargo.toml" && CANDIDATES+=( "${d%/src}" )
done

log "measuring (this reads every file, so give it a moment)"
TOTAL_MB=0
DOOMED=()
for c in "${CANDIDATES[@]}"; do
  [ -e "$c" ] || continue
  if endangers_node "$c"; then
    warn "skipping $c -- it holds or is part of the node"
    continue
  fi
  mb="$(du -sm -- "$c" 2>/dev/null | cut -f1)"; mb="${mb:-0}"
  printf '    %8s MB  %s\n' "$mb" "$c"
  TOTAL_MB=$(( TOTAL_MB + mb ))
  DOOMED+=("$c")
done

if [ "${#DOOMED[@]}" -eq 0 ]; then
  echo
  log "Nothing to remove -- no Android build toolchain on this box."
  df -h "$HOME" | tail -1 | awk '{print "    " $4 " free on " $6}'
  exit 0
fi

echo
log "total to free: ~$(( TOTAL_MB / 1024 )) GB (${TOTAL_MB} MB)"

if [ "$DRY_RUN" = "1" ]; then
  echo
  log "DRY_RUN=1 -- nothing was deleted. Re-run without it to free the space."
  exit 0
fi

# --- 4. Remove it ------------------------------------------------------------

echo
for c in "${DOOMED[@]}"; do
  # Re-checked immediately before the delete, not only when the list was built.
  if endangers_node "$c"; then warn "skipping $c (protected)"; continue; fi
  log "removing $c"
  rm -rf -- "$c"
done

# Rust: keep the toolchain that install.sh needs, drop what only the APK build
# used -- three Android std targets, the two cargo tools, and the download
# caches. Roughly 600 MB, without making a node update re-download rustup.
if [ "$PURGE_RUST" != "1" ] && [ -x "$HOME/.cargo/bin/rustup" ]; then
  log "removing the Android Rust targets and APK-only cargo tools"
  "$HOME/.cargo/bin/rustup" target remove \
    aarch64-linux-android armv7-linux-androideabi x86_64-linux-android >/dev/null 2>&1 || true
  rm -f "$HOME/.cargo/bin/cargo-ndk" "$HOME/.cargo/bin/flutter_rust_bridge_codegen"
  # Shoal itself has no third-party crates, so this cache only ever held the
  # dependencies of those two tools. install.sh does not need it.
  rm -rf "$HOME/.cargo/registry" "$HOME/.cargo/git"
fi

# --- 5. Say where that left the box ------------------------------------------

echo
log "Done."
df -h "$HOME" | tail -1 | awk '{print "    " $4 " free on " $6 " (" $5 " used)"}'

if [ -n "$NODE_BIN" ]; then
  echo
  if systemctl is-active --quiet shoal-node 2>/dev/null || \
     systemctl --user is-active --quiet shoal-node 2>/dev/null || \
     pgrep -x shoal-relay-server >/dev/null 2>&1; then
    log "The node is still running, on the same identity and the same stored mail."
  else
    warn "The node is not running. It was not removed -- start it with:"
    warn "  systemctl start shoal-node      (or: systemctl --user start shoal-node)"
  fi
fi

cat <<'EOF'

If the disk is still fuller than it should be, these are the usual culprits on
a box like this -- check them, do not run them blind:

  journalctl --disk-usage           # then: journalctl --vacuum-size=200M
  docker system df                  # Docker layers, IF you use Docker here.
                                    # Do NOT `docker system prune -a` while a
                                    # node runs in a container: it deletes the
                                    # image out from under it.
  du -xh -d1 / 2>/dev/null | sort -h | tail -20      # what is actually large

To build an APK again later, run deploy/build-apk.sh -- it reinstalls
everything removed here. Better: let CI build it, and keep the VPS for the node.
EOF
