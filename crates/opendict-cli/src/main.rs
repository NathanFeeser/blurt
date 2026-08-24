//! `opendict` — drive the real pipeline from a terminal.
//!
//! This exists so the production code path is runnable without a UI. The eval
//! harness (DictBench, Phase 2) shells out to this, which is the only way to be
//! sure the thing being scored is the thing that ships.

mod wav;

use std::collections::HashMap;
use std::path::PathBuf;

use anyhow::{bail, Context, Result};
use clap::{Parser, Subcommand};
use opendict_core::{
    AppContext, DictationEngine, Mode, ProviderCredentials, Vocabulary, SAMPLE_RATE,
};

#[derive(Parser)]
#[command(name = "opendict", version, about = "OpenDict pipeline CLI")]
struct Cli {
    #[command(subcommand)]
    command: Command,
}

#[derive(Subcommand)]
// clap subcommands are naturally lopsided; boxing the big variant would only
// obscure the argument definitions for no measurable gain in a CLI.
#[allow(clippy::large_enum_variant)]
enum Command {
    /// Transcribe a WAV file through the full pipeline.
    Transcribe {
        file: PathBuf,
        /// Mode id. Built in: `default`, `raw`.
        #[arg(long, default_value = "default")]
        mode: String,
        /// STT provider id (groq, openai, deepgram, ollama, vllm, lmstudio).
        #[arg(long)]
        stt_provider: Option<String>,
        #[arg(long)]
        stt_model: Option<String>,
        /// Cleanup provider id. Pass `none` to skip the LLM stage.
        #[arg(long)]
        llm_provider: Option<String>,
        /// Reasoning effort for models that support it: low, medium, high.
        /// Pass `none` to omit the parameter, which most local servers require.
        #[arg(long)]
        reasoning_effort: Option<String>,
        #[arg(long)]
        llm_model: Option<String>,
        /// BCP-47 language tag. Omit to auto-detect.
        #[arg(long)]
        language: Option<String>,
        /// Simulated frontmost app, e.g. com.tinyspeck.slackmacgap.
        #[arg(long)]
        app: Option<String>,
        /// Simulated text around the cursor.
        #[arg(long)]
        context: Option<String>,
        /// Comma-separated custom vocabulary.
        #[arg(long)]
        vocab: Option<String>,
        /// Always run cleanup, even when the skip gate says it is unnecessary.
        #[arg(long)]
        no_skip: bool,
        /// Emit JSON (what the eval harness consumes).
        #[arg(long)]
        json: bool,
    },
    /// Run only the cleanup stage on text supplied directly. Used by the eval
    /// harness so it scores the production prompt rather than a copy of it.
    Cleanup {
        text: String,
        #[arg(long)]
        llm_provider: Option<String>,
        #[arg(long)]
        llm_model: Option<String>,
        /// low | medium | high | none
        #[arg(long)]
        reasoning_effort: Option<String>,
        #[arg(long)]
        app: Option<String>,
        #[arg(long)]
        context: Option<String>,
        /// Bypass the skip gate so every case actually reaches the model.
        #[arg(long)]
        no_skip: bool,
    },

    /// Check that a provider's credentials work.
    Check { provider: String },
    /// List known provider ids and their default endpoints.
    Providers,
}

/// Load `.env`, searching upward from the working directory so the CLI works
/// from anywhere in the repo. Returns the file it found, for diagnostics.
///
/// This is a development convenience and applies to the CLI only. The shipped
/// apps read keys from the OS keychain and never from a file on disk — see the
/// privacy model in docs/ARCHITECTURE.md. `.env` is gitignored; keep it that way.
fn load_dotenv() -> Option<PathBuf> {
    match dotenvy::dotenv() {
        Ok(path) => Some(path),
        // Absent is the normal case when keys come from the shell instead.
        Err(e) if e.not_found() => None,
        Err(e) => {
            eprintln!("warning: could not read .env: {e}");
            None
        }
    }
}

