//! Audio capture buffering and encoding.
//!
//! The shells own the platform microphone (AVAudioEngine, WASAPI) and push PCM
//! chunks in here. The core owns the buffer so that pre-roll, level metering,
//! and encoding are implemented exactly once.

mod ring;
mod wav;

pub use ring::{AudioCapture, CaptureStats};
pub use wav::encode_wav_pcm16;

/// Everything downstream assumes 16 kHz mono f32. Shells resample before pushing.
/// 16 kHz is what every ASR model wants and it keeps upload payloads small —
/// a 5 second utterance is 160 KB of WAV.
pub const SAMPLE_RATE: u32 = 16_000;
pub const CHANNELS: u16 = 1;

/// How much audio to keep buffered ahead of the hotkey. Users reliably start
/// speaking a beat before the key registers; without this, the first syllable
/// is clipped. 250 ms costs 16 KB of RAM.
pub const PREROLL_MS: u32 = 250;

/// The core's sample rate, exposed to the shells.
///
/// UniFFI does not export constants, and every shell needs this to configure its
/// resampler. A function keeps one source of truth instead of three hardcoded
/// literals that quietly diverge.
#[uniffi::export]
pub fn sample_rate() -> u32 {
    SAMPLE_RATE
}
