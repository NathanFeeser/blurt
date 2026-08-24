//! The object the shells hold.
//!
//! Everything above this line is plain Rust with no FFI in it; everything the
//! platform apps touch goes through here. Keeping the FFI surface small and
//! boring is deliberate — it is the part that is expensive to change once three
//! platforms depend on it.

use std::collections::HashMap;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use crate::context::AppContext;
use crate::error::{DictError, Result};
use crate::mode::{resolve_mode, Mode};
use crate::pipeline::{self, DictationResult, Stages};
use crate::providers::{
    default_base_url, DeepgramStt, LlmProvider, OpenAiCompatLlm, OpenAiCompatStt,
    ProviderCredentials, SttKind, SttProvider,
};
use crate::vocab::Vocabulary;

/// Give up rather than leave the user staring at a recording indicator. Local
/// models (Ollama cold start) can legitimately exceed this, so shells expose it.
const DEFAULT_TIMEOUT_SECS: u64 = 30;

/// rustls has no process-wide crypto provider unless one is installed, and it
/// panics on first use if none is. We build with the `ring` provider (see the
/// note in Cargo.toml), so install it exactly once before any client is built.
fn install_crypto_provider() {
    static ONCE: std::sync::Once = std::sync::Once::new();
    ONCE.call_once(|| {
        // Errs only if a provider is already installed, which is fine.
        let _ = rustls::crypto::ring::default_provider().install_default();
    });
}

#[derive(uniffi::Object)]
pub struct DictationEngine {
    inner: Mutex<EngineState>,
    http: reqwest::Client,
}

struct EngineState {
    /// Keyed by provider id. Populated from the OS keychain by the shell; the
    /// core never persists these.
    credentials: HashMap<String, ProviderCredentials>,
    modes: Vec<Mode>,
    active_mode_id: String,
    vocabulary: Vocabulary,
}

#[uniffi::export(async_runtime = "tokio")]
impl DictationEngine {
    #[uniffi::constructor]
    pub fn new() -> Self {
        Self::with_timeout_secs(DEFAULT_TIMEOUT_SECS)
    }

    /// Local models on a cold start can take far longer than a hosted API.
    #[uniffi::constructor]
    pub fn with_timeout_secs(timeout_secs: u64) -> Self {
        install_crypto_provider();
        let default = Mode::default_dictation();
        let http = reqwest::Client::builder()
            .timeout(Duration::from_secs(timeout_secs))
            // Keep sockets warm between dictations — this is worth ~100 ms on
            // every utterance after the first.
            .pool_idle_timeout(Duration::from_secs(300))
            .build()
            .unwrap_or_default();

        Self {
            inner: Mutex::new(EngineState {
                credentials: HashMap::new(),
                active_mode_id: default.id.clone(),
                modes: vec![default, Mode::raw()],
                vocabulary: Vocabulary::default(),
            }),
            http,
        }
    }

    /// Register (or replace) credentials for a provider id. If `base_url` is
    /// empty the well-known default for that id is used.
    pub fn set_credentials(&self, provider_id: String, mut creds: ProviderCredentials) {
        if creds.base_url.trim().is_empty() {
            if let Some(url) = default_base_url(&provider_id) {
                creds.base_url = url.to_string();
            }
        }
        self.inner
            .lock()
            .unwrap()
            .credentials
            .insert(provider_id, creds);
    }

    pub fn set_modes(&self, modes: Vec<Mode>) {
        let mut inner = self.inner.lock().unwrap();
        if !modes.is_empty() {
            // Don't leave `active_mode_id` dangling at something that no longer exists.
            if !modes.iter().any(|m| m.id == inner.active_mode_id) {
                inner.active_mode_id = modes[0].id.clone();
            }
            inner.modes = modes;
        }
    }

    pub fn set_active_mode(&self, mode_id: String) -> Result<()> {
        let mut inner = self.inner.lock().unwrap();
        if !inner.modes.iter().any(|m| m.id == mode_id) {
            return Err(DictError::UnknownProvider { id: mode_id });
        }
        inner.active_mode_id = mode_id;
        Ok(())
    }

    pub fn set_vocabulary(&self, vocabulary: Vocabulary) {
        self.inner.lock().unwrap().vocabulary = vocabulary;
    }

    pub fn modes(&self) -> Vec<Mode> {
        self.inner.lock().unwrap().modes.clone()
    }

    pub fn active_mode_id(&self) -> String {
        self.inner.lock().unwrap().active_mode_id.clone()
    }

    /// Transcribe and clean up. `samples` is 16 kHz mono f32 from `AudioCapture::stop`.
    ///
    /// The mode is resolved from `ctx.bundle_id` when a mode claims that app,
    /// otherwise the active mode is used.
    pub async fn transcribe(&self, samples: Vec<f32>, ctx: AppContext) -> Result<DictationResult> {
        let (mode, stages, vocab) = self.prepare(&ctx)?;
        pipeline::run_dictation(&samples, &stages, &mode, &ctx, &vocab).await
    }

    /// Command mode: apply a spoken instruction to `ctx.selected_text`.
    pub async fn run_command(&self, samples: Vec<f32>, ctx: AppContext) -> Result<DictationResult> {
        let (mode, stages, vocab) = self.prepare(&ctx)?;
        pipeline::run_command(&samples, &stages, &mode, &ctx, &vocab).await
    }

