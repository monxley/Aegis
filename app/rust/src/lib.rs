//! `rust_lib_shoal` — the flutter_rust_bridge crate for the Shoal app.
//!
//! It exposes [`api::shoal::ShoalEngine`] (a thin wrapper over
//! `shoal_api::ShoalApp`) to Dart. Running `flutter_rust_bridge_codegen
//! generate` writes `src/frb_generated.rs` (the bridge glue), which does not
//! exist until you run codegen. That glue must be wired in with a
//! `mod frb_generated;` declaration; codegen does NOT add it, so the build
//! (see `deploy/build-apk.sh`) appends it after generation — without it the
//! crate compiles clean but the `.so` loads with
//! "undefined symbol: frb_get_rust_content_hash".

pub mod api;
