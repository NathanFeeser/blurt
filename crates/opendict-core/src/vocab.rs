//! Custom vocabulary and the biasing prompt built from it.

use std::collections::BTreeSet;

/// Terms the ASR should be nudged toward: names, project jargon, product names.
/// Phase 1 adds terms learned automatically from user corrections; the storage
/// shape is the same either way.
#[derive(Debug, Clone, Default, uniffi::Record)]
pub struct Vocabulary {
    pub terms: Vec<String>,
}

/// Whisper consumes only the last 224 tokens of `prompt` and its attention
/// weights the tail most heavily. So: emit a bounded list, and put nothing
/// after the terms. We budget conservatively in characters rather than tokens
/// because we don't want a tokenizer dependency in the core.
///
/// ~4 chars/token, 224 tokens, minus headroom for the lead-in sentence.
const MAX_BIASING_CHARS: usize = 700;

impl Vocabulary {
    pub fn is_empty(&self) -> bool {
        self.terms.iter().all(|t| t.trim().is_empty())
    }

    /// Build the `prompt` field sent to the STT provider.
    ///
    /// Returns `None` when there is nothing to bias toward — passing an empty
    /// or generic prompt measurably *hurts* Whisper output, so we send nothing.
    pub fn biasing_prompt(&self) -> Option<String> {
        let mut seen = BTreeSet::new();
        let mut terms: Vec<&str> = Vec::new();
        for t in &self.terms {
            let t = t.trim();
            if !t.is_empty() && seen.insert(t.to_lowercase()) {
                terms.push(t);
            }
        }
        if terms.is_empty() {
            return None;
        }

        let lead = "Terms that may appear: ";
        let mut out = String::from(lead);
        for (i, term) in terms.iter().enumerate() {
            let sep = if i == 0 { "" } else { ", " };
            if out.len() + sep.len() + term.len() + 1 > MAX_BIASING_CHARS {
                break;
            }
            out.push_str(sep);
            out.push_str(term);
        }
        if out.len() == lead.len() {
            return None;
        }
        out.push('.');
        Some(out)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn empty_vocabulary_sends_no_prompt() {
        assert!(Vocabulary::default().biasing_prompt().is_none());
        assert!(Vocabulary {
            terms: vec!["  ".into()]
        }
        .biasing_prompt()
        .is_none());
    }

    #[test]
    fn dedupes_case_insensitively() {
        let v = Vocabulary {
            terms: vec!["Kubernetes".into(), "kubernetes".into(), "Nomad".into()],
        };
        let p = v.biasing_prompt().unwrap();
        assert_eq!(p.matches("ubernetes").count(), 1);
        assert!(p.contains("Nomad"));
    }

    #[test]
    fn respects_the_224_token_budget() {
        let v = Vocabulary {
            terms: (0..500).map(|i| format!("term{i}")).collect(),
        };
        let p = v.biasing_prompt().unwrap();
        assert!(p.len() <= super::MAX_BIASING_CHARS, "got {} chars", p.len());
        assert!(p.ends_with('.'));
    }
}
