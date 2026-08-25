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
use crate::history::{should_record, EntryKind, History, HistoryEntry};
use crate::mode::{resolve_mode, Mode};
use crate::pipeline::{self, DictationResult, Stages};
use crate::providers::{
    default_base_url, DeepgramStt, LlmProvider, LocalStt, LocalTranscriber, OpenAiCompatLlm,
    OpenAiCompatStt, ProviderCredentials, SttKind, SttProvider,
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
    /// Supplied by the shell when on-device transcription is available.
    local: Option<Arc<dyn LocalTranscriber>>,
    /// `None` until a shell opens one. History is opt-in at the shell level and
    /// per-mode below that; a core with no store simply records nothing.
    history: Option<Arc<History>>,
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
                local: None,
                history: None,
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

    /// Register the shell's on-device transcriber, or clear it with `None`.
    ///
    /// Modes referring to the `local` provider fail with a clear error until
    /// this is set, rather than silently falling back to a hosted provider —
    /// a mode chosen for privacy must never quietly send audio to a server.
    pub fn set_local_transcriber(&self, transcriber: Option<Arc<dyn LocalTranscriber>>) {
        self.inner.lock().unwrap().local = transcriber;
    }

    pub fn has_local_transcriber(&self) -> bool {
        self.inner.lock().unwrap().local.is_some()
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
        let mut result = pipeline::run_dictation(&samples, &stages, &mode, &ctx, &vocab).await?;
        result.entry_id = self.remember(&result, &ctx, &mode, EntryKind::Dictation);
        Ok(result)
    }

    /// Command mode: apply a spoken instruction to `ctx.selected_text`.
    pub async fn run_command(&self, samples: Vec<f32>, ctx: AppContext) -> Result<DictationResult> {
        let (mode, stages, vocab) = self.prepare(&ctx)?;
        let mut result = pipeline::run_command(&samples, &stages, &mode, &ctx, &vocab).await?;
        result.entry_id = self.remember(&result, &ctx, &mode, EntryKind::Command);
        Ok(result)
    }

    // MARK: history
    //
    // Recording happens here rather than in each shell so that iOS and Windows
    // get it by existing, and so there is exactly one place that decides whether
    // a dictation is written down.

    /// Open (creating if needed) the history database at `path`.
    ///
    /// The shell picks the location because only it knows what its platform
    /// considers user data. Nothing is recorded until this is called.
    pub fn open_history(&self, path: String, limit: u32) -> Result<()> {
        let history = History::open(&path, limit)?;
        self.inner.lock().unwrap().history = Some(Arc::new(history));
        Ok(())
    }

    /// Stop recording. Existing entries are left alone — use `history_clear`
    /// to delete them, which is a different question the user answers.
    pub fn close_history(&self) {
        self.inner.lock().unwrap().history = None;
    }

    pub fn history_is_open(&self) -> bool {
        self.inner.lock().unwrap().history.is_some()
    }

    pub fn history_recent(&self, limit: u32) -> Result<Vec<HistoryEntry>> {
        match self.history() {
            Some(h) => h.recent(limit),
            None => Ok(vec![]),
        }
    }

    pub fn history_search(&self, query: String, limit: u32) -> Result<Vec<HistoryEntry>> {
        match self.history() {
            Some(h) => h.search(&query, limit),
            None => Ok(vec![]),
        }
    }

    pub fn history_entry(&self, id: i64) -> Result<Option<HistoryEntry>> {
        match self.history() {
            Some(h) => h.get(id),
            None => Ok(None),
        }
    }

    pub fn history_count(&self) -> Result<u32> {
        match self.history() {
            Some(h) => h.count(),
            None => Ok(0),
        }
    }

    /// Record which insertion strategy landed. Only the shell knows.
    pub fn history_note_insertion(&self, id: i64, method: String) -> Result<()> {
        match self.history() {
            Some(h) => h.note_insertion(id, &method),
            None => Ok(()),
        }
    }

    /// Record what the user turned the inserted text into — the correction pair
    /// a future cleanup model would train on.
    pub fn history_record_edit(&self, id: i64, edited: String) -> Result<()> {
        match self.history() {
            Some(h) => h.record_edit(id, &edited),
            None => Ok(()),
        }
    }

    pub fn history_delete(&self, id: i64) -> Result<()> {
        match self.history() {
            Some(h) => h.delete(id),
            None => Ok(()),
        }
    }

    /// Re-run the cleanup stage over a stored dictation's raw transcript, using
    /// a mode of the caller's choosing.
    ///
    /// This is cleanup-only by construction: history keeps text, never audio, so
    /// there is nothing to re-transcribe. Trying a different *prompt* on what
    /// you actually said is the useful half anyway — and it is how a user can
    /// tell whether a mode is worth switching to.
    ///
    /// The stored entry is left untouched. A re-run is an experiment, not a
    /// correction of the record.
    pub async fn rerun_cleanup(&self, entry_id: i64, mode_id: String) -> Result<DictationResult> {
        let entry = self
            .history_entry(entry_id)?
            .ok_or_else(|| DictError::Storage {
                detail: format!("no history entry {entry_id}"),
            })?;

        // The app it was dictated into is part of what cleanup conditions on, so
        // a re-run has to reproduce that context or it is scoring a different
        // prompt than the one that ran.
        let ctx = AppContext {
            bundle_id: entry.app_bundle_id.clone(),
            app_name: entry.app_name.clone(),
            window_title: None,
            surrounding_text: None,
            selected_text: None,
        };
        let (mode, stages, _) = self.prepare_with(&ctx, Some(&mode_id))?;
        let cleaned = pipeline::clean_up(&entry.raw_text, &stages, &mode, &ctx).await;

        Ok(DictationResult {
            entry_id: Some(entry_id),
            mode_id: mode.id.clone(),
            mode_name: mode.name.clone(),
            raw_text: entry.raw_text,
            final_text: cleaned.text,
            cleanup_ran: cleaned.ran,
            cleanup_error: cleaned.error,
            audio_duration_ms: entry.audio_duration_ms,
            detected_language: None,
            stt_provider: entry.stt_provider,
            stt_model: entry.stt_model,
            timings: crate::pipeline::Timings {
                stt_ms: 0,
                cleanup_ms: cleaned.elapsed_ms,
                total_ms: cleaned.elapsed_ms,
            },
        })
    }

    pub fn history_clear(&self) -> Result<()> {
        match self.history() {
            Some(h) => h.clear(),
            None => Ok(()),
        }
    }

    /// Which mode would run for this context right now.
    ///
    /// Exists so the UI can name the active mode without reimplementing
    /// `resolve_mode` — two implementations of app matching will disagree
    /// eventually, and the one the user sees would be the wrong one.
    pub fn resolve_mode_for(&self, ctx: AppContext) -> Mode {
        let inner = self.inner.lock().unwrap();
        let active = inner
            .modes
            .iter()
            .find(|m| m.id == inner.active_mode_id)
            .cloned()
            .unwrap_or_else(Mode::default_dictation);
        resolve_mode(&inner.modes, &active, ctx.bundle_id.as_deref()).clone()
    }

    /// Run only the cleanup stage against text that is already transcribed.
    ///
    /// Exists for the eval harness: scoring cleanup without audio removes STT
    /// variance from the measurement, which matters a great deal on a free tier
    /// where identical clips vary by a factor of three.
    pub async fn clean_up_text(&self, text: String, ctx: AppContext) -> Result<DictationResult> {
        let (mode, stages, _) = self.prepare(&ctx)?;
        let cleaned = pipeline::clean_up(&text, &stages, &mode, &ctx).await;
        Ok(DictationResult {
            entry_id: None,
            mode_id: mode.id.clone(),
            mode_name: mode.name.clone(),
            raw_text: text,
            final_text: cleaned.text,
            cleanup_ran: cleaned.ran,
            cleanup_error: cleaned.error,
            audio_duration_ms: 0,
            detected_language: None,
            stt_provider: "none".into(),
            stt_model: "none".into(),
            timings: crate::pipeline::Timings {
                stt_ms: 0,
                cleanup_ms: cleaned.elapsed_ms,
                total_ms: cleaned.elapsed_ms,
            },
        })
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
        self.prepare_with(ctx, None)
    }

    /// `forced_mode` bypasses app matching. Re-running a stored dictation is
    /// the caller picking a mode by hand; resolving from the app it was
    /// originally dictated into would silently ignore that choice.
    fn prepare_with(
        &self,
        ctx: &AppContext,
        forced_mode: Option<&str>,
    ) -> Result<(Mode, Stages, Vocabulary)> {
        let inner = self.inner.lock().unwrap();
        let mode = match forced_mode {
            Some(id) => inner
                .modes
                .iter()
                .find(|m| m.id == id)
                .cloned()
                .ok_or_else(|| DictError::UnknownProvider { id: id.to_string() })?,
            None => {
                let active = inner
                    .modes
                    .iter()
                    .find(|m| m.id == inner.active_mode_id)
                    .cloned()
                    .unwrap_or_else(Mode::default_dictation);
                resolve_mode(&inner.modes, &active, ctx.bundle_id.as_deref()).clone()
            }
        };
        let vocab = inner.vocabulary.clone();
        let credentials = inner.credentials.clone();
        let local = inner.local.clone();
        drop(inner);

        let stt = build_stt(&self.http, &credentials, local, &mode)?;
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

    fn history(&self) -> Option<Arc<History>> {
        self.inner.lock().unwrap().history.clone()
    }

    /// Write a finished dictation to history, if there is a store and the mode
    /// allows it.
    ///
    /// Failures are swallowed on purpose. The text is already on its way into
    /// the user's app by now; a full disk is not a reason to tell them their
    /// dictation failed, and the error is visible in the log.
    fn remember(
        &self,
        result: &DictationResult,
        ctx: &AppContext,
        mode: &Mode,
        kind: EntryKind,
    ) -> Option<i64> {
        if !should_record(mode, result) {
            return None;
        }
        match self.history()?.record(result, ctx, kind) {
            Ok(id) => Some(id),
            Err(e) => {
                tracing::warn!("could not write history: {e}");
                None
            }
        }
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
    local: Option<Arc<dyn LocalTranscriber>>,
    mode: &Mode,
) -> Result<Arc<dyn SttProvider>> {
    let id = &mode.stt.provider_id;

    // On-device needs no credentials, and asking for them first would reject a
    // perfectly valid offline configuration.
    if SttKind::from_id(id)? == SttKind::Local {
        let transcriber = local.ok_or(DictError::NotConfigured {
            provider: "on-device".into(),
            detail: "no on-device model is installed".into(),
        })?;
        return Ok(Arc::new(LocalStt::new(transcriber)));
    }

    let creds = lookup_credentials(credentials, id)?;
    Ok(match SttKind::from_id(id)? {
        SttKind::Local => unreachable!("handled above"),
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
    fn on_device_without_an_installed_model_is_a_clear_error() {
        let err = build_stt(
            &reqwest::Client::new(),
            &HashMap::new(),
            None,
            &Mode {
                stt: crate::mode::SttConfig {
                    provider_id: "local".into(),
                    model: "large-v3-turbo".into(),
                    language: None,
                },
                ..Mode::default_dictation()
            },
        );
        match err {
            Err(DictError::NotConfigured { provider, .. }) => assert_eq!(provider, "on-device"),
            Err(other) => panic!("expected NotConfigured, got {other:?}"),
            Ok(_) => panic!("expected an error when no model is installed"),
        }
    }

    #[test]
    fn on_device_never_falls_back_to_a_hosted_provider() {
        // A mode chosen for privacy must fail loudly rather than quietly send
        // the user's audio to a server.
        let mut credentials = HashMap::new();
        credentials.insert(
            "groq".to_string(),
            ProviderCredentials {
                base_url: "https://x".into(),
                api_key: Some("k".into()),
            },
        );
        let result = build_stt(
            &reqwest::Client::new(),
            &credentials,
            None,
            &Mode {
                stt: crate::mode::SttConfig {
                    provider_id: "whisperkit".into(),
                    model: "large-v3-turbo".into(),
                    language: None,
                },
                ..Mode::default_dictation()
            },
        );
        assert!(
            result.is_err(),
            "must not silently use a configured hosted provider"
        );
    }

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
    fn history_calls_are_harmless_before_a_shell_opens_a_store() {
        // iOS and the CLI may never open one. Reading history then is an empty
        // list, not an error the caller has to special-case.
        let engine = DictationEngine::new();
        assert!(!engine.history_is_open());
        assert!(engine.history_recent(10).unwrap().is_empty());
        assert!(engine
            .history_search("anything".into(), 10)
            .unwrap()
            .is_empty());
        assert_eq!(engine.history_count().unwrap(), 0);
        assert!(engine.history_entry(1).unwrap().is_none());
        assert!(engine.history_note_insertion(1, "paste".into()).is_ok());
        assert!(engine.history_delete(1).is_ok());
        assert!(engine.history_clear().is_ok());
    }

    #[test]
    fn a_mode_that_opts_out_leaves_no_row_behind() {
        let engine = DictationEngine::new();
        engine.open_history(":memory:".into(), 100).unwrap();

        let ctx = AppContext {
            bundle_id: None,
            app_name: None,
            window_title: None,
            surrounding_text: None,
            selected_text: None,
        };
        let result = crate::pipeline::DictationResult {
            entry_id: None,
            mode_id: "private".into(),
            mode_name: "Private (on-device)".into(),
            raw_text: "something private".into(),
            final_text: "something private".into(),
            cleanup_ran: false,
            cleanup_error: None,
            audio_duration_ms: 1000,
            detected_language: None,
            stt_provider: "local".into(),
            stt_model: "large-v3-turbo".into(),
            timings: crate::pipeline::Timings::default(),
        };

        assert!(engine
            .remember(&result, &ctx, &Mode::private(), EntryKind::Dictation)
            .is_none());
        assert_eq!(engine.history_count().unwrap(), 0);

        assert!(engine
            .remember(
                &result,
                &ctx,
                &Mode::default_dictation(),
                EntryKind::Dictation
            )
            .is_some());
        assert_eq!(engine.history_count().unwrap(), 1);
    }

    #[test]
    fn unknown_active_mode_is_rejected() {
        let engine = DictationEngine::new();
        assert!(engine.set_active_mode("nope".into()).is_err());
        assert!(engine.set_active_mode("raw".into()).is_ok());
    }
}
