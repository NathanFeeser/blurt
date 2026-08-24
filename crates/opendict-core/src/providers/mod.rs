//! Provider adapters.
//!
//! Two traits, many implementations. The point of the whole project is that a
//! user can point either stage at anything — a hosted API, their own vLLM box,
//! or Ollama on localhost — so nothing above this module may assume a vendor.

pub mod llm;
pub mod stt;

pub use llm::{ChatMessage, LlmProvider, LlmRequest, OpenAiCompatLlm, Role};
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
}

impl SttKind {
    pub fn from_id(id: &str) -> Result<Self> {
        match id {
            "openai-compat" | "groq" | "openai" | "local" => Ok(SttKind::OpenAiCompat),
            "deepgram" => Ok(SttKind::Deepgram),
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
