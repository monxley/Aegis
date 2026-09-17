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
# The in-app updater asks GitHub for releases by `owner/repo`. Point that string
# at a repository that does not exist and the update check quietly returns
# nothing: no error, no update offered, ever.
#
# This check has been inverted once already. While the product was renamed but
# the repository was not, the correct slug was the OLD one, and writing the new
# name here broke the updater twice. The repository is now monxley/shoal, so the
# old name is the wrong one -- GitHub redirects it, which is exactly why nothing
# would look broken until the redirect went away.
slug_wrong=$(grep -rn "monxley/Aegis\|monxley\.github\.io/Aegis" \
  --exclude-dir=.git --exclude-dir=target \
  --exclude-dir=.dart_tool --exclude-dir=build \
  --exclude=check-names.sh . 2>/dev/null || true)
if [ -n "$slug_wrong" ]; then
  note "the GitHub repository is monxley/shoal, but these still say monxley/Aegis:"
  printf '%s\n' "$slug_wrong" >&2
else
  ok "every GitHub URL points at the repository that exists"
fi

# The updater's slug is the one that fails silently, so assert it by name rather
# than trusting the sweep above to have covered it.
upd=$(grep -hoE "repo = '[^']+'" app/lib/updater.dart 2>/dev/null | sed "s/repo = '//; s/'//")
if [ "$upd" = "monxley/shoal" ]; then
  ok "the updater queries $upd"
else
  note "the updater queries '$upd', which is not monxley/shoal"
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
# Deliberate exceptions, each for a reason: the published v0.3.0 tag is history
# and cannot be rewritten, the mix node's log lines are protocol-level, and the
# social accounts are real and live until they are renamed by hand.
stragglers=$(grep -rni "aegis" --exclude-dir=.git --exclude-dir=target \
  --exclude-dir=.dart_tool --exclude-dir=build --exclude-dir=fdroid . 2>/dev/null \
  | grep -viE "V0\.3\.0-Aegis|aegis: (delivery|DELIVERY)|t\.me/aegis_private|instagram\.com/aegis\.private|check-names\.sh" || true)
if [ -n "$stragglers" ]; then
  note "the old name survives in $(printf '%s\n' "$stragglers" | wc -l) place(s):"
  printf '%s\n' "$stragglers" | head -20 >&2
else
  ok "no unexplained mention of the old name"
fi

# --- 5. Asset paths ----------------------------------------------------------
#
# Flutter resolves `Image.asset` at *runtime*. A renamed or mistyped asset path
# compiles, ships, and then throws when the screen that uses it is opened --
# which during a rename is every brand image at once. Check that each path a
# Dart file names exists, and that pubspec still declares its directory.
missing=0
while read -r ref; do
  [ -z "$ref" ] && continue
  if [ ! -f "app/$ref" ]; then
    note "Dart asks for app/$ref, which does not exist"
    missing=1
  fi
done <<EOF
$(grep -rhoE "'assets/[A-Za-z0-9_/.-]+\.(png|jpg|svg|webp)'" app/lib --include=*.dart 2>/dev/null \
  | tr -d "'" | sort -u)
EOF
[ "$missing" -eq 0 ] && ok "every asset a Dart file names is present"

for d in $(grep -rhoE "^ *- assets/[a-z_]+/" app/pubspec.yaml | sed 's/^ *- //'); do
  [ -d "app/$d" ] || note "pubspec declares assets dir $d, which does not exist"
done

# The launcher icons are read by flutter_launcher_icons, not by Dart, so the
# check above never sees them.
for k in image_path adaptive_icon_foreground; do
  v=$(grep -hoE "^ *$k: *\"[^\"]+\"" app/pubspec.yaml | head -1 | sed 's/.*"\(.*\)"/\1/')
  if [ -n "$v" ] && [ ! -f "app/$v" ]; then
    note "pubspec $k points at app/$v, which does not exist"
  elif [ -n "$v" ]; then
    ok "launcher $k -> $v"
  fi
done

echo
[ "$fail" -eq 0 ] && echo "names are consistent" || echo "name checks failed" >&2
exit "$fail"
