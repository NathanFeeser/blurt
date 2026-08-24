//! Modes — superwhisper's abstraction, and the right one.
//!
//! A mode bundles {STT config, optional cleanup config, extra instructions,
//! app matching}. Users end up with a coding mode, an email mode, a Slack mode.
//! Modes are plain data so they can be serialized to a file and shared.

use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Serialize, Deserialize, uniffi::Record)]
pub struct SttConfig {
    /// Provider id: `groq`, `openai`, `deepgram`, `ollama`, `vllm`, `openai-compat`.
    pub provider_id: String,
    pub model: String,
    /// `None` means auto-detect.
    pub language: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, uniffi::Record)]
pub struct LlmConfig {
    pub provider_id: String,
    pub model: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, uniffi::Record)]
pub struct Mode {
    pub id: String,
    pub name: String,
    pub stt: SttConfig,
    /// `None` disables the cleanup stage entirely — raw ASR straight to the app.
    /// Useful for code, and for users who want maximum speed.
    pub cleanup: Option<LlmConfig>,
    /// Appended to the base system prompt. Never replaces it.
    pub cleanup_instructions: Option<String>,
    /// Bundle ids / process names this mode auto-activates for.
    pub app_matches: Vec<String>,
    /// When false, always run cleanup even if `needs_cleanup` says it's unnecessary.
    /// Off by default: the skip gate is a latency optimization users can disable
    /// if they don't trust it.
    pub allow_cleanup_skip: bool,
}

impl Mode {
    /// The out-of-box mode: Groq's turbo Whisper plus a small fast cleanup model.
    /// Cheapest credible configuration — see the cost table in docs/RESEARCH.md.
    pub fn default_dictation() -> Self {
        Self {
            id: "default".into(),
            name: "Dictation".into(),
            stt: SttConfig {
                provider_id: "groq".into(),
                model: "whisper-large-v3-turbo".into(),
                language: None,
            },
            cleanup: Some(LlmConfig {
                provider_id: "groq".into(),
                // Measured 2026-08-24 against live Groq: gpt-oss-20b returns
                // dictation verbatim — it does not apply self-corrections at
                // all — while 120b handles them at comparable latency (~430 ms).
                // Phase 2 replaces this judgement call with DictBench.
                model: "openai/gpt-oss-120b".into(),
            }),
            cleanup_instructions: None,
            app_matches: vec![],
            allow_cleanup_skip: true,
        }
    }

    /// Raw transcription, no LLM hop. Fastest possible path.
    pub fn raw() -> Self {
        Self {
            id: "raw".into(),
            name: "Raw".into(),
            stt: SttConfig {
                provider_id: "groq".into(),
                model: "whisper-large-v3-turbo".into(),
                language: None,
            },
            cleanup: None,
            cleanup_instructions: None,
            app_matches: vec![],
            allow_cleanup_skip: true,
        }
    }

    /// Does this mode claim the given app?
    pub fn matches_app(&self, bundle_id: Option<&str>) -> bool {
        let Some(id) = bundle_id else { return false };
        let id = id.to_lowercase();
        self.app_matches
            .iter()
            .any(|m| !m.is_empty() && id.contains(&m.to_lowercase()))
    }
}

/// Pick the mode for the current app: the first mode claiming this bundle id,
/// else the explicitly active mode.
pub fn resolve_mode<'a>(modes: &'a [Mode], active: &'a Mode, bundle_id: Option<&str>) -> &'a Mode {
    modes
        .iter()
        .find(|m| m.matches_app(bundle_id))
        .unwrap_or(active)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn mode_for(id: &str, matches: &[&str]) -> Mode {
        let mut m = Mode::default_dictation();
        m.id = id.into();
        m.app_matches = matches.iter().map(|s| s.to_string()).collect();
        m
    }

    #[test]
    fn app_matching_is_substring_and_case_insensitive() {
        let m = mode_for("code", &["com.microsoft.VSCode"]);
        assert!(m.matches_app(Some("com.microsoft.vscode")));
        assert!(!m.matches_app(Some("com.tinyspeck.slackmacgap")));
        assert!(!m.matches_app(None));
    }

    #[test]
    fn empty_match_patterns_never_claim_an_app() {
        let m = mode_for("bad", &[""]);
        assert!(!m.matches_app(Some("com.apple.Safari")));
    }

    #[test]
    fn resolve_falls_back_to_the_active_mode() {
        let active = mode_for("active", &[]);
        let modes = vec![mode_for("code", &["vscode"])];
        assert_eq!(
            resolve_mode(&modes, &active, Some("com.apple.Safari")).id,
            "active"
        );
        assert_eq!(
            resolve_mode(&modes, &active, Some("com.microsoft.VSCode")).id,
            "code"
        );
    }

    #[test]
    fn modes_round_trip_through_json() {
        let m = Mode::default_dictation();
        let json = serde_json::to_string(&m).unwrap();
        let back: Mode = serde_json::from_str(&json).unwrap();
        assert_eq!(back.id, m.id);
        assert_eq!(back.stt.model, m.stt.model);
    }
}
