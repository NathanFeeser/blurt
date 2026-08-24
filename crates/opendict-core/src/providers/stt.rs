use async_trait::async_trait;
use serde::Deserialize;

use super::{classify_http_error, ProviderCredentials};
use crate::error::{from_reqwest, DictError, Result};

/// One transcription request. `biasing_prompt` is the lever for custom
/// vocabulary — note that Whisper only consumes the last 224 tokens of it and
/// weights the tail most heavily, so callers must put rare terms last.
/// See `crate::vocab::biasing_prompt`.
#[derive(Debug, Clone)]
pub struct SttRequest {
    pub wav: Vec<u8>,
    /// BCP-47 tag. `None` means let the provider auto-detect.
    pub language: Option<String>,
    pub biasing_prompt: Option<String>,
}

/// What came back. `text` is deliberately raw — no cleanup happens at this
/// layer, because the eval harness needs to score the two stages separately.
#[derive(Debug, Clone, uniffi::Record)]
pub struct Transcript {
    pub text: String,
    pub detected_language: Option<String>,
    pub provider: String,
    pub model: String,
    pub latency_ms: u64,
}

#[async_trait]
pub trait SttProvider: Send + Sync {
    fn name(&self) -> &str;
    fn model(&self) -> &str;
    async fn transcribe(&self, req: SttRequest) -> Result<Transcript>;
}

// ---------------------------------------------------------------------------
// OpenAI-compatible: Groq, OpenAI, vLLM, Ollama, LM Studio, ...
// ---------------------------------------------------------------------------

pub struct OpenAiCompatStt {
    creds: ProviderCredentials,
    model: String,
    label: String,
    http: reqwest::Client,
}

impl OpenAiCompatStt {
    /// Takes a shared client on purpose: a per-request client means a fresh TLS
    /// handshake every dictation, which is ~100 ms of a 600 ms budget.
    pub fn new(
        http: reqwest::Client,
        creds: ProviderCredentials,
        model: impl Into<String>,
        label: impl Into<String>,
    ) -> Self {
        Self {
            creds,
            model: model.into(),
            label: label.into(),
            http,
        }
    }
}

#[derive(Deserialize)]
struct OpenAiTranscription {
    text: String,
    #[serde(default)]
    language: Option<String>,
}

#[async_trait]
impl SttProvider for OpenAiCompatStt {
    fn name(&self) -> &str {
        &self.label
    }
    fn model(&self) -> &str {
        &self.model
    }

    async fn transcribe(&self, req: SttRequest) -> Result<Transcript> {
        let started = std::time::Instant::now();
        let url = format!(
            "{}/audio/transcriptions",
            self.creds.base_url.trim_end_matches('/')
        );

        let part = reqwest::multipart::Part::bytes(req.wav)
            .file_name("audio.wav")
            .mime_str("audio/wav")
            .map_err(|e| from_reqwest(&self.label, e))?;

        let mut form = reqwest::multipart::Form::new()
            .text("model", self.model.clone())
            .text("response_format", "json")
            .part("file", part);

        if let Some(lang) = req.language {
            form = form.text("language", lang);
        }
        if let Some(prompt) = req.biasing_prompt {
            form = form.text("prompt", prompt);
        }

        let mut builder = self.http.post(&url).multipart(form);
        if let Some(key) = &self.creds.api_key {
            builder = builder.bearer_auth(key);
        }

        let resp = builder
            .send()
            .await
            .map_err(|e| from_reqwest(&self.label, e))?;

        if !resp.status().is_success() {
            return Err(classify_http_error(&self.label, resp).await);
        }

        let parsed: OpenAiTranscription =
            resp.json().await.map_err(|e| DictError::BadResponse {
                provider: self.label.clone(),
                detail: e.to_string(),
            })?;

        Ok(Transcript {
            text: parsed.text.trim().to_string(),
            detected_language: parsed.language,
            provider: self.label.clone(),
            model: self.model.clone(),
            latency_ms: started.elapsed().as_millis() as u64,
        })
    }
}

