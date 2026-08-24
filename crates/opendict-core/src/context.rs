//! What the shell knows about where the text is going.
//!
//! This is the single highest-leverage input to the cleanup stage. Knowing the
//! user is in Slack vs. an editor vs. Gmail changes tone, formatting, and how
//! aggressively to punctuate; the surrounding text fixes proper nouns that no
//! amount of ASR accuracy will get right. freeflow spends 769 lines of
//! Accessibility API code on this and it is most of why their output feels smart.

/// Populated by the shell: Accessibility API on macOS, UI Automation on Windows,
/// nothing at all on iOS (where the keyboard extension can't see the host app).
/// Every field is optional — the pipeline degrades gracefully to a plain cleanup.
#[derive(Debug, Clone, Default, uniffi::Record)]
pub struct AppContext {
    /// e.g. `com.tinyspeck.slackmacgap`.
    pub bundle_id: Option<String>,
    /// Human-readable, e.g. `Slack`.
    pub app_name: Option<String>,
    pub window_title: Option<String>,
    /// Text around the caret. Trimmed by the shell before crossing FFI; the
    /// pipeline caps it again defensively.
    pub surrounding_text: Option<String>,
    /// Present only in command mode — the text the user wants transformed.
    pub selected_text: Option<String>,
}

/// How much surrounding text is worth sending. Past a few hundred characters
/// the signal flattens out and we're just paying input tokens and latency.
const MAX_SURROUNDING_CHARS: usize = 600;

impl AppContext {
    pub fn is_empty(&self) -> bool {
        self.bundle_id.is_none()
            && self.app_name.is_none()
            && self.window_title.is_none()
            && self.surrounding_text.is_none()
    }

    /// Render as a compact block for the cleanup prompt.
    pub fn to_prompt_block(&self) -> Option<String> {
        if self.is_empty() {
            return None;
        }
        let mut out = String::new();
        if let Some(app) = self.app_name.as_ref().or(self.bundle_id.as_ref()) {
            out.push_str(&format!("Application: {app}\n"));
        }
        if let Some(title) = &self.window_title {
            out.push_str(&format!("Window: {title}\n"));
        }
        if let Some(text) = &self.surrounding_text {
            let trimmed = truncate_tail(text, MAX_SURROUNDING_CHARS);
            if !trimmed.trim().is_empty() {
                out.push_str(&format!("Text already around the cursor:\n{trimmed}\n"));
            }
        }
        Some(out)
    }
}

/// Keep the *end* of the text — the words nearest the caret are the ones most
/// likely to disambiguate what was just spoken.
fn truncate_tail(s: &str, max_chars: usize) -> String {
    let count = s.chars().count();
    if count <= max_chars {
        return s.to_string();
    }
    let skipped = count - max_chars;
    format!("…{}", s.chars().skip(skipped).collect::<String>())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn empty_context_yields_no_block() {
        assert!(AppContext::default().to_prompt_block().is_none());
    }

    #[test]
    fn surrounding_text_keeps_the_tail() {
        let ctx = AppContext {
            surrounding_text: Some("a".repeat(700) + "TAIL"),
            ..Default::default()
        };
        let block = ctx.to_prompt_block().unwrap();
        assert!(block.contains("TAIL"));
        assert!(block.contains('…'));
    }

    #[test]
    fn multibyte_truncation_does_not_panic() {
        let ctx = AppContext {
            surrounding_text: Some("日本語".repeat(500)),
            ..Default::default()
        };
        assert!(ctx.to_prompt_block().is_some());
    }
}
