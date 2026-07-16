#!/usr/bin/env bash
# Build the Aegis Android APK on a plain Linux VPS, entirely from the console
# (no GUI, no GitHub Actions). Made for a Debian/Ubuntu box you SSH into.
#
#   curl -fsSL https://raw.githubusercontent.com/monxley/Aegis/main/deploy/build-apk.sh | bash
#
# It installs a JDK, the Flutter SDK, the Android command-line SDK + NDK, and
# Rust, then builds an installable debug APK and tells you how to copy it to
# your phone. FULLY ROOTLESS: everything lands under $HOME, no sudo/apt needed
# (a portable JDK is downloaded if `java` is absent). Only needs git + curl,
# which you already have if this script was fetched.
#
# Needs ~8 GB free disk and ~2 GB RAM. On a <2 GB box the build may be OOM-killed
# ("Killed"); without root you can't add swap, so build on a bigger box.
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

# Extract a zip without requiring `unzip` (portable, no root): unzip if present,
# else python3, else the JDK's `jar`.
extract_zip() { # $1=zip  $2=dest_dir
  if have unzip; then unzip -q "$1" -d "$2"
  elif have python3; then python3 -c "import zipfile,sys;zipfile.ZipFile(sys.argv[1]).extractall(sys.argv[2])" "$1" "$2"
  else ( mkdir -p "$2" && cd "$2" && jar xf "$1" ); fi
}

# 1. JDK — NO ROOT. Use an existing java, else drop a portable Temurin 17 under
#    $HOME. (git/curl are already present since this script was fetched + can
#    clone.)
if have java; then
  export JAVA_HOME="${JAVA_HOME:-$(dirname "$(dirname "$(readlink -f "$(command -v java)")")")}"
else
  if [ ! -x "$HOME/jdk/bin/java" ]; then
    log "installing a portable JDK 17 under \$HOME (no root)"
    case "$(uname -m)" in
      x86_64|amd64) JARCH=x64 ;;
      aarch64|arm64) JARCH=aarch64 ;;
      *) JARCH=x64 ;;
    esac
    mkdir -p "$HOME/jdk"; tmp="$(mktemp -d)"
    curl -fsSL "https://api.adoptium.net/v3/binary/latest/17/ga/linux/$JARCH/jdk/hotspot/normal/eclipse?project=jdk" -o "$tmp/jdk.tar.gz"
    tar -xzf "$tmp/jdk.tar.gz" -C "$tmp"
    jdir="$(find "$tmp" -maxdepth 1 -type d -name 'jdk-17*' | head -1)"
    rm -rf "$HOME/jdk"; mv "$jdir" "$HOME/jdk"; rm -rf "$tmp"
  fi
  export JAVA_HOME="$HOME/jdk"; export PATH="$HOME/jdk/bin:$PATH"
fi

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
  extract_zip "$tmp/clt.zip" "$tmp"
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
export FLUTTER_ALLOW_ROOT=true   # this VPS session runs as root; that's fine here
flutter create --platforms=android --project-name aegis . >/dev/null
flutter pub get >/dev/null

# Flutter's generated MAIN manifest has no INTERNET permission — it ships only
# in the debug/profile manifests, so a release build would have no network at
# all and every socket (all our traffic runs from Rust) would fail. Declare the
# network permissions in the main manifest so they're present in every build.
# Both are "normal" permissions: granted silently at install, no user prompt.
MANIFEST="android/app/src/main/AndroidManifest.xml"
if [ -f "$MANIFEST" ] && ! grep -q 'android.permission.INTERNET' "$MANIFEST"; then
  log "adding INTERNET + network-state permissions to AndroidManifest"
  awk '/<application/ && !d {
        print "    <uses-permission android:name=\"android.permission.INTERNET\"/>";
        print "    <uses-permission android:name=\"android.permission.ACCESS_NETWORK_STATE\"/>";
        d=1
      } {print}' "$MANIFEST" > "$MANIFEST.tmp" && mv "$MANIFEST.tmp" "$MANIFEST"
fi

mkdir -p lib/src/rust           # codegen canonicalizes this path before creating it
flutter_rust_bridge_codegen generate

# FRB's codegen writes rust/src/frb_generated.rs but does NOT wire it into the
# crate root, so `mod frb_generated;` is missing and the glue (frb_get_rust_
# content_hash, the wire_* fns) never gets compiled into the .so. The library
# then builds clean but fails at load with:
#   undefined symbol: frb_get_rust_content_hash
# Declare the module now that the generated file exists (idempotent).
if [ -f rust/src/frb_generated.rs ] && ! grep -qE '^\s*(pub\s+)?mod frb_generated;' rust/src/lib.rs; then
  log "wiring 'mod frb_generated;' into rust/src/lib.rs (codegen leaves it out)"
  printf '\nmod frb_generated;\n' >> rust/src/lib.rs
fi

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
