# Aegis app

The Aegis messenger UI — **Flutter** on top of the Rust `aegis-api` engine via
[`flutter_rust_bridge`](https://cjycode.com/flutter_rust_bridge/). Android-first,
Linux next; one UI codebase for both.

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

`app/rust` is the flutter_rust_bridge crate: it depends on `aegis-api` (this
workspace) and re-exports `AegisApp` for the bridge to bind. See
`flutter_rust_bridge.yaml` for paths.

## Status

Scaffold: the Rust engine (`aegis-api`) is complete and tested; the Dart screens
(onboarding, chats, thread, add-contact) and theme are in place and call the
engine through `AegisEngine`. Running `flutter_rust_bridge_codegen generate`
fills in `lib/src/rust/` and the app builds. Push notifications, QR scanning,
persistent storage of ratchet state, and message-status ticks are the next UI
work.
