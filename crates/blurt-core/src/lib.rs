//! blurt-core — the portable dictation pipeline.
//!
//! One implementation of capture buffering, provider adapters, cleanup, and
//! mode resolution, shared by the macOS, iOS, and Windows shells over UniFFI.
//! Nothing in here knows about a UI framework or an operating system.
//!
//! The shells own only what is irreducibly platform-specific: microphone
//! capture, the global hotkey, screen-context scraping, and text insertion.
//! See docs/ARCHITECTURE.md.

pub mod audio;
pub mod cleanup;
pub mod context;
pub mod engine;
pub mod error;
pub mod history;
pub mod mode;
pub mod pipeline;
pub mod providers;
pub mod vocab;

pub use audio::{AudioCapture, CaptureStats, SAMPLE_RATE};
pub use context::AppContext;
pub use engine::DictationEngine;
pub use error::DictError;
pub use history::{EntryKind, History, HistoryEntry};
pub use mode::{LlmConfig, Mode, SttConfig};
pub use pipeline::{DictationResult, Timings};
pub use providers::{ProviderCredentials, Transcript};
pub use vocab::Vocabulary;

uniffi::setup_scaffolding!();
