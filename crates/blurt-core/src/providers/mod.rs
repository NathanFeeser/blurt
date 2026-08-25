//! Provider adapters.
//!
//! Two traits, many implementations. The point of the whole project is that a
//! user can point either stage at anything — a hosted API, their own vLLM box,
//! or Ollama on localhost — so nothing above this module may assume a vendor.

pub mod llm;
pub mod local;
pub mod stt;

pub use llm::{ChatMessage, LlmProvider, LlmRequest, OpenAiCompatLlm, Role};
pub use local::{LocalStt, LocalTranscriber};
pub use stt::{DeepgramStt, OpenAiCompatStt, SttProvider, SttRequest, Transcript};

use crate::error::{DictError, Result};

/// Where a provider's credentials and endpoint come from. Shells populate this
/// from the OS keychain; it is never serialized to disk by the core.
#[derive(Debug, Clone, uniffi::Record)]
pub struct ProviderCredentials {
    /// Base URL, e.g. `https://api.groq.com/openai/v1` or `http://localhost:11434/v1`.
    pub base_url: String,
    /// Omitted for most local servers.
    pub api_key: Option<String>,
}

/// Known provider shapes. `OpenAiCompat` is the catch-all and covers Groq,
/// OpenAI, Together, Ollama, LM Studio, vLLM, and anything else that speaks the
/// same wire format. The named variants exist only where the API genuinely differs.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum SttKind {
    OpenAiCompat,
    Deepgram,
    /// Runs on this machine, through a transcriber the shell provides.
    Local,
}

impl SttKind {
    pub fn from_id(id: &str) -> Result<Self> {
        match id {
            // Self-hosted servers speak the OpenAI wire format, so they are the
            // same adapter as the hosted ones. `local` is deliberately NOT here:
            // it means on-device inference, not a server on localhost.
            "openai-compat" | "groq" | "openai" | "ollama" | "lmstudio" | "vllm" => {
                Ok(SttKind::OpenAiCompat)
            }
            "deepgram" => Ok(SttKind::Deepgram),
            "local" | "whisperkit" | "on-device" => Ok(SttKind::Local),
            other => Err(DictError::UnknownProvider {
                id: other.to_string(),
            }),
        }
    }
}

/// Default endpoints, so the setup UI can prefill something sensible.
pub fn default_base_url(id: &str) -> Option<&'static str> {
    Some(match id {
        "groq" => "https://api.groq.com/openai/v1",
        "openai" => "https://api.openai.com/v1",
        "deepgram" => "https://api.deepgram.com/v1",
        "ollama" => "http://localhost:11434/v1",
        "lmstudio" => "http://localhost:1234/v1",
        "vllm" => "http://localhost:8000/v1",
        _ => return None,
    })
}

/// Map an HTTP failure onto something the UI can act on.
pub(crate) async fn classify_http_error(provider: &str, resp: reqwest::Response) -> DictError {
    let status = resp.status();
    let retry_after_ms = resp
        .headers()
        .get(reqwest::header::RETRY_AFTER)
        .and_then(|v| v.to_str().ok())
        .and_then(|v| v.parse::<f64>().ok())
        .map(|secs| (secs * 1000.0) as u64)
        .unwrap_or(1000);
    let body = resp.text().await.unwrap_or_default();

    match status.as_u16() {
        401 | 403 => DictError::Unauthorized {
            provider: provider.to_string(),
        },
        429 => DictError::RateLimited {
            provider: provider.to_string(),
            retry_after_ms,
        },
        s => DictError::ProviderRejected {
            provider: provider.to_string(),
            status: s,
            // Provider error bodies can be enormous HTML pages behind a proxy.
            body: body.chars().take(500).collect(),
        },
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn every_advertised_provider_id_resolves() {
        // The settings UI and `blurt providers` list these; each must map to
        // an adapter or the user gets "unknown provider" from a documented id.
        for id in [
            "groq",
            "openai",
            "deepgram",
            "ollama",
            "lmstudio",
            "vllm",
            "openai-compat",
        ] {
            assert!(SttKind::from_id(id).is_ok(), "{id} should resolve");
        }
    }

    #[test]
    fn local_means_on_device_not_a_localhost_server() {
        assert_eq!(SttKind::from_id("local").unwrap(), SttKind::Local);
        assert_eq!(SttKind::from_id("whisperkit").unwrap(), SttKind::Local);
        // A server on localhost is reached by its own id, not by "local".
        assert_eq!(SttKind::from_id("ollama").unwrap(), SttKind::OpenAiCompat);
    }

    #[test]
    fn unknown_ids_are_rejected() {
        assert!(SttKind::from_id("not-a-provider").is_err());
    }
}
