//! Orchestration: audio in, finished text out, with timings for every hop.
//!
//! The timings are not diagnostics — they are the product spec. docs/ARCHITECTURE.md
//! commits to p50 <= 600 ms and p95 <= 1.2 s from hotkey release to inserted text,
//! and nothing enforces that unless every run reports where the time went.

use std::sync::Arc;

use crate::audio::{encode_wav_pcm16, SAMPLE_RATE};
use crate::cleanup::{build_cleanup_request, build_command_request, needs_cleanup};
use crate::context::AppContext;
use crate::error::{DictError, Result};
use crate::mode::Mode;
use crate::providers::{LlmProvider, SttProvider, SttRequest, Transcript};
use crate::vocab::Vocabulary;

/// Where the wall-clock went. All values in milliseconds.
#[derive(Debug, Clone, Default, uniffi::Record)]
pub struct Timings {
    pub encode_ms: u64,
    pub stt_ms: u64,
    pub cleanup_ms: u64,
    pub total_ms: u64,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct DictationResult {
    /// Which mode produced this. Reported by the core rather than inferred by
    /// the shell: a UI that recomputes app-matching itself can disagree with
    /// what actually ran, which is worse than showing nothing.
    pub mode_id: String,
    pub mode_name: String,
    /// Straight from the ASR, before any LLM touched it. Kept because the eval
    /// harness scores the two stages separately, and because "show me what I
    /// actually said" is a feature.
    pub raw_text: String,
    /// What gets inserted into the app.
    pub final_text: String,
    /// True only when cleanup ran *and* succeeded. False both when the skip
    /// gate declined to run it and when it ran and failed — check
    /// `cleanup_error` to tell those apart.
    pub cleanup_ran: bool,
    /// Set when cleanup was attempted and failed. The pipeline degrades to the
    /// raw transcript rather than losing the user's words, but a failure that
    /// nobody surfaces looks exactly like a model that silently does nothing —
    /// which is how a dead default model can hide for weeks.
    pub cleanup_error: Option<String>,
    pub audio_duration_ms: u64,
    pub detected_language: Option<String>,
    pub stt_provider: String,
    pub stt_model: String,
    pub timings: Timings,
}

impl DictationResult {
    /// Real-time factor: processing time over audio duration. Below 1.0 means we
    /// finished faster than the user spoke.
    pub fn rtf(&self) -> f64 {
        if self.audio_duration_ms == 0 {
            return 0.0;
        }
        self.timings.total_ms as f64 / self.audio_duration_ms as f64
    }
}

/// The two provider slots, resolved for a specific mode.
pub struct Stages {
    pub stt: Arc<dyn SttProvider>,
    pub cleanup: Option<Arc<dyn LlmProvider>>,
}

/// Run a full dictation. `samples` is 16 kHz mono f32 (what `AudioCapture::stop`
/// returns).
pub async fn run_dictation(
    samples: &[f32],
    stages: &Stages,
    mode: &Mode,
    ctx: &AppContext,
    vocab: &Vocabulary,
) -> Result<DictationResult> {
    let started = std::time::Instant::now();
    if samples.is_empty() {
        return Err(DictError::NoAudio);
    }
    let audio_duration_ms = (samples.len() as u64 * 1000) / SAMPLE_RATE as u64;

    let encode_start = std::time::Instant::now();
    let wav = encode_wav_pcm16(samples, SAMPLE_RATE);
    let encode_ms = encode_start.elapsed().as_millis() as u64;

    let transcript: Transcript = stages
        .stt
        .transcribe(SttRequest {
            wav,
            language: mode.stt.language.clone(),
            biasing_prompt: vocab.biasing_prompt(),
        })
        .await?;

    let raw_text = transcript.text.clone();

    // Nothing was said. Return early rather than paying for a cleanup call that
    // will hallucinate something into the silence — a real and well-known
    // Whisper failure mode.
    if raw_text.trim().is_empty() {
        return Ok(DictationResult {
            mode_id: mode.id.clone(),
            mode_name: mode.name.clone(),
            raw_text,
            final_text: String::new(),
            cleanup_ran: false,
            cleanup_error: None,
            audio_duration_ms,
            detected_language: transcript.detected_language,
            stt_provider: transcript.provider,
            stt_model: transcript.model,
            timings: Timings {
                encode_ms,
                stt_ms: transcript.latency_ms,
                cleanup_ms: 0,
                total_ms: started.elapsed().as_millis() as u64,
            },
        });
    }

    let cleaned = clean_up(&raw_text, stages, mode, ctx).await;
    let (final_text, cleanup_ran, cleanup_error, cleanup_ms) =
        (cleaned.text, cleaned.ran, cleaned.error, cleaned.elapsed_ms);

    Ok(DictationResult {
        mode_id: mode.id.clone(),
        mode_name: mode.name.clone(),
        raw_text,
        final_text,
        cleanup_ran,
        cleanup_error,
        audio_duration_ms,
        detected_language: transcript.detected_language,
        stt_provider: transcript.provider,
        stt_model: transcript.model,
        timings: Timings {
            encode_ms,
            stt_ms: transcript.latency_ms,
            cleanup_ms,
            total_ms: started.elapsed().as_millis() as u64,
        },
    })
}

/// Outcome of the cleanup stage on its own.
pub struct Cleaned {
    pub text: String,
    pub ran: bool,
    pub error: Option<String>,
    pub elapsed_ms: u64,
}

/// Run the cleanup stage against an already-transcribed string.
///
/// Public so the eval harness can score cleanup without audio, which removes
/// STT variance from the measurement. Sharing this function with
/// `run_dictation` is the point: an eval that scores a reimplementation of the
/// prompt is scoring the wrong thing.
pub async fn clean_up(raw_text: &str, stages: &Stages, mode: &Mode, ctx: &AppContext) -> Cleaned {
    let mut out = Cleaned {
        text: raw_text.to_string(),
        ran: false,
        error: None,
        elapsed_ms: 0,
    };

    let Some(llm) = &stages.cleanup else {
        return out;
    };
    if mode.allow_cleanup_skip && !needs_cleanup(raw_text) {
        return out;
    }

    let started = std::time::Instant::now();
    match llm
        .complete(build_cleanup_request(raw_text, mode, ctx))
        .await
    {
        Ok(cleaned) => {
            let candidate = sanitize_llm_output(&cleaned, raw_text);
            if dropped_too_much(raw_text, &candidate) {
                // Losing half a sentence is the worst failure this app can
                // have: it looks like a successful dictation. Keep the raw
                // transcript and say so.
                tracing::warn!("cleanup dropped too much text; keeping the raw transcript");
                out.error = Some(
                    "cleanup returned far less text than was dictated; kept the raw transcript"
                        .into(),
                );
            } else {
                out.text = candidate;
                out.ran = true;
            }
        }
        Err(e) => {
            // Degrade, don't fail. The user said something; giving them the raw
            // transcript beats an error dialog and lost words. But record why.
            tracing::warn!(error = %e, "cleanup failed; falling back to raw transcript");
            out.error = Some(e.to_string());
        }
    }
    out.elapsed_ms = started.elapsed().as_millis() as u64;
    out
}

/// Command mode: transcribe the spoken instruction, apply it to the selection.
pub async fn run_command(
    samples: &[f32],
    stages: &Stages,
    mode: &Mode,
    ctx: &AppContext,
    vocab: &Vocabulary,
) -> Result<DictationResult> {
    let started = std::time::Instant::now();
    let selection = ctx.selected_text.clone().unwrap_or_default();
    if selection.trim().is_empty() {
        return Err(DictError::NotConfigured {
            provider: "command mode".into(),
            detail: "no text is selected".into(),
        });
    }
    let llm = stages.cleanup.as_ref().ok_or(DictError::NotConfigured {
        provider: "command mode".into(),
        detail: "this mode has no cleanup model configured".into(),
    })?;

    if samples.is_empty() {
        return Err(DictError::NoAudio);
    }
    let audio_duration_ms = (samples.len() as u64 * 1000) / SAMPLE_RATE as u64;

    let encode_start = std::time::Instant::now();
    let wav = encode_wav_pcm16(samples, SAMPLE_RATE);
    let encode_ms = encode_start.elapsed().as_millis() as u64;

    let transcript = stages
        .stt
        .transcribe(SttRequest {
            wav,
            language: mode.stt.language.clone(),
            biasing_prompt: vocab.biasing_prompt(),
        })
        .await?;

    if transcript.text.trim().is_empty() {
        return Err(DictError::NoAudio);
    }

    let t = std::time::Instant::now();
    let out = llm
        .complete(build_command_request(&transcript.text, &selection, mode))
        .await?;
    let cleanup_ms = t.elapsed().as_millis() as u64;

    Ok(DictationResult {
        mode_id: mode.id.clone(),
        mode_name: mode.name.clone(),
        raw_text: transcript.text,
        final_text: sanitize_llm_output(&out, &selection),
        cleanup_ran: true,
        cleanup_error: None,
        audio_duration_ms,
        detected_language: transcript.detected_language,
        stt_provider: transcript.provider,
        stt_model: transcript.model,
        timings: Timings {
            encode_ms,
            stt_ms: transcript.latency_ms,
            cleanup_ms,
            total_ms: started.elapsed().as_millis() as u64,
        },
    })
}

/// Did cleanup lose a substantial part of what the user said?
///
/// Only applied to longer dictations. Short utterances legitimately shrink a
/// lot — "Um, so I was thinking we could ship on Tuesday. Wait, no, Friday."
/// correctly becomes "We could ship Friday.", a third of the length — so a
/// ratio check on short input would fire constantly on correct output. Over a
/// few hundred characters, though, no honest cleanup halves the text; that is a
/// model deciding to summarise.
fn dropped_too_much(raw: &str, cleaned: &str) -> bool {
    /// Below this, self-corrections dominate and big shrinkage is normal.
    const MIN_CHARS_TO_CHECK: usize = 400;

    let raw_len = raw.chars().count();
    if raw_len < MIN_CHARS_TO_CHECK {
        return false;
    }
    cleaned.chars().count() * 2 < raw_len
}

/// Strip the wrappers small models habitually add, and refuse output that is
/// obviously not a cleanup of the input.
///
/// Models below ~8B routinely return ```fenced blocks``` or "Here is the cleaned
/// text:" no matter how the prompt is worded. Since the output goes straight
/// into the user's document, we defend here rather than trusting the prompt.
fn sanitize_llm_output(out: &str, fallback: &str) -> String {
    // Reasoning models emit their chain of thought inline. Users will point this
    // at one — it is the default on several providers — and that text must never
    // reach their document. Strip complete blocks; treat an unterminated one as
    // a truncated response and fall back to the raw transcript.
    let stripped = strip_reasoning(out);
    let Some(stripped) = stripped else {
        return fallback.trim().to_string();
    };
    let mut s = stripped.trim();

    // Fenced code block wrapping the whole response.
    if s.starts_with("```") {
        if let Some(rest) = s.split_once('\n').map(|(_, r)| r) {
            if let Some(inner) = rest.rsplit_once("```") {
                s = inner.0.trim();
            }
        }
    }

    // Common preambles.
    for prefix in [
        "Here is the cleaned text:",
        "Here's the cleaned text:",
        "Cleaned text:",
        "Output:",
    ] {
        if let Some(rest) = s.strip_prefix(prefix) {
            s = rest.trim();
        }
    }

    // Symmetric quote wrapping that the speaker didn't ask for.
    if s.len() >= 2 && s.starts_with('"') && s.ends_with('"') && !fallback.starts_with('"') {
        s = &s[1..s.len() - 1];
    }

    if s.trim().is_empty() {
        return fallback.trim().to_string();
    }
    s.to_string()
}

/// Remove `<think>`/`<thinking>` blocks. Returns `None` when an opening tag has
/// no matching close, which means the model ran out of tokens mid-thought and
/// the real answer was never produced.
fn strip_reasoning(s: &str) -> Option<String> {
    const TAGS: [(&str, &str); 2] = [("<think>", "</think>"), ("<thinking>", "</thinking>")];
    let mut out = s.to_string();

    for (open, close) in TAGS {
        while let Some(start) = out.to_lowercase().find(open) {
            // Opened but never closed: the answer is missing, not merely messy,
            // so the caller falls back to the raw transcript.
            let rel_end = out.to_lowercase()[start..].find(close)?;
            let end = start + rel_end + close.len();
            out.replace_range(start..end, "");
        }
    }
    Some(out)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn command_mode_rejects_an_empty_selection() {
        let stages = Stages {
            stt: std::sync::Arc::new(NeverCalledStt),
            cleanup: None,
        };
        let err = run_command(
            &[0.1; 16000],
            &stages,
            &Mode::default_dictation(),
            &AppContext::default(),
            &Vocabulary::default(),
        )
        .await
        .unwrap_err();
        assert!(
            matches!(err, DictError::NotConfigured { .. }),
            "an empty selection must fail before any provider call: {err:?}"
        );
    }

    /// Panics if reached: these tests assert we bail out before any network use.
    struct NeverCalledStt;

    #[async_trait::async_trait]
    impl crate::providers::SttProvider for NeverCalledStt {
        fn name(&self) -> &str {
            "never"
        }
        fn model(&self) -> &str {
            "never"
        }
        async fn transcribe(
            &self,
            _req: crate::providers::SttRequest,
        ) -> Result<crate::providers::Transcript> {
            panic!("provider must not be called");
        }
    }

    #[test]
    fn short_utterances_may_shrink_a_lot() {
        // A real self-correction, correctly cleaned down to a third.
        let raw = "Um, so I was thinking we could ship on Tuesday. Wait, no, Friday.";
        assert!(!dropped_too_much(raw, "We could ship Friday."));
    }

    #[test]
    fn long_dictations_must_not_halve() {
        let raw = "word ".repeat(120); // 600 chars
        assert!(
            dropped_too_much(&raw, &"word ".repeat(40)),
            "a summary must be rejected"
        );
        assert!(
            !dropped_too_much(&raw, &"word ".repeat(100)),
            "normal tidying is fine"
        );
    }

    #[test]
    fn the_guard_ignores_short_input_entirely() {
        assert!(!dropped_too_much(
            "a short sentence that got much shorter",
            "short"
        ));
    }

    #[test]
    fn strips_reasoning_blocks() {
        assert_eq!(
            sanitize_llm_output("<think>Let me consider...</think>\nHello there.", "x"),
            "Hello there."
        );
        assert_eq!(
            sanitize_llm_output("<thinking>hmm</thinking>Hi.", "x"),
            "Hi."
        );
    }

    #[test]
    fn truncated_reasoning_falls_back_rather_than_leaking() {
        // gpt-oss / qwen style: hit max_tokens mid-thought, no answer produced.
        let leaked = "<think>Here is a thinking process:\n1. Analyze the input";
        assert_eq!(
            sanitize_llm_output(leaked, "the raw transcript"),
            "the raw transcript"
        );
    }

    #[test]
    fn reasoning_stripped_before_fences_and_quotes() {
        assert_eq!(
            sanitize_llm_output("<think>x</think>\n```\n\"Hi.\"\n```", "raw"),
            "Hi."
        );
    }

    #[test]
    fn text_containing_the_word_think_is_untouched() {
        assert_eq!(
            sanitize_llm_output("I think we should ship.", "x"),
            "I think we should ship."
        );
    }

    #[test]
    fn strips_code_fences() {
        assert_eq!(
            sanitize_llm_output("```\nHello there.\n```", "x"),
            "Hello there."
        );
        assert_eq!(
            sanitize_llm_output("```text\nHello there.\n```", "x"),
            "Hello there."
        );
    }

    #[test]
    fn strips_preambles() {
        assert_eq!(
            sanitize_llm_output("Here is the cleaned text: Hi.", "x"),
            "Hi."
        );
    }

    #[test]
    fn strips_added_quotes_but_keeps_intentional_ones() {
        assert_eq!(
            sanitize_llm_output("\"Hi there.\"", "Hi there"),
            "Hi there."
        );
        assert_eq!(
            sanitize_llm_output("\"Hi there.\"", "\"quoted"),
            "\"Hi there.\""
        );
    }

    #[test]
    fn empty_output_falls_back_to_the_raw_transcript() {
        assert_eq!(sanitize_llm_output("   ", "the original"), "the original");
        assert_eq!(
            sanitize_llm_output("```\n\n```", "the original"),
            "the original"
        );
    }

    #[test]
    fn rtf_is_zero_for_empty_audio() {
        let r = DictationResult {
            mode_id: "t".into(),
            mode_name: "T".into(),
            raw_text: String::new(),
            final_text: String::new(),
            cleanup_ran: false,
            cleanup_error: None,
            audio_duration_ms: 0,
            detected_language: None,
            stt_provider: "x".into(),
            stt_model: "y".into(),
            timings: Timings::default(),
        };
        assert_eq!(r.rtf(), 0.0);
    }
}