/// Keys come from the environment here (directly, or via `.env`).
fn credentials_from_env() -> HashMap<String, ProviderCredentials> {
    let mut out = HashMap::new();
    for (id, key_var, url_var) in [
        ("groq", "GROQ_API_KEY", "GROQ_BASE_URL"),
        ("openai", "OPENAI_API_KEY", "OPENAI_BASE_URL"),
        ("deepgram", "DEEPGRAM_API_KEY", "DEEPGRAM_BASE_URL"),
        ("ollama", "OLLAMA_API_KEY", "OLLAMA_BASE_URL"),
        ("lmstudio", "LMSTUDIO_API_KEY", "LMSTUDIO_BASE_URL"),
        ("vllm", "VLLM_API_KEY", "VLLM_BASE_URL"),
        ("openai-compat", "OPENDICT_API_KEY", "OPENDICT_BASE_URL"),
    ] {
        let key = std::env::var(key_var).ok().filter(|k| !k.is_empty());
        let url = std::env::var(url_var).unwrap_or_default();
        if key.is_some() || !url.is_empty() {
            out.insert(
                id.to_string(),
                ProviderCredentials {
                    base_url: url,
                    api_key: key,
                },
            );
        }
    }
    out
}

/// A missing key is the single most common first-run failure. Say what to do
/// about it rather than making the user go read the source.
fn explain_missing_credentials(
    err: &opendict_core::DictError,
    dotenv_path: Option<&std::path::Path>,
) {
    let opendict_core::DictError::NotConfigured { provider, .. } = err else {
        return;
    };
    let var = match provider.as_str() {
        "groq" => "GROQ_API_KEY",
        "openai" => "OPENAI_API_KEY",
        "deepgram" => "DEEPGRAM_API_KEY",
        _ => "OPENDICT_API_KEY (with OPENDICT_BASE_URL)",
    };
    match dotenv_path {
        Some(p) => eprintln!("hint: set {var} in {}", p.display()),
        None => eprintln!("hint: cp .env.example .env, then set {var} in it"),
    }
}