    /// Cheap reachability check for the settings UI, so users find out their key
    /// is wrong before they're mid-sentence.
    pub async fn check_credentials(&self, provider_id: String) -> Result<bool> {
        let creds = self.credentials_for(&provider_id)?;
        let url = format!("{}/models", creds.base_url.trim_end_matches('/'));
        let mut req = self.http.get(&url);
        if let Some(key) = &creds.api_key {
            req = req.bearer_auth(key);
        }
        match req.send().await {
            Ok(r) if r.status().is_success() => Ok(true),
            Ok(r) if r.status().as_u16() == 401 || r.status().as_u16() == 403 => {
                Err(DictError::Unauthorized {
                    provider: provider_id,
                })
            }
            Ok(_) => Ok(false),
            Err(e) => Err(crate::error::from_reqwest(&provider_id, e)),
        }
    }
}

impl DictationEngine {
    /// Resolve mode + providers for this dictation. Not exported: `Stages` holds
    /// trait objects that have no FFI representation.
    fn prepare(&self, ctx: &AppContext) -> Result<(Mode, Stages, Vocabulary)> {
        let inner = self.inner.lock().unwrap();
        let active = inner
            .modes
            .iter()
            .find(|m| m.id == inner.active_mode_id)
            .cloned()
            .unwrap_or_else(Mode::default_dictation);
        let mode = resolve_mode(&inner.modes, &active, ctx.bundle_id.as_deref()).clone();
        let vocab = inner.vocabulary.clone();
        let credentials = inner.credentials.clone();
        drop(inner);

        let stt = build_stt(&self.http, &credentials, &mode)?;
        let cleanup = match &mode.cleanup {
            Some(cfg) => Some(build_llm(
                &self.http,
                &credentials,
                &cfg.provider_id,
                &cfg.model,
            )?),
            None => None,
        };

        Ok((mode, Stages { stt, cleanup }, vocab))
    }

    fn credentials_for(&self, provider_id: &str) -> Result<ProviderCredentials> {
        lookup_credentials(&self.inner.lock().unwrap().credentials, provider_id)
    }
}

impl Default for DictationEngine {
    fn default() -> Self {
        Self::new()
    }
}

fn lookup_credentials(
    credentials: &HashMap<String, ProviderCredentials>,
    provider_id: &str,
) -> Result<ProviderCredentials> {
    if let Some(c) = credentials.get(provider_id) {
        return Ok(c.clone());
    }
    // A provider with a well-known local endpoint and no key is legitimately
    // usable with no configuration at all — that's the whole point of pointing
    // this at Ollama or a vLLM box.
    match default_base_url(provider_id) {
        Some(url) if url.starts_with("http://localhost") => Ok(ProviderCredentials {
            base_url: url.to_string(),
            api_key: None,
        }),
        _ => Err(DictError::NotConfigured {
            provider: provider_id.to_string(),
            detail: "no API key or base URL has been set".into(),
        }),
    }
}

fn build_stt(
    http: &reqwest::Client,
    credentials: &HashMap<String, ProviderCredentials>,
    mode: &Mode,
) -> Result<Arc<dyn SttProvider>> {
    let id = &mode.stt.provider_id;
    let creds = lookup_credentials(credentials, id)?;
    Ok(match SttKind::from_id(id)? {
        SttKind::OpenAiCompat => Arc::new(OpenAiCompatStt::new(
            http.clone(),
            creds,
            mode.stt.model.clone(),
            id.clone(),
        )),
        SttKind::Deepgram => Arc::new(DeepgramStt::new(
            http.clone(),
            creds,
            mode.stt.model.clone(),
        )),
    })
}

fn build_llm(
    http: &reqwest::Client,
    credentials: &HashMap<String, ProviderCredentials>,
    provider_id: &str,
    model: &str,
) -> Result<Arc<dyn LlmProvider>> {
    let creds = lookup_credentials(credentials, provider_id)?;
    Ok(Arc::new(OpenAiCompatLlm::new(
        http.clone(),
        creds,
        model.to_string(),
        provider_id.to_string(),
    )))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn local_providers_work_with_no_configuration() {
        let creds = lookup_credentials(&HashMap::new(), "ollama").unwrap();
        assert_eq!(creds.base_url, "http://localhost:11434/v1");
        assert!(creds.api_key.is_none());
    }

    #[test]
    fn hosted_providers_require_configuration() {
        let err = lookup_credentials(&HashMap::new(), "groq").unwrap_err();
        assert!(matches!(err, DictError::NotConfigured { .. }));
    }

    #[test]
    fn empty_base_url_is_filled_from_the_provider_default() {
        let engine = DictationEngine::new();
        engine.set_credentials(
            "groq".into(),
            ProviderCredentials {
                base_url: "  ".into(),
                api_key: Some("k".into()),
            },
        );
        let creds = engine.credentials_for("groq").unwrap();
        assert_eq!(creds.base_url, "https://api.groq.com/openai/v1");
    }

    #[test]
    fn setting_modes_repoints_a_dangling_active_id() {
        let engine = DictationEngine::new();
        let mut m = Mode::default_dictation();
        m.id = "only".into();
        engine.set_modes(vec![m]);
        assert_eq!(engine.active_mode_id(), "only");
    }

    #[test]
    fn empty_mode_list_is_ignored_rather_than_bricking_the_engine() {
        let engine = DictationEngine::new();
        let before = engine.modes().len();
        engine.set_modes(vec![]);
        assert_eq!(engine.modes().len(), before);
    }

    #[test]
    fn unknown_active_mode_is_rejected() {
        let engine = DictationEngine::new();
        assert!(engine.set_active_mode("nope".into()).is_err());
        assert!(engine.set_active_mode("raw".into()).is_ok());
    }
}
