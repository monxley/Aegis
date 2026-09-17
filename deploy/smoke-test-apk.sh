#!/usr/bin/env bash
# Install the built APK on a running emulator and prove the app actually starts.
#
#   deploy/smoke-test-apk.sh path/to/app-release.apk
#
# Everything CI checked before this read the APK as a *file*: the package name,
# the permissions, the ABIs, the signing certificate, the page alignment. None
# of that can tell you whether the thing runs. The app has failed at exactly
# that point before -- a missing `mod frb_generated;` builds a perfectly valid
# APK whose native library aborts on load with "undefined symbol:
# frb_get_rust_content_hash" -- and a green build said nothing about it.
#
# So this installs it and launches it, and fails the build if:
#   - the installer refuses it (and prints the INSTALL_FAILED_* reason, which is
#     the thing a phone's installer never shows you),
#   - the process is gone after launch,
#   - no activity of ours is resumed (it started but put nothing on screen),
#   - or logcat carries a fatal exception, an UnsatisfiedLinkError or a dlopen
#     failure from our package.
#
# It runs against an x86_64 emulator, so it exercises the x86_64 slice of the
# APK. That is the same Dart, the same Rust and the same startup path as arm64;
# what it does NOT cover is anything architecture-specific, including how a real
# 16 KB-page device loads these libraries -- the alignment check in ci.yml reads
# that off the file instead.
set -euo pipefail

APK="${1:?usage: smoke-test-apk.sh <path to apk>}"
PKG="${SHOAL_APPLICATION_ID:-io.github.monxley.shoal}"
SETTLE="${SETTLE:-25}"          # seconds to let it boot, load the engine, draw

say() { printf '\n\033[36m==>\033[0m %s\n' "$*"; }
fail() { printf '\n\033[31m!!\033[0m %s\n' "$*" >&2; exit 1; }

[ -f "$APK" ] || fail "no such APK: $APK"

say "waiting for the emulator"
adb wait-for-device
# `wait-for-device` returns as soon as adb can talk to it, which is well before
# the framework is up; installing then fails in ways that look like the APK's
# fault.
adb shell 'while [ "$(getprop sys.boot_completed)" != "1" ]; do sleep 1; done'
adb shell getprop ro.build.version.release
adb shell getprop ro.product.cpu.abi

# A leftover install from an earlier attempt would make this a *reinstall*, and
# reinstalls take paths a first install does not. Fresh every time.
adb uninstall "$PKG" >/dev/null 2>&1 || true

say "installing $(basename "$APK")"
# Not swallowed: INSTALL_FAILED_* is the single most useful line in this script
# when it goes wrong, and it is exactly what "Приложение не установлено" hides.
if ! adb install -r -d "$APK"; then
  fail "the installer refused this APK -- the INSTALL_FAILED_* reason is above."
fi

# Ask the device which component the launcher would start rather than assuming
# MainActivity: the disguise feature ships activity-aliases, and which alias is
# enabled decides what actually launches.
COMPONENT="$(adb shell cmd package resolve-activity --brief \
  -c android.intent.category.LAUNCHER "$PKG" 2>/dev/null | tail -1 | tr -d '\r')"
case "$COMPONENT" in
  "$PKG"/*) : ;;
  *) fail "no launcher activity resolved for $PKG (got: '${COMPONENT:-nothing}').
     The app would install and then not appear in the launcher at all." ;;
esac

# A freshly booted emulator can come up behind the keyguard, and an activity
# started behind it never reaches the resumed state -- which this script would
# then report as the app failing to draw.
adb shell wm dismiss-keyguard >/dev/null 2>&1 || true

adb logcat -c || true
say "launching $COMPONENT"
adb shell am start -W -n "$COMPONENT"

say "letting it settle for ${SETTLE}s"
sleep "$SETTLE"

adb logcat -d > logcat.txt 2>/dev/null || true
adb exec-out screencap -p > screen.png 2>/dev/null || true

# --- Did it survive? ---------------------------------------------------------

say "checking the app is still alive"
if ! adb shell pidof "$PKG" >/dev/null 2>&1; then
  echo "--- last 200 lines of logcat ---"
  tail -200 logcat.txt || true
  fail "the process is gone ${SETTLE}s after launch: it started and died."
fi

# Alive is not the same as showing anything -- a process can survive with its
# first frame never drawn. A resumed activity of ours means the app is actually
# on screen.
say "checking one of our activities is on screen"
resumed="$(adb shell dumpsys activity activities 2>/dev/null \
  | grep -E 'mResumedActivity|ResumedActivity:' | head -3 | tr -d '\r')"
echo "$resumed"
case "$resumed" in
  *"$PKG"*) ;;
  *) echo "--- last 200 lines of logcat ---"
     tail -200 logcat.txt || true
     fail "the process is running but no activity of $PKG is resumed: it
     launched without putting anything on screen." ;;
esac

# --- Did it complain on the way? ---------------------------------------------

say "scanning logcat for fatal errors"
# Deliberately narrow. logcat on a booting emulator is full of other packages'
# noise, and a check that fires on someone else's warning is a check people
# learn to ignore.
patterns='FATAL EXCEPTION|UnsatisfiedLinkError|dlopen failed|undefined symbol|frb_get_rust_content_hash'
if grep -nE "$patterns" logcat.txt | grep -vE 'com\.android\.|com\.google\.android\.' > fatal.txt; then
  echo "--- what logcat said ---"
  cat fatal.txt
  echo
  # The Dart side of a Flutter crash is logged separately from the Java trace,
  # and it is usually the half that names the actual cause.
  grep -nE 'E/flutter|E/AndroidRuntime' logcat.txt | head -40 || true
  fail "the app logged a fatal error on startup (see above)."
fi

# Not a failure, but worth seeing: Dart-level exceptions that the app caught
# and carried on from still mean something on the startup path is broken.
if grep -qE 'E/flutter' logcat.txt; then
  say "non-fatal Dart errors were logged (the app kept running):"
  grep -E 'E/flutter' logcat.txt | head -20 || true
fi

say "OK: $PKG installed, launched, drew a screen and is still running."
