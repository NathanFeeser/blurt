use async_trait::async_trait;

use super::{SttProvider, SttRequest, Transcript};
use crate::error::{DictError, Result};

/// On-device transcription, implemented by the platform shell.
///
/// The core deliberately does not own this. Running Whisper on Apple's Neural
/// Engine means CoreML and Swift; on Windows it will mean whisper.cpp or ONNX
/// Runtime. Both are the shell's business. The core's job is to orchestrate,
/// pick the mode, and assemble the cleanup prompt — not to host an inference
/// engine per platform.
///
/// Implemented in foreign code (Swift, C#) and called from Rust.
#[uniffi::export(with_foreign)]
#[async_trait]
pub trait LocalTranscriber: Send + Sync {
    /// Transcribe 16 kHz mono float samples.
    ///
    /// Samples rather than an encoded file: WhisperKit and whisper.cpp both take
    /// float arrays, so encoding a WAV here would only be decoded again.
    ///
    /// `language` is a BCP-47 tag, or `None` to auto-detect.
    async fn transcribe(&self, samples: Vec<f32>, language: Option<String>) -> Result<String>;

    /// The model currently loaded, for display and for the pipeline's record of
    /// what produced a transcript.
    fn model_name(&self) -> String;

    /// False while a model is still downloading or loading. The engine checks
    /// this so a mode can fall back to a hosted provider instead of hanging.
    fn is_ready(&self) -> bool;
}

/// Adapts the foreign transcriber to the same trait the hosted providers use, so
/// nothing downstream needs to know whether audio left the machine.
pub struct LocalStt {
    inner: std::sync::Arc<dyn LocalTranscriber>,
}

impl LocalStt {
    pub fn new(inner: std::sync::Arc<dyn LocalTranscriber>) -> Self {
        Self { inner }
    }
}

#[async_trait]
impl SttProvider for LocalStt {
    fn name(&self) -> &str {
        "on-device"
    }

    fn model(&self) -> &str {
        // The trait returns an owned String because it crosses the FFI; this
        // trait wants a borrow. The concrete name travels on the Transcript.
        "on-device"
    }

    async fn transcribe(&self, req: SttRequest) -> Result<Transcript> {
        if !self.inner.is_ready() {
            return Err(DictError::NotConfigured {
                provider: "on-device".into(),
                detail: "the local model is still loading".into(),
            });
        }

        let started = std::time::Instant::now();
        // Note: no biasing prompt. WhisperKit exposes one, but routing custom
        // vocabulary through it is later work: the prompt is capped at 224
        // tokens and weighted towards the end, so it needs its own design.
        let text = self
            .inner
            .transcribe(req.samples, req.language.clone())
            .await?;

        Ok(Transcript {
            text: text.trim().to_string(),
            detected_language: req.language,
            provider: "on-device".into(),
            model: self.inner.model_name(),
            latency_ms: started.elapsed().as_millis() as u64,
        })
    }
}
