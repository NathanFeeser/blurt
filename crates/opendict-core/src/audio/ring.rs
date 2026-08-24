use std::collections::VecDeque;
use std::sync::Mutex;

use super::{PREROLL_MS, SAMPLE_RATE};

/// A microphone buffer with a rolling pre-roll window.
///
/// The platform shell calls [`AudioCapture::push`] continuously from its audio
/// callback (typically every 10–20 ms) whether or not a dictation is active.
/// `start()` seeds the recording with whatever is already sitting in the
/// pre-roll ring, so audio spoken just before the hotkey still lands.
///
/// FFI note: chunks cross the boundary, never individual frames. At 16 kHz with
/// 10 ms chunks that's 100 calls/sec carrying 640 bytes each — immaterial. If
/// profiling ever says otherwise, the replacement is a shared-memory ring, not
/// a smaller struct.
#[derive(uniffi::Object)]
pub struct AudioCapture {
    inner: Mutex<Inner>,
}

struct Inner {
    preroll: VecDeque<f32>,
    preroll_capacity: usize,
    recording: Option<Vec<f32>>,
    peak: f32,
}

/// A snapshot for the recording overlay's level meter.
#[derive(Debug, Clone, uniffi::Record)]
pub struct CaptureStats {
    pub is_recording: bool,
    pub duration_ms: u64,
    /// RMS level of the most recent chunk, 0.0–1.0.
    pub level: f32,
    /// Peak level seen since `start()`. Used to detect "you never unmuted".
    pub peak: f32,
}

#[uniffi::export]
impl AudioCapture {
    #[uniffi::constructor]
    pub fn new() -> Self {
        Self::with_preroll_ms(PREROLL_MS)
    }

    #[uniffi::constructor]
    pub fn with_preroll_ms(preroll_ms: u32) -> Self {
        let preroll_capacity = (SAMPLE_RATE as u64 * preroll_ms as u64 / 1000) as usize;
        Self {
            inner: Mutex::new(Inner {
                preroll: VecDeque::with_capacity(preroll_capacity),
                preroll_capacity,
                recording: None,
                peak: 0.0,
            }),
        }
    }

    /// Push a chunk of 16 kHz mono f32 samples. Safe to call at all times.
    /// Returns the RMS level of this chunk so the shell can drive a meter
    /// without a second call.
    pub fn push(&self, frames: Vec<f32>) -> f32 {
        let level = rms(&frames);
        let mut inner = self.inner.lock().unwrap();

        if let Some(rec) = inner.recording.as_mut() {
            rec.extend_from_slice(&frames);
            if level > inner.peak {
                inner.peak = level;
            }
        }

        // The pre-roll ring keeps filling during a recording too, so a second
        // dictation started immediately after the first still gets its lead-in.
        for f in frames {
            if inner.preroll.len() == inner.preroll_capacity {
                inner.preroll.pop_front();
            }
            inner.preroll.push_back(f);
        }

        level
    }

    /// Begin a dictation, seeded with the buffered pre-roll.
    pub fn start(&self) {
        let mut inner = self.inner.lock().unwrap();
        let seed: Vec<f32> = inner.preroll.iter().copied().collect();
        inner.peak = 0.0;
        inner.recording = Some(seed);
    }

    /// End the dictation and take the samples. Returns empty if not recording.
    pub fn stop(&self) -> Vec<f32> {
        let mut inner = self.inner.lock().unwrap();
        inner.recording.take().unwrap_or_default()
    }

    /// Abandon the dictation without producing audio (user hit escape).
    pub fn cancel(&self) {
        self.inner.lock().unwrap().recording = None;
    }

    pub fn stats(&self) -> CaptureStats {
        let inner = self.inner.lock().unwrap();
        let (is_recording, samples) = match inner.recording.as_ref() {
            Some(r) => (true, r.len()),
            None => (false, 0),
        };
        CaptureStats {
            is_recording,
            duration_ms: (samples as u64 * 1000) / SAMPLE_RATE as u64,
            level: inner
                .recording
                .as_ref()
                .map(|r| rms(&r[r.len().saturating_sub(512)..]))
                .unwrap_or(0.0),
            peak: inner.peak,
        }
    }
}

impl Default for AudioCapture {
    fn default() -> Self {
        Self::new()
    }
}

fn rms(frames: &[f32]) -> f32 {
    if frames.is_empty() {
        return 0.0;
    }
    let sum: f32 = frames.iter().map(|f| f * f).sum();
    (sum / frames.len() as f32).sqrt().clamp(0.0, 1.0)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn preroll_is_prepended_to_the_recording() {
        let cap = AudioCapture::with_preroll_ms(10); // 160 samples
        cap.push(vec![0.5; 160]); // fills the ring exactly
        cap.start();
        cap.push(vec![0.25; 100]);
        let out = cap.stop();

        assert_eq!(out.len(), 260, "pre-roll should be prepended");
        assert_eq!(out[0], 0.5);
        assert_eq!(out[259], 0.25);
    }

    #[test]
    fn preroll_ring_evicts_oldest() {
        let cap = AudioCapture::with_preroll_ms(10); // 160 samples
        cap.push(vec![0.1; 500]); // overflows by a lot
        cap.start();
        let out = cap.stop();
        assert_eq!(out.len(), 160, "ring must stay capped");
    }

    #[test]
    fn push_outside_a_recording_produces_no_audio() {
        let cap = AudioCapture::new();
        cap.push(vec![0.3; 1000]);
        assert!(cap.stop().is_empty());
    }

    #[test]
    fn cancel_discards() {
        let cap = AudioCapture::with_preroll_ms(0);
        cap.start();
        cap.push(vec![0.9; 1000]);
        cap.cancel();
        assert!(cap.stop().is_empty());
    }
}
