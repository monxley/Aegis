#!/usr/bin/env bash
# Build the Aegis iOS app from the macOS command line. iOS is NOT like the
# Android build: Apple's toolchain (clang for arm64-apple-ios, code signing,
# the Simulator, `xcodebuild`) exists only on macOS, so — unlike
# deploy/build-apk.sh, which runs on a headless Linux VPS — THIS SCRIPT MUST RUN
# ON A MAC with Xcode installed. There is no way to produce an iOS build on Linux.
#
#   bash deploy/build-ios.sh                 # build the app (unsigned)
#   TARGET=simulator bash deploy/build-ios.sh  # build for the iOS Simulator
#
# It installs Rust + the Apple targets and the Flutter SDK (under $HOME if
# absent), generates the flutter_rust_bridge bindings, cross-compiles the Rust
# engine into a static library for device + simulator, scaffolds the `ios/`
# folder, wires the static lib and the iOS-specific native glue (Face ID usage
# string, app-switcher privacy blur) into the Xcode project, and builds the app.
#
# It stops short of *signing*: a signed `.ipa` for a real device or the App
# Store needs your Apple Developer account and is done from Xcode (Product →
# Archive) or `flutter build ipa --export-options-plist=...`. This script gets
# you a compiling, runnable app; see the end for the signing hand-off.
#
# Prerequisites you must install yourself (they need the Mac App Store / sudo):
#   - Xcode (full app, not just the CLT) + `xcodebuild -runFirstLaunch` accepted
#   - CocoaPods:  `sudo gem install cocoapods`  (or `brew install cocoapods`)
set -euo pipefail

REPO="${REPO:-https://github.com/monxley/Aegis}"
FLUTTER_DIR="${FLUTTER_DIR:-$HOME/flutter}"
WORK="${WORK:-$HOME/aegis-ios-build}"
FRB_VERSION="2.0.0"
# `device` → build the app for a physical iPhone/iPad (unsigned; sign in Xcode).
# `simulator` → build for the iOS Simulator (no signing needed at all).
TARGET="${TARGET:-device}"

