#!/usr/bin/env bash
# Guard the three renames that break things silently.
#
#   bash deploy/check-names.sh
#
# Renaming a project is mostly harmless string replacement, with a few places
# where a wrong string produces no error at all -- it just makes a feature stop
# working, or points at something that does not exist. Every check below exists
# because that already happened during this rename, twice for the first one.
set -euo pipefail

cd "$(dirname "$0")/.."
fail=0
note() { printf '\033[31m!!\033[0m %s\n' "$*" >&2; fail=1; }
ok()   { printf '   ok  %s\n' "$*"; }

# --- 1. The GitHub repository slug -------------------------------------------
#
# The in-app updater asks GitHub for releases by `owner/repo`. Rename that
# string and the update check queries a repository that does not exist: no
# error, no update offered, ever. A blanket product rename hits it every time,
# because the repository keeps its own name until someone renames it on GitHub.
slug_wrong=$(grep -rn "monxley/Shoal" --exclude-dir=.git --exclude-dir=target \
  --exclude-dir=.dart_tool --exclude-dir=build \
  --exclude=check-names.sh . 2>/dev/null || true)
if [ -n "$slug_wrong" ]; then
  note "the GitHub repository is monxley/Aegis, but these point at monxley/Shoal:"
  printf '%s\n' "$slug_wrong" >&2
else
  ok "every GitHub URL points at the repository that exists"
fi

# --- 2. Method channels, both sides ------------------------------------------
#
# Dart and Kotlin agree on these strings by convention only. Rename one side and
# FLAG_SECURE, the background service and the disguise toggle all become no-ops
# that raise nothing and log nothing.
dart_ch=$(grep -rhoE "MethodChannel\('[^']+'\)" app/lib --include=*.dart 2>/dev/null \
  | sed "s/MethodChannel('//; s/')//" | sort -u)
kot_ch=$(grep -hoE '"[a-z_]+/[a-z_]+"' deploy/prepare-android-project.sh 2>/dev/null \
  | tr -d '"' | sort -u)
for c in $dart_ch; do
  if printf '%s\n' "$kot_ch" | grep -qx "$c"; then
    ok "channel $c exists on both sides"
  else
    note "Dart uses MethodChannel('$c') but the Android side never names it"
  fi
done

# --- 3. The share-code prefix ------------------------------------------------
#
# Rust mints the ID and Dart parses it. If the two disagree, every code a user
# pastes is rejected as malformed -- which reads as "their code is broken",
# not as "the two halves of our own app disagree".
rust_prefix=$(grep -rhoE '"[a-z]+:"' crates/shoal-identity/src/*.rs 2>/dev/null | head -1 | tr -d '"')
dart_prefix=$(grep -rhoE "startsWith\('[a-z]+:'\)" app/lib/share.dart 2>/dev/null \
  | sed "s/startsWith('//; s/')//" | head -1)
if [ -n "$rust_prefix" ] && [ "$rust_prefix" = "$dart_prefix" ]; then
  ok "share-code prefix agrees: $rust_prefix"
elif [ -z "$rust_prefix" ] || [ -z "$dart_prefix" ]; then
  note "could not read the share-code prefix from both sides (rust='$rust_prefix' dart='$dart_prefix')"
else
  note "share-code prefix disagrees: Rust mints '$rust_prefix', Dart accepts '$dart_prefix'"
fi

# --- 4. Nothing calls itself by the old name ---------------------------------
#
# Deliberate exceptions, each for a reason: the repository keeps its name until
# it is renamed on GitHub, the published v0.3.0 tag is history, the mix node's
# log lines are protocol-level, and the social accounts are real and live.
stragglers=$(grep -rni "aegis" --exclude-dir=.git --exclude-dir=target \
  --exclude-dir=.dart_tool --exclude-dir=build --exclude-dir=fdroid . 2>/dev/null \
  | grep -viE "monxley/Aegis|monxley.github.io/Aegis|V0\.3\.0-Aegis|aegis: (delivery|DELIVERY)|t\.me/aegis_private|instagram\.com/aegis\.private|check-names\.sh" || true)
if [ -n "$stragglers" ]; then
  note "the old name survives in $(printf '%s\n' "$stragglers" | wc -l) place(s):"
  printf '%s\n' "$stragglers" | head -20 >&2
else
  ok "no unexplained mention of the old name"
fi

echo
[ "$fail" -eq 0 ] && echo "names are consistent" || echo "name checks failed" >&2
exit "$fail"
