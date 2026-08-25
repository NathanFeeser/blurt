use thiserror::Error;

/// Every failure the core can surface to a shell. Keep this list small and
/// actionable — each variant should map to something the UI can actually say.
#[derive(Debug, Error, uniffi::Error)]
#[uniffi(flat_error)]
pub enum DictError {
    #[error("no audio was captured")]
    NoAudio,

    #[error("{provider} is not configured: {detail}")]
    NotConfigured { provider: String, detail: String },

    #[error("{provider} rejected the request ({status}): {body}")]
    ProviderRejected {
        provider: String,
        status: u16,
        body: String,
    },

    #[error("{provider} authentication failed — check the API key")]
    Unauthorized { provider: String },

    #[error("{provider} rate limited us; retry after {retry_after_ms}ms")]
    RateLimited {
        provider: String,
        retry_after_ms: u64,
    },

    #[error("network error talking to {provider}: {detail}")]
    Network { provider: String, detail: String },

    #[error("could not parse the {provider} response: {detail}")]
    BadResponse { provider: String, detail: String },

    #[error("unknown provider id {id:?}")]
    UnknownProvider { id: String },

    /// Local persistence failed. Never fatal to a dictation: the text is
    /// already on its way into the user's app by the time history is written.
    #[error("history storage error: {detail}")]
    Storage { detail: String },
}

pub type Result<T> = std::result::Result<T, DictError>;

impl DictError {
    /// Whether retrying the identical request could plausibly succeed. The
    /// pipeline uses this to decide between a retry and surfacing the error.
    pub fn is_transient(&self) -> bool {
        matches!(
            self,
            DictError::Network { .. } | DictError::RateLimited { .. }
        )
    }
}

pub(crate) fn from_reqwest(provider: &str, e: reqwest::Error) -> DictError {
    DictError::Network {
        provider: provider.to_string(),
        detail: e.to_string(),
    }
}