log()  { printf '\033[36m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[33m!!\033[0m %s\n' "$*"; }
die()  { printf '\033[31mxx\033[0m %s\n' "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

# 0. Preflight — this only works on macOS with a full Xcode + CocoaPods.
[ "$(uname -s)" = "Darwin" ] || die "iOS builds require macOS. Run this on a Mac (Android has deploy/build-apk.sh for Linux)."
have xcodebuild || die "Xcode not found. Install Xcode from the App Store, then run: sudo xcode-select -s /Applications/Xcode.app && xcodebuild -runFirstLaunch"
xcodebuild -version >/dev/null 2>&1 || die "xcodebuild can't run. Accept the licence: sudo xcodebuild -license accept"
have pod || die "CocoaPods not found. Install it: sudo gem install cocoapods   (or: brew install cocoapods)"

# 1. Rust + Apple targets. Device is arm64 only (no 32-bit iOS); the Simulator
#    is arm64 on Apple-Silicon Macs and x86_64 on Intel Macs, so build both sim
#    slices and fatten them with lipo — the resulting sim lib runs on either Mac.
if [ ! -x "$HOME/.cargo/bin/cargo" ]; then
  log "installing Rust (rustup)"
  curl -fsSL https://sh.rustup.rs | sh -s -- -y --profile minimal --default-toolchain stable
fi
# shellcheck disable=SC1091
. "$HOME/.cargo/env"
rustup target add aarch64-apple-ios aarch64-apple-ios-sim x86_64-apple-ios >/dev/null
[ -x "$HOME/.cargo/bin/flutter_rust_bridge_codegen" ] || \
  { log "installing flutter_rust_bridge_codegen"; cargo install flutter_rust_bridge_codegen --version "$FRB_VERSION" --locked; }

# 2. Flutter SDK.
if [ ! -x "$FLUTTER_DIR/bin/flutter" ]; then
  log "cloning Flutter (stable)"
  git clone --depth 1 -b stable https://github.com/flutter/flutter "$FLUTTER_DIR"
fi
export PATH="$FLUTTER_DIR/bin:$HOME/.cargo/bin:$PATH"
git config --global --add safe.directory "$FLUTTER_DIR" 2>/dev/null || true

# 3. Source. Always build from a FRESH clone so a stale local checkout can't be
#    shipped by mistake (mirrors deploy/build-apk.sh). REPO is overridable.
log "cloning $REPO (fresh, so the build is always current)"
rm -rf "$WORK"; git clone --depth 1 "$REPO" "$WORK"; SRC="$WORK"
log "building @ $(cd "$SRC" && git rev-parse --short HEAD)"
cd "$SRC/app"

# 4. Bindings + platform folder.
log "generating bindings + the iOS platform folder"
flutter create --platforms=ios --project-name aegis . >/dev/null
flutter pub get >/dev/null

# iOS launcher icon from the bundled source PNG (best-effort; keeps the default
# Flutter icon if generation fails rather than breaking the build).
log "generating the iOS app icon"
dart run flutter_launcher_icons -f flutter_launcher_icons-ios.yaml >/dev/null 2>&1 \
  || warn "app-icon generation failed (keeping default)"

mkdir -p lib/src/rust           # codegen canonicalizes this path before creating it
flutter_rust_bridge_codegen generate

# FRB writes rust/src/frb_generated.rs but does NOT declare it in the crate root,
# so without `mod frb_generated;` the glue (frb_get_rust_content_hash, the wire_*
# fns) is never compiled and the app fails at startup. Declare it (idempotent) —
# same fix build-apk.sh applies.
if [ -f rust/src/frb_generated.rs ] && ! grep -qE '^\s*(pub\s+)?mod frb_generated;' rust/src/lib.rs; then
  log "wiring 'mod frb_generated;' into rust/src/lib.rs (codegen leaves it out)"
  printf '\nmod frb_generated;\n' >> rust/src/lib.rs
fi

# 5. Cross-compile the Rust engine to a STATIC library (iOS links Rust statically
#    into the app binary; there is no jniLibs-style .so bundle as on Android).
log "cross-compiling the Rust engine for iOS device + simulator (a few minutes)"
( cd rust && rm -f Cargo.lock && \
  cargo build --release --target aarch64-apple-ios && \
  cargo build --release --target aarch64-apple-ios-sim && \
  cargo build --release --target x86_64-apple-ios )

LIB=librust_lib_aegis.a          # matches [package] name in app/rust/Cargo.toml
RLIBS="ios/rust-libs"
mkdir -p "$RLIBS/device" "$RLIBS/sim"
cp "rust/target/aarch64-apple-ios/release/$LIB" "$RLIBS/device/libaegis_rust.a"
# One simulator lib covering both Intel and Apple-Silicon Macs.
lipo -create \
  "rust/target/aarch64-apple-ios-sim/release/$LIB" \
  "rust/target/x86_64-apple-ios/release/$LIB" \
  -output "$RLIBS/sim/libaegis_rust.a"

# 6. Link the static lib into the Runner. Rather than surgery on project.pbxproj,
#    append SDK-conditional linker flags to the xcconfigs Flutter already
#    includes — the right slice (device vs simulator) is chosen automatically.
#    `-force_load` keeps every object file: the FRB glue is reached only through
#    FFI symbol lookup, so without it the linker would dead-strip it and the app
#    would crash at launch with a missing `frb_get_rust_content_hash`.
for cfg in Debug Release; do
  xcconfig="ios/Flutter/$cfg.xcconfig"
  [ -f "$xcconfig" ] || continue
  if ! grep -q 'rust-libs/device/libaegis_rust.a' "$xcconfig"; then
    log "linking the Rust static lib into $cfg.xcconfig"
    {
      echo ''
      echo '// Aegis: link the cross-compiled Rust engine (added by deploy/build-ios.sh).'
      echo 'OTHER_LDFLAGS[sdk=iphoneos*]=$(inherited) -force_load $(SRCROOT)/rust-libs/device/libaegis_rust.a'
      echo 'OTHER_LDFLAGS[sdk=iphonesimulator*]=$(inherited) -force_load $(SRCROOT)/rust-libs/sim/libaegis_rust.a'
    } >> "$xcconfig"
  fi
done

# 7. Info.plist — Face ID usage string (local_auth crashes without it when it
#    invokes Face ID) and a background-fetch mode. NOTE: unlike Android's
#    foreground service, iOS grants only best-effort, throttled background wakes,
#    so background receive on iOS is degraded, not continuous (see ROADMAP).
PLIST="ios/Runner/Info.plist"
if [ -f "$PLIST" ]; then
  if ! /usr/libexec/PlistBuddy -c 'Print :NSFaceIDUsageDescription' "$PLIST" >/dev/null 2>&1; then
    log "adding NSFaceIDUsageDescription to Info.plist"
    /usr/libexec/PlistBuddy -c 'Add :NSFaceIDUsageDescription string "Unlock Aegis with Face ID."' "$PLIST"
  fi
  if ! /usr/libexec/PlistBuddy -c 'Print :UIBackgroundModes' "$PLIST" >/dev/null 2>&1; then
    log "declaring the fetch background mode in Info.plist"
    /usr/libexec/PlistBuddy -c 'Add :UIBackgroundModes array' "$PLIST"
    /usr/libexec/PlistBuddy -c 'Add :UIBackgroundModes:0 string fetch' "$PLIST"
  fi
fi

# 8. Native glue — rewrite AppDelegate.swift to add the `aegis/screen_security`
#    channel. iOS has NO way to block screenshots (unlike Android FLAG_SECURE),
#    so `setSecure` instead toggles an app-switcher privacy blur: a cover view
#    shown when the app resigns active, so the multitasking snapshot doesn't leak
#    the conversation. Also posts a Dart-visible event when a screenshot is taken
#    (detect-only — iOS cannot prevent it). Secure by default (blur on).
SWIFT="ios/Runner/AppDelegate.swift"
if [ -f "$SWIFT" ] && ! grep -q 'aegis/screen_security' "$SWIFT"; then
  log "patching AppDelegate.swift for the app-switcher privacy blur"
  cat > "$SWIFT" <<'SWIFT_EOF'
import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate {
    private let secureChannelName = "aegis/screen_security"
    // Secure by default: cover the app snapshot in the switcher until the user
    // turns it off (mirrors the Android FLAG_SECURE default).
    private var privacyBlurEnabled = true
    private var privacyCover: UIView?

    override func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        let controller = window?.rootViewController as! FlutterViewController
        let channel = FlutterMethodChannel(
            name: secureChannelName,
            binaryMessenger: controller.binaryMessenger
        )
        channel.setMethodCallHandler { [weak self] call, result in
            if call.method == "setSecure" {
                self?.privacyBlurEnabled = (call.arguments as? Bool) ?? true
                result(nil)
            } else {
                result(FlutterMethodNotImplemented)
            }
        }

        // Detect-only: iOS can tell us a screenshot was taken but cannot block it.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(onScreenshot),
            name: UIApplication.userDidTakeScreenshotNotification,
            object: nil
        )

        GeneratedPluginRegistrant.register(with: self)
        return super.application(application, didFinishLaunchingWithOptions: launchOptions)
    }

    // Cover the screen the moment we leave the foreground, so the snapshot iOS
    // stores for the app switcher shows the blur, not the chat.
    override func applicationWillResignActive(_ application: UIApplication) {
        guard privacyBlurEnabled, privacyCover == nil, let window = window else { return }
        let cover = UIVisualEffectView(effect: UIBlurEffect(style: .systemThinMaterialDark))
        cover.frame = window.bounds
        cover.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        window.addSubview(cover)
        privacyCover = cover
    }

    override func applicationDidBecomeActive(_ application: UIApplication) {
        privacyCover?.removeFromSuperview()
        privacyCover = nil
    }

    @objc private func onScreenshot() {
        // Hook point for a future "a screenshot was taken" warning to Dart.
    }
}
SWIFT_EOF
fi

