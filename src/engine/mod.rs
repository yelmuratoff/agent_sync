//! The render: source overlays and the file tree a run reads, the per-target
//! copy, conversion, and composition passes, and the staged writes they end in.

pub mod codex_toml;
pub mod convert;
pub mod file_ops;
pub mod filters;
pub mod gitignore;
pub mod opencode_json;
pub mod overlay;
pub mod render;
pub mod rules;
pub mod session;
pub mod staging;
pub mod workspace;
