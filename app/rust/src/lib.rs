//! `rust_lib_aegis` — the flutter_rust_bridge crate for the Aegis app.
//!
//! It exposes [`api::aegis::AegisEngine`] (a thin wrapper over
//! `aegis_api::AegisApp`) to Dart. Running `flutter_rust_bridge_codegen
//! generate` writes `src/frb_generated.rs` and inserts its `mod frb_generated;`
//! declaration here; that file is the bridge glue and does not exist until you
//! run codegen.

pub mod api;
