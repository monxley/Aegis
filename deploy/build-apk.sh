#!/usr/bin/env bash
# Build the Aegis Android APK on a plain Linux VPS, entirely from the console
# (no GUI, no GitHub Actions). Made for a Debian/Ubuntu box you SSH into.
#
#   curl -fsSL https://raw.githubusercontent.com/monxley/Aegis/main/deploy/build-apk.sh | bash
#
# It installs a JDK, the Flutter SDK, the Android command-line SDK + NDK, and
# Rust, then builds an installable debug APK and tells you how to copy it to
# your phone. Everything lands under $HOME; nothing needs root except the one
# apt-get for the JDK (uses sudo if available).
#
# Needs ~8 GB free disk and ~2 GB RAM (add swap if the box is smaller — see the
# note printed at the end if the build is killed).
set -euo pipefail

REPO="${REPO:-https://github.com/monxley/Aegis}"
FLUTTER_DIR="${FLUTTER_DIR:-$HOME/flutter}"
SDK="${ANDROID_SDK_ROOT:-$HOME/android-sdk}"
NDK_VER="26.3.11579264"
PLATFORM="android-34"
BUILDTOOLS="34.0.0"
WORK="${WORK:-$HOME/aegis-build}"
FRB_VERSION="2.0.0"

log() { printf '\033[36m==>\033[0m %s\n' "$*"; }
have() { command -v "$1" >/dev/null 2>&1; }
SUDO=""; [ "$(id -u)" -ne 0 ] && have sudo && SUDO="sudo"

# 1. JDK + basic tools (the only thing needing apt).
if ! have java; then
  log "installing JDK + tools (apt)"
  $SUDO apt-get update -y
  $SUDO apt-get install -y openjdk-17-jdk-headless git curl unzip xz-utils
fi
export JAVA_HOME="${JAVA_HOME:-$(dirname "$(dirname "$(readlink -f "$(command -v java)")")")}"

# 2. Rust + Android targets + tooling.
if [ ! -x "$HOME/.cargo/bin/cargo" ]; then
  log "installing Rust (rustup)"
  curl -fsSL https://sh.rustup.rs | sh -s -- -y --profile minimal --default-toolchain stable
fi
# shellcheck disable=SC1091
. "$HOME/.cargo/env"
rustup target add aarch64-linux-android armv7-linux-androideabi x86_64-linux-android >/dev/null
have cargo-ndk || { log "installing cargo-ndk"; cargo install cargo-ndk; }
[ -x "$HOME/.cargo/bin/flutter_rust_bridge_codegen" ] || \
  { log "installing flutter_rust_bridge_codegen"; cargo install flutter_rust_bridge_codegen --version "$FRB_VERSION" --locked; }

# 3. Flutter SDK.
if [ ! -x "$FLUTTER_DIR/bin/flutter" ]; then
  log "cloning Flutter (stable)"
  git clone --depth 1 -b stable https://github.com/flutter/flutter "$FLUTTER_DIR"
fi
export PATH="$FLUTTER_DIR/bin:$HOME/.cargo/bin:$PATH"
git config --global --add safe.directory "$FLUTTER_DIR" 2>/dev/null || true

# 4. Android command-line SDK + platform + build-tools + NDK.
export ANDROID_SDK_ROOT="$SDK"
if [ ! -x "$SDK/cmdline-tools/latest/bin/sdkmanager" ]; then
  log "installing Android command-line tools"
  mkdir -p "$SDK/cmdline-tools"
  tmp="$(mktemp -d)"
  curl -fsSL https://dl.google.com/android/repository/commandlinetools-linux-11076708_latest.zip -o "$tmp/clt.zip"
  unzip -q "$tmp/clt.zip" -d "$tmp"
  rm -rf "$SDK/cmdline-tools/latest"; mv "$tmp/cmdline-tools" "$SDK/cmdline-tools/latest"
  rm -rf "$tmp"
fi
export PATH="$SDK/cmdline-tools/latest/bin:$SDK/platform-tools:$PATH"
log "installing Android SDK packages (platform $PLATFORM, build-tools $BUILDTOOLS, NDK)"
yes | sdkmanager --licenses >/dev/null 2>&1 || true
sdkmanager "platform-tools" "platforms;$PLATFORM" "build-tools;$BUILDTOOLS" "ndk;$NDK_VER" >/dev/null
export ANDROID_NDK_HOME="$SDK/ndk/$NDK_VER"
flutter config --android-sdk "$SDK" >/dev/null 2>&1 || true

# 5. Source + bindings + native engine + APK.
if [ -f "app/pubspec.yaml" ] && grep -q "name: aegis" app/pubspec.yaml 2>/dev/null; then
  SRC="$PWD"
else
  log "cloning Aegis"
  rm -rf "$WORK"; git clone --depth 1 "$REPO" "$WORK"; SRC="$WORK"
fi
cd "$SRC/app"

log "generating bindings + platform folders"
flutter create --platforms=android --project-name aegis . >/dev/null
flutter pub get >/dev/null
flutter_rust_bridge_codegen generate

log "cross-compiling the Rust engine for Android (a few minutes)"
( cd rust && rm -f Cargo.lock && \
  cargo ndk -t arm64-v8a -t armeabi-v7a -t x86_64 -o ../android/app/src/main/jniLibs build --release )

log "building the APK (a few minutes)"
flutter build apk --debug

APK="$SRC/app/build/app/outputs/flutter-apk/app-debug.apk"
IP="$(curl -fsSL --max-time 5 https://api.ipify.org 2>/dev/null || echo YOUR_VPS_IP)"
echo
log "Done. APK: $APK"
echo "Copy it to your phone — easiest from the console:"
echo "  cd $(dirname "$APK") && python3 -m http.server 8080"
echo "  then on your phone open:  http://$IP:8080/app-debug.apk"
echo "  (open port 8080 in the firewall for that download, then Ctrl-C the server)"
echo "On Android: allow 'install from unknown sources' and open the APK."
echo "The seed node is baked in, so it connects with no setup."