// ---------------------------------------------------------------------------
// Deepgram — different wire shape, kept here to prove the trait isn't just
// "OpenAI with extra steps".
// ---------------------------------------------------------------------------

pub struct DeepgramStt {
    creds: ProviderCredentials,
    model: String,
    http: reqwest::Client,
}

impl DeepgramStt {
    pub fn new(
        http: reqwest::Client,
        creds: ProviderCredentials,
        model: impl Into<String>,
    ) -> Self {
        Self {
            creds,
            model: model.into(),
            http,
        }
    }
}

#[derive(Deserialize)]
struct DgResponse {
    results: DgResults,
}
#[derive(Deserialize)]
struct DgResults {
    channels: Vec<DgChannel>,
}
#[derive(Deserialize)]
struct DgChannel {
    alternatives: Vec<DgAlternative>,
    #[serde(default)]
    detected_language: Option<String>,
}
#[derive(Deserialize)]
struct DgAlternative {
    transcript: String,
}

#[async_trait]
impl SttProvider for DeepgramStt {
    fn name(&self) -> &str {
        "deepgram"
    }
    fn model(&self) -> &str {
        &self.model
    }

    async fn transcribe(&self, req: SttRequest) -> Result<Transcript> {
        let started = std::time::Instant::now();
        let key = self
            .creds
            .api_key
            .as_ref()
            .ok_or(DictError::NotConfigured {
                provider: "deepgram".into(),
                detail: "an API key is required".into(),
            })?;

        let mut url = format!(
            "{}/listen?model={}&smart_format=true&punctuate=true",
            self.creds.base_url.trim_end_matches('/'),
            self.model
        );
        match req.language.as_deref() {
            Some(lang) => url.push_str(&format!("&language={lang}")),
            None => url.push_str("&detect_language=true"),
        }
        // Deepgram's equivalent of a biasing prompt is per-term keyword boosting.
        if let Some(prompt) = &req.biasing_prompt {
            for term in prompt.split(", ").filter(|t| !t.is_empty()).take(100) {
                url.push_str(&format!("&keyterm={}", urlencode(term)));
            }
        }

        let resp = self
            .http
            .post(&url)
            .header("Authorization", format!("Token {key}"))
            .header("Content-Type", "audio/wav")
            .body(req.wav)
            .send()
            .await
            .map_err(|e| from_reqwest("deepgram", e))?;

        if !resp.status().is_success() {
            return Err(classify_http_error("deepgram", resp).await);
        }

        let parsed: DgResponse = resp.json().await.map_err(|e| DictError::BadResponse {
            provider: "deepgram".into(),
            detail: e.to_string(),
        })?;

        let channel =
            parsed
                .results
                .channels
                .into_iter()
                .next()
                .ok_or_else(|| DictError::BadResponse {
                    provider: "deepgram".into(),
                    detail: "no channels in response".into(),
                })?;
        let detected_language = channel.detected_language;
        let text = channel
            .alternatives
            .into_iter()
            .next()
            .map(|a| a.transcript)
            .unwrap_or_default();

        Ok(Transcript {
            text: text.trim().to_string(),
            detected_language,
            provider: "deepgram".into(),
            model: self.model.clone(),
            latency_ms: started.elapsed().as_millis() as u64,
        })
    }
}

fn urlencode(s: &str) -> String {
    s.bytes()
        .map(|b| match b {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'_' | b'.' | b'~' => {
                (b as char).to_string()
            }
            b' ' => "+".to_string(),
            other => format!("%{other:02X}"),
        })
        .collect()
}

#[cfg(test)]
mod tests {
    #[test]
    fn urlencode_handles_spaces_and_symbols() {
        assert_eq!(super::urlencode("Kubernetes v1.2"), "Kubernetes+v1.2");
        assert_eq!(super::urlencode("a&b"), "a%26b");
    }
}
