//! Modes — superwhisper's abstraction, and the right one.
//!
//! A mode bundles {STT config, optional cleanup config, extra instructions,
//! app matching}. Users end up with a coding mode, an email mode, a Slack mode.
//! Modes are plain data so they can be serialized to a file and shared.

use serde::{Deserialize, Serialize};

use crate::error::DictError;

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
    /// `low` | `medium` | `high` for reasoning models. Leave `None` for any
    /// endpoint that might reject an unknown parameter — most local servers.
    #[serde(default)]
    pub reasoning_effort: Option<String>,
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
                // Cleanup is formatting, not reasoning. Measured: ~36% faster
                // than the default effort with identical results on
                // self-corrections and spoken formatting commands.
                reasoning_effort: Some("low".into()),
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

    /// The starter set. Chosen to demonstrate the axes a mode can vary on —
    /// tone, formatting, and whether the cleanup stage runs at all — rather than
    /// to be exhaustive. Users are expected to edit these.
    pub fn starter_set() -> Vec<Mode> {
        let stt = || SttConfig {
            provider_id: "groq".into(),
            model: "whisper-large-v3-turbo".into(),
            language: None,
        };
        let cleanup = || {
            Some(LlmConfig {
                provider_id: "groq".into(),
                model: "openai/gpt-oss-120b".into(),
                reasoning_effort: Some("low".into()),
            })
        };

        vec![
            Mode::default_dictation(),
            Mode {
                id: "chat".into(),
                name: "Chat".into(),
                stt: stt(),
                cleanup: cleanup(),
                cleanup_instructions: Some(
                    "This is a chat message. Keep it casual and conversational. Do not add \
                     greetings or sign-offs the speaker did not say. Short sentences are fine; \
                     so are sentence fragments if that is how they spoke."
                        .into(),
                ),
                app_matches: vec![
                    "slack".into(),
                    "discord".into(),
                    "messages".into(),
                    "whatsapp".into(),
                    "telegram".into(),
                ],
                allow_cleanup_skip: true,
            },
            Mode {
                id: "email".into(),
                name: "Email".into(),
                stt: stt(),
                cleanup: cleanup(),
                cleanup_instructions: Some(
                    "This is an email. Use complete sentences and standard punctuation. Break \
                     into paragraphs where the speaker changed subject. Do not invent a subject \
                     line, greeting, or sign-off."
                        .into(),
                ),
                app_matches: vec![
                    "mail".into(),
                    "superhuman".into(),
                    "outlook".into(),
                    "sparkmail".into(),
                ],
                allow_cleanup_skip: true,
            },
            Mode {
                id: "code".into(),
                name: "Code".into(),
                stt: stt(),
                cleanup: cleanup(),
                cleanup_instructions: Some(
                    "The speaker is in a code editor or terminal. Preserve identifiers, flags, \
                     and paths exactly as spoken, including case and punctuation such as \
                     underscores, hyphens, and dots. Do not capitalise the first word if it is \
                     an identifier or a command. Do not add trailing punctuation to a command."
                        .into(),
                ),
                app_matches: vec![
                    "vscode".into(),
                    "cursor".into(),
                    "xcode".into(),
                    "terminal".into(),
                    "iterm".into(),
                    "ghostty".into(),
                    "warp".into(),
                    "jetbrains".into(),
                ],
                allow_cleanup_skip: true,
            },
        ]
    }

    /// Fully offline: on-device transcription, no cleanup model, nothing leaves
    /// the machine. Offered as a preset because "private" should be one click,
    /// not a form the user has to assemble correctly.
    pub fn private() -> Self {
        Self {
            id: "private".into(),
            name: "Private (on-device)".into(),
            stt: SttConfig {
                provider_id: "local".into(),
                model: "large-v3-turbo".into(),
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
    fn the_private_mode_sends_nothing_anywhere() {
        let m = Mode::private();
        assert!(
            m.cleanup.is_none(),
            "a cleanup model would send the transcript off-device"
        );
        assert_eq!(m.stt.provider_id, "local");
    }

    #[test]
    fn a_new_mode_inherits_the_defaults_but_claims_no_apps() {
        let m = new_mode("x".into(), "X".into());
        assert_eq!(m.id, "x");
        assert_eq!(m.name, "X");
        assert!(
            m.app_matches.is_empty(),
            "a new mode must not steal another's apps"
        );
        assert_eq!(m.stt.model, Mode::default_dictation().stt.model);
        assert!(m.cleanup.is_some());
    }

    #[test]
    fn the_starter_set_has_no_duplicate_ids() {
        let modes = Mode::starter_set();
        let mut ids: Vec<&str> = modes.iter().map(|m| m.id.as_str()).collect();
        ids.sort_unstable();
        let before = ids.len();
        ids.dedup();
        assert_eq!(
            ids.len(),
            before,
            "duplicate mode ids would make one unreachable"
        );
    }

    #[test]
    fn the_starter_set_resolves_real_bundle_ids() {
        let modes = Mode::starter_set();
        let active = Mode::default_dictation();
        for (bundle, expected) in [
            ("com.tinyspeck.slackmacgap", "chat"),
            ("com.apple.mail", "email"),
            ("com.microsoft.VSCode", "code"),
            ("com.apple.Safari", "default"),
        ] {
            assert_eq!(
                resolve_mode(&modes, &active, Some(bundle)).id,
                expected,
                "{bundle} resolved to the wrong mode"
            );
        }
    }

    #[test]
    fn modes_survive_a_json_round_trip_through_the_ffi_helpers() {
        let modes = Mode::starter_set();
        let restored = modes_from_json(modes_to_json(modes.clone())).unwrap();
        assert_eq!(restored.len(), modes.len());
        assert_eq!(
            restored[1].cleanup_instructions,
            modes[1].cleanup_instructions
        );
        assert_eq!(restored[3].app_matches, modes[3].app_matches);
    }

    #[test]
    fn malformed_json_is_an_error_not_a_panic() {
        assert!(modes_from_json("not json".into()).is_err());
        assert!(modes_from_json("{}".into()).is_err());
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

// ---------------------------------------------------------------------------
// Serialization, exported so every shell reads and writes the same format.
// ---------------------------------------------------------------------------

/// The starter set, for a first launch.
#[uniffi::export]
pub fn starter_modes() -> Vec<Mode> {
    Mode::starter_set()
}

/// The offline preset, for the settings UI.
#[uniffi::export]
pub fn private_mode() -> Mode {
    Mode::private()
}

/// A blank mode for the "add mode" button.
///
/// Exported rather than constructed in each shell: three shells inventing their
/// own default field values is exactly how they drift apart.
#[uniffi::export]
pub fn new_mode(id: String, name: String) -> Mode {
    Mode {
        id,
        name,
        app_matches: vec![],
        ..Mode::default_dictation()
    }
}

/// Serialize modes for storage or for sharing as a file.
///
/// Lives in the core rather than each shell so a mode exported on a Mac loads
/// unchanged on Windows, and so there is exactly one schema to version.
#[uniffi::export]
pub fn modes_to_json(modes: Vec<Mode>) -> String {
    serde_json::to_string_pretty(&modes).unwrap_or_else(|_| "[]".to_string())
}

/// Parse modes from storage or an imported file.
#[uniffi::export]
pub fn modes_from_json(json: String) -> Result<Vec<Mode>, DictError> {
    serde_json::from_str(&json).map_err(|e| DictError::BadResponse {
        provider: "modes".into(),
        detail: e.to_string(),
    })
}