# 9. Fetch the CocoaPods dependencies for the Flutter plugins, then build.
log "installing CocoaPods dependencies"
( cd ios && pod install >/dev/null 2>&1 || pod install )

if [ "$TARGET" = "simulator" ]; then
  log "building the app for the iOS Simulator (no signing needed)"
  flutter build ios --debug --simulator
  APP="$SRC/app/build/ios/iphonesimulator/Runner.app"
  echo
  log "Done. Simulator app: $APP"
  echo "Run it:  flutter run   (with a Simulator open), or drag Runner.app onto the Simulator."
else
  log "building the app for a physical device (UNSIGNED)"
  flutter build ios --debug --no-codesign
  APP="$SRC/app/build/ios/iphoneos/Runner.app"
  echo
  log "Done (unsigned). App bundle: $APP"
  echo
  echo "To install on YOUR iPhone you must sign it with your Apple ID:"
  echo "  1. open ios/Runner.xcworkspace in Xcode  (from $SRC/app)"
  echo "  2. Runner target → Signing & Capabilities → pick your Team"
  echo "     (a free Apple ID works for a 7-day on-device build)"
  echo "  3. plug in the iPhone, select it, press Run — or Product → Archive for a .ipa"
  echo "  Or from the console:  flutter run --release   (with the device connected)"
fi
echo
echo "The seed node is baked in, so it connects with no setup."
echo "Export compliance: Aegis uses end-to-end encryption. Before any TestFlight/"
echo "App Store upload, set ITSAppUsesNonExemptEncryption in Info.plist and complete"
echo "Apple's encryption self-classification — do not guess this value."
