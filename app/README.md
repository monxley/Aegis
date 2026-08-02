# Aegis app

The Aegis messenger UI — **Flutter** on top of the Rust `aegis-api` engine via
[`flutter_rust_bridge`](https://cjycode.com/flutter_rust_bridge/). Android-first,
with an **iOS** build (alpha) and Linux next; one UI codebase for all.

```
┌───────────────────────────────┐
│ Flutter UI (Dart)             │  screens, theme, animations
│   lib/screens/  lib/theme.dart│
├───────────────────────────────┤
│ AegisEngine (lib/engine.dart) │  thin Dart wrapper
├───────────────────────────────┤
│ flutter_rust_bridge (generated)│  lib/src/rust/  ← codegen output
├───────────────────────────────┤
│ app/rust  →  aegis-api (Rust)  │  AegisApp: identity, contacts, chat
│                → aegis-client → the whole protocol (crypto stays in Rust)
└───────────────────────────────┘
```

The UI never sees a key: it calls `AegisApp` (identity, contacts, `send`,
`poll`, `history`); all cryptography and protocol state live in Rust.

## One-time setup

```sh
# 1. Tooling
cargo install flutter_rust_bridge_codegen cargo-ndk
flutter create --platforms=android,linux .        # if the platform folders are absent

# 2. Generate the Dart bindings from the Rust API (app/rust → lib/src/rust)
flutter_rust_bridge_codegen generate

# 3. Build the Rust engine for Android and run
cargo ndk -o android/app/src/main/jniLibs build --release   # from app/rust
flutter run                                                 # device/emulator

# Linux desktop:
flutter run -d linux
```

### iOS (alpha)

iOS must be built **on a Mac with Xcode** — Apple's toolchain has no Linux
equivalent, so there is no headless-VPS path like the Android APK. One command
does the whole thing (installs Rust + Apple targets + Flutter if missing,
cross-compiles the engine to a static lib, wires it and the native glue into the
Xcode project, and builds):

```sh
bash deploy/build-ios.sh                    # unsigned build for a physical device
TARGET=simulator bash deploy/build-ios.sh   # for the iOS Simulator (no signing)
```

It stops at an **unsigned** app; installing on a real iPhone or shipping needs
your Apple ID / Developer account (open `ios/Runner.xcworkspace` in Xcode, pick a
signing Team, Run or Archive). What works, and what is still partial on iOS
(background delivery, screenshot blocking), is tracked in `ROADMAP.md` →
"iOS support (alpha)".

`app/rust` is the flutter_rust_bridge crate: it depends on `aegis-api` (this
workspace) and re-exports `AegisApp` for the bridge to bind. See
`flutter_rust_bridge.yaml` for paths.

## Status

Scaffold: the Rust engine (`aegis-api`) is complete and tested; the Dart screens
(onboarding, chats, thread, add-contact) and theme are in place and call the
engine through `AegisEngine`. Running `flutter_rust_bridge_codegen generate`
fills in `lib/src/rust/` and the app builds. **State persists across restarts**:
the engine exports its sessions, contacts, and history, and `AegisEngine`
(lib/engine.dart) saves that blob to local storage after every change and
restores it on launch.

**Zero-setup networking**: onboarding defaults to the anonymous mixnet — the app
auto-discovers nodes from the built-in bootstrap list (`lib/config.dart`) and
onion-routes sends, no relay to configure. Settings has an opt-in **node toggle**
(on by default on desktop/Linux) so a device can also carry the network. An
"Advanced" sheet still allows a specific relay or offline mode.

Push notifications, QR scanning, and message-status ticks are the next UI work.