#[tokio::main]
async fn main() -> Result<()> {
    let cli = Cli::parse();
    let dotenv_path = load_dotenv();
    let engine = DictationEngine::new();
    for (id, creds) in credentials_from_env() {
        engine.set_credentials(id, creds);
    }

    match cli.command {
        Command::Providers => {
            println!("{:<16} DEFAULT BASE URL", "ID");
            for id in ["groq", "openai", "deepgram", "ollama", "lmstudio", "vllm"] {
                println!(
                    "{:<16} {}",
                    id,
                    opendict_core::providers::default_base_url(id).unwrap_or("-")
                );
            }
            println!(
                "\nAny OpenAI-compatible endpoint also works via --stt-provider openai-compat"
            );
            println!("with OPENDICT_BASE_URL / OPENDICT_API_KEY set.");

            match &dotenv_path {
                Some(p) => println!("\nReading credentials from {}", p.display()),
                None => println!(
                    "\nNo .env found. Copy .env.example to .env, or export keys in your shell."
                ),
            }
            let mut configured: Vec<String> = credentials_from_env().into_keys().collect();
            configured.sort();
            if configured.is_empty() {
                println!("Configured: (none)");
            } else {
                println!("Configured: {}", configured.join(", "));
            }
        }

        Command::Check { provider } => match engine.check_credentials(provider.clone()).await {
            Ok(true) => println!("{provider}: ok"),
            Ok(false) => println!("{provider}: reachable, but /models did not return success"),
            Err(e) => {
                eprintln!("{provider}: {e}");
                std::process::exit(1);
            }
        },

        Command::Cleanup {
            text,
            llm_provider,
            llm_model,
            reasoning_effort,
            app,
            context,
            no_skip,
        } => {
            let mut m = Mode::default_dictation();
            if let Some(c) = m.cleanup.as_mut() {
                if let Some(p) = llm_provider {
                    c.provider_id = p;
                }
                if let Some(x) = llm_model {
                    c.model = x;
                }
                match reasoning_effort.as_deref() {
                    Some("none") => c.reasoning_effort = None,
                    Some(e) => c.reasoning_effort = Some(e.to_string()),
                    None => {}
                }
            }
            m.allow_cleanup_skip = !no_skip;
            m.id = "cli".into();
            engine.set_modes(vec![m]);
            engine.set_active_mode("cli".into())?;

            let ctx = AppContext {
                bundle_id: app.clone(),
                app_name: app,
                window_title: None,
                surrounding_text: context,
                selected_text: None,
            };

            let result = engine
                .clean_up_text(text, ctx)
                .await
                .inspect_err(|e| explain_missing_credentials(e, dotenv_path.as_deref()))?;

            println!(
                "{}",
                serde_json::json!({
                    "raw_text": result.raw_text,
                    "final_text": result.final_text,
                    "cleanup_ran": result.cleanup_ran,
                    "cleanup_error": result.cleanup_error,
                    "cleanup_ms": result.timings.cleanup_ms,
                })
            );
        }

        Command::Transcribe {
            file,
            mode,
            stt_provider,
            stt_model,
            llm_provider,
            llm_model,
            reasoning_effort,
            language,
            app,
            context,
            vocab,
            no_skip,
            json,
        } => {
            let bytes =
                std::fs::read(&file).with_context(|| format!("reading {}", file.display()))?;
            let parsed = wav::read(&bytes)?;
            let samples = wav::to_mono_16k(&parsed, SAMPLE_RATE);
            if samples.is_empty() {
                bail!("{} contains no audio", file.display());
            }

            let mut m = match mode.as_str() {
                "raw" => Mode::raw(),
                _ => Mode::default_dictation(),
            };
            if let Some(p) = stt_provider {
                m.stt.provider_id = p;
            }
            if let Some(x) = stt_model {
                m.stt.model = x;
            }
            if let Some(l) = language {
                m.stt.language = Some(l);
            }
            match llm_provider.as_deref() {
                Some("none") => m.cleanup = None,
                Some(p) => {
                    let model = llm_model.clone().unwrap_or_else(|| {
                        m.cleanup
                            .as_ref()
                            .map(|c| c.model.clone())
                            .unwrap_or_default()
                    });
                    m.cleanup = Some(opendict_core::LlmConfig {
                        provider_id: p.to_string(),
                        model,
                        reasoning_effort: m
                            .cleanup
                            .as_ref()
                            .and_then(|c| c.reasoning_effort.clone()),
                    });
                }
                None => {
                    if let (Some(c), Some(x)) = (m.cleanup.as_mut(), llm_model) {
                        c.model = x;
                    }
                }
            }
            match reasoning_effort.as_deref() {
                Some("none") => {
                    if let Some(c) = m.cleanup.as_mut() {
                        c.reasoning_effort = None;
                    }
                }
                Some(effort) => {
                    if let Some(c) = m.cleanup.as_mut() {
                        c.reasoning_effort = Some(effort.to_string());
                    }
                }
                None => {}
            }
            m.allow_cleanup_skip = !no_skip;
            m.id = "cli".into();
            engine.set_modes(vec![m]);
            engine.set_active_mode("cli".into())?;

            if let Some(v) = vocab {
                engine.set_vocabulary(Vocabulary {
                    terms: v.split(',').map(|s| s.trim().to_string()).collect(),
                });
            }

            let ctx = AppContext {
                bundle_id: app.clone(),
                app_name: app,
                window_title: None,
                surrounding_text: context,
                selected_text: None,
            };

            let result = engine
                .transcribe(samples, ctx)
                .await
                .inspect_err(|e| explain_missing_credentials(e, dotenv_path.as_deref()))?;

            if json {
                println!(
                    "{}",
                    serde_json::json!({
                        "raw_text": result.raw_text,
                        "final_text": result.final_text,
                        "cleanup_ran": result.cleanup_ran,
                    "cleanup_error": result.cleanup_error,
                        "audio_duration_ms": result.audio_duration_ms,
                        "detected_language": result.detected_language,
                        "stt_provider": result.stt_provider,
                        "stt_model": result.stt_model,
                        "timings": {
                            "encode_ms": result.timings.encode_ms,
                            "stt_ms": result.timings.stt_ms,
                            "cleanup_ms": result.timings.cleanup_ms,
                            "total_ms": result.timings.total_ms,
                        },
                    })
                );
            } else {
                println!("{}", result.final_text);
                eprintln!();
                if result.cleanup_ran && result.raw_text != result.final_text {
                    eprintln!("  raw:      {}", result.raw_text);
                }
                if let Some(err) = &result.cleanup_error {
                    eprintln!("  cleanup FAILED, showing the raw transcript: {err}");
                }
                let cleanup_label = match (&result.cleanup_error, result.cleanup_ran) {
                    (Some(_), _) => " (failed)",
                    (None, true) => "",
                    (None, false) => " (skipped)",
                };
                eprintln!(
                    "  audio {}ms | stt {}ms | cleanup {}ms{} | total {}ms",
                    result.audio_duration_ms,
                    result.timings.stt_ms,
                    result.timings.cleanup_ms,
                    cleanup_label,
                    result.timings.total_ms,
                );
            }
        }
    }

    Ok(())
}
