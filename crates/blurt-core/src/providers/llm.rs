use async_trait::async_trait;
use serde::{Deserialize, Serialize};

use super::{classify_http_error, ProviderCredentials};
use crate::error::{from_reqwest, DictError, Result};

#[derive(Debug, Clone, Copy, Serialize, PartialEq, Eq)]
#[serde(rename_all = "lowercase")]
pub enum Role {
    System,
    User,
    Assistant,
}

#[derive(Debug, Clone, Serialize)]
pub struct ChatMessage {
    pub role: Role,
    pub content: String,
}

impl ChatMessage {
    pub fn system(content: impl Into<String>) -> Self {
        Self {
            role: Role::System,
            content: content.into(),
        }
    }
    pub fn user(content: impl Into<String>) -> Self {
        Self {
            role: Role::User,
            content: content.into(),
        }
    }
    pub fn assistant(content: impl Into<String>) -> Self {
        Self {
            role: Role::Assistant,
            content: content.into(),
        }
    }
}

#[derive(Debug, Clone)]
pub struct LlmRequest {
    pub messages: Vec<ChatMessage>,
    pub temperature: f32,
    pub max_tokens: u32,
    /// `low` | `medium` | `high`, for models that reason before answering.
    ///
    /// Measured on gpt-oss-120b: `low` spends 8 reasoning tokens where the
    /// default spends ~240, cutting cleanup latency by roughly a third with no
    /// loss on self-corrections or spoken formatting commands. Cleanup is a
    /// formatting task, not a reasoning task.
    ///
    /// `None` omits the field entirely, because plenty of OpenAI-compatible
    /// servers reject parameters they do not recognise.
    pub reasoning_effort: Option<String>,
}

#[async_trait]
pub trait LlmProvider: Send + Sync {
    fn name(&self) -> &str;
    fn model(&self) -> &str;
    async fn complete(&self, req: LlmRequest) -> Result<String>;
}

/// Chat-completions over anything speaking the OpenAI wire format.
pub struct OpenAiCompatLlm {
    creds: ProviderCredentials,
    model: String,
    label: String,
    http: reqwest::Client,
}

impl OpenAiCompatLlm {
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

#[derive(Serialize)]
struct ChatRequestBody<'a> {
    model: &'a str,
    messages: &'a [ChatMessage],
    temperature: f32,
    max_tokens: u32,
    stream: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    reasoning_effort: Option<&'a str>,
}

#[derive(Deserialize)]
struct ChatResponse {
    choices: Vec<ChatChoice>,
}
#[derive(Deserialize)]
struct ChatChoice {
    message: ChatResponseMessage,
    /// "stop" when the model finished, "length" when it hit max_tokens.
    #[serde(default)]
    finish_reason: Option<String>,
}
#[derive(Deserialize)]
struct ChatResponseMessage {
    #[serde(default)]
    content: Option<String>,
}

#[async_trait]
impl LlmProvider for OpenAiCompatLlm {
    fn name(&self) -> &str {
        &self.label
    }
    fn model(&self) -> &str {
        &self.model
    }

    async fn complete(&self, req: LlmRequest) -> Result<String> {
        let url = format!(
            "{}/chat/completions",
            self.creds.base_url.trim_end_matches('/')
        );

        let body = ChatRequestBody {
            model: &self.model,
            messages: &req.messages,
            temperature: req.temperature,
            max_tokens: req.max_tokens,
            // Phase 1 turns this on and inserts tokens incrementally; see the
            // latency budget in docs/ARCHITECTURE.md.
            stream: false,
            reasoning_effort: req.reasoning_effort.as_deref(),
        };

        let mut builder = self.http.post(&url).json(&body);
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

        let parsed: ChatResponse = resp.json().await.map_err(|e| DictError::BadResponse {
            provider: self.label.clone(),
            detail: e.to_string(),
        })?;

        let choice = parsed
            .choices
            .into_iter()
            .next()
            .ok_or_else(|| DictError::BadResponse {
                provider: self.label.clone(),
                detail: "response contained no choices".into(),
            })?;

        // A truncated completion is worse than no completion: it silently
        // returns the first half of the user's sentence, which looks like a
        // successful cleanup. Treat it as a failure so the caller falls back to
        // the raw transcript and keeps every word the user said.
        if choice.finish_reason.as_deref() == Some("length") {
            return Err(DictError::BadResponse {
                provider: self.label.clone(),
                detail: "model hit the token limit and returned a truncated result".into(),
            });
        }

        choice
            .message
            .content
            .map(|c| c.trim().to_string())
            .filter(|c| !c.is_empty())
            .ok_or_else(|| DictError::BadResponse {
                provider: self.label.clone(),
                detail: "response contained no content".into(),
            })
    }
}
