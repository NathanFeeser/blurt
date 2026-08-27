//! Whether a recording contains speech at all.
//!
//! This exists because of what Whisper does with silence. Asked to transcribe
//! room tone it does not return an empty string — it returns the likeliest
//! thing in its training data, which is the caption track of a video that had
//! no speech either. "Thank you." is the famous one; "Thanks for watching!",
//! "you", and subtitle credits are the rest of the family. Press the key,
//! say nothing, release, and a "Thank you." lands in whatever you were typing.
//!
//! Filtering those phrases out of the output was the obvious fix and the wrong
//! one: the list is endless, it is per-language, and it would eat a genuine
//! "Thank you." — a phrase people dictate constantly. The signal is in the
//! audio, so the check belongs before the model, where it also saves the round
//! trip and returns a silent press instantly.

use super::{rms, SAMPLE_RATE};

/// 20 ms. Short enough to sit inside a single syllable, long enough that its
/// RMS is a stable number rather than a sample of the waveform.
const FRAME_SAMPLES: usize = SAMPLE_RATE as usize / 50;

/// Below this there is not enough audio to judge, and not enough to be a
/// dictation either. The 250 ms pre-roll means real recordings clear it easily.
const MIN_FRAMES: usize = 5;

/// How far the loud part of the recording has to sit above the quiet part.
///
/// This is the rule that does the real work, because it is about *structure*
/// rather than level. Speech is bursty — vowels against closures and gaps —
/// while a room is flat, whatever its volume. That distinction survives the
/// automatic gain control in a Bluetooth headset, which happily amplifies an
/// empty room up to conversational level and defeats any absolute threshold.
///
/// 6x (about 16 dB) is measured, not guessed. Against the speech clips in
/// WhisperKit's test resources and against synthetic room tone:
///
/// ```text
///                          p95/p05
///   real speech              13.8 – 5300     (worst: a Spanish clip's first 2s)
///   flat white noise          1.1
///   drifting room tone        2.4 – 3.1      (worst: HVAC-like level swings)
/// ```
///
/// A narrower pair of percentiles collapses that gap: on p90/p20 the worst
/// real speech scores 2.6 and the worst room tone 2.4, which is no separation
/// at all. Reaching further into the tails is what makes the rule decidable.
const ABOVE_ROOM: f32 = 6.0;

/// Pitch analysis runs at half rate. A voice's fundamental lives far below
/// 4 kHz, so halving the sample count loses nothing and quarters the cost of
/// the lag search.
const DECIMATION: usize = 2;
const PITCH_RATE: usize = SAMPLE_RATE as usize / DECIMATION;

/// 40 ms — at least two periods of the lowest pitch we look for.
const PITCH_FRAME: usize = PITCH_RATE / 25;
const PITCH_HOP: usize = PITCH_RATE / 50;

/// 70–400 Hz, the range a human fundamental occupies. The bottom deliberately
/// stops short of mains hum at 50/60 Hz.
const MIN_LAG: usize = PITCH_RATE / 400;
const MAX_LAG: usize = PITCH_RATE / 70;

/// Normalised autocorrelation above which a frame counts as voiced.
const VOICED: f32 = 0.5;

/// Enough voicing to be a word rather than a chair creak: 8 frames is 160 ms.
const MIN_VOICED_FRAMES: u32 = 8;

/// What separates a voice from a fan.
///
/// A steady tone is *also* strongly periodic, so counting voiced frames alone
/// calls a 120 Hz hum speech with total confidence. The difference is that a
/// hum holds one pitch and a voice never does — intonation moves it constantly,
/// and voiced sounds keep giving way to unvoiced ones. So the test is how many
/// *different* pitches the voiced frames carry, as a fraction of them:
///
/// ```text
///                        distinct pitches / voiced frames, capped
///   real speech            0.46 – 1.00   (unchanged by gain control or length)
///   60/120/220 Hz hum      0.05 – 0.07
///   motor with harmonics   0.03
///   white noise            0.00
/// ```
const MIN_PITCH_VARIETY: f32 = 0.15;

/// Voiced frames past this point stop dragging the score down.
///
/// Without the cap the measure punishes talking for longer. There are only
/// ~95 lags in the search range, so the count of *distinct* pitches saturates
/// while the count of voiced frames keeps climbing, and the ratio falls with
/// length rather than with anything about the audio. It is not a marginal
/// effect: a real clip scored 0.17, and the same clip repeated three times
/// scored 0.06 — the identical speech, rejected for going on too long. A live
/// dictation was thrown away this way at 0.14 while the take before it, of the
/// same voice on the same microphone, passed at 0.19.
///
/// 40 frames is 800 ms of voicing, which is plenty to judge whether a pitch is
/// moving, and past it more speech can only help.
const VARIETY_FRAMES: u32 = 40;

/// A floor for the one case the ratio cannot see: a dead or muted input, where
/// the room estimate is so close to zero that any dither above it looks like a
/// huge multiple.
///
/// Its only job is "is there a signal here at all" — *not* "is it loud enough
/// to be speech". Setting it at speech level was a mistake that cost a real
/// dictation: a webcam microphone across the desk captures perfectly
/// intelligible speech at a level a headset would call silence, and the model
/// transcribes it happily. Level is the model's problem. This is -66 dBFS, far
/// under any live microphone and far over a muted one.
const ABSOLUTE_FLOOR: f32 = 0.0005;

/// What the speech check saw. Reported so the shells can write it down: a
/// dictation dropped for "no speech" is indistinguishable from a dictation that
/// vanished unless the numbers behind the decision are in the log.
#[derive(Debug, Clone, uniffi::Record)]
pub struct SpeechMeasurement {
    pub has_speech: bool,
    /// Frame RMS at the 5th percentile — the room.
    pub room: f32,
    /// Frame RMS at the 95th percentile — the loudest sustained part.
    pub loud: f32,
    /// `loud / room`. Zero when the room is silent enough to make it undefined.
    pub ratio: f32,
    pub frames: u32,
    /// How many frames carried a pitch. Zero when the loudness test already
    /// answered and the pitch search was skipped — see `pitch_checked`.
    pub voiced_frames: u32,
    /// Distinct pitches over voiced frames. What tells a voice from a fan.
    pub pitch_variety: f32,
    pub pitch_checked: bool,
}

/// Whether `samples` (16 kHz mono) plausibly contain someone speaking.
///
/// Errs toward yes. A false negative silently throws away something the user
/// said, which is the worst failure this app has; a false positive is one
/// unwanted "Thank you." that they can see and undo.
pub fn contains_speech(samples: &[f32]) -> bool {
    measure(samples).has_speech
}

/// The measurement behind [`contains_speech`], for the diagnostic log.
///
/// Two independent tests, and either one is enough. They fail in opposite
/// directions, which is the point:
///
/// - **Loudness structure** sees any speech that stands out from its room, but
///   a microphone with automatic gain control pumps the gaps between words back
///   up to speech level and flattens exactly what this measures. A webcam mic
///   that sounds perfect can score below the threshold.
/// - **Voicing** sees the periodicity of vocal folds, which gain control cannot
///   touch at all — but it is blind to whispering, which has no pitch to find.
///
/// Requiring both would fail a whisper and fail an AGC microphone. Requiring
/// either passes both, and neither one fires on a room: noise has no pitch and
/// no structure, whatever its volume.
pub fn measure(samples: &[f32]) -> SpeechMeasurement {
    let mut frames: Vec<f32> = samples
        .as_chunks::<FRAME_SAMPLES>()
        .0
        .iter()
        .map(|f| rms(f))
        .collect();
    let count = frames.len() as u32;
    if frames.len() < MIN_FRAMES {
        return SpeechMeasurement {
            has_speech: false,
            room: 0.0,
            loud: 0.0,
            ratio: 0.0,
            frames: count,
            voiced_frames: 0,
            pitch_variety: 0.0,
            pitch_checked: false,
        };
    }
    frames.sort_by(|a, b| a.partial_cmp(b).unwrap_or(std::cmp::Ordering::Equal));

    // Percentiles rather than min and max: a single cough, key click, or chair
    // creak in an otherwise empty room should not read as a sentence, and one
    // unlucky frame should not stand in for the noise floor either.
    let room = percentile(&frames, 0.05);
    let loud = percentile(&frames, 0.95);

    let ratio = if room > 0.0 { loud / room } else { 0.0 };
    let mut out = SpeechMeasurement {
        has_speech: loud >= ABSOLUTE_FLOOR && loud >= room * ABOVE_ROOM,
        room,
        loud,
        ratio,
        frames: count,
        voiced_frames: 0,
        pitch_variety: 0.0,
        pitch_checked: false,
    };
    if out.has_speech {
        // Already answered, and the lag search is the expensive half. Skipping
        // it keeps the ordinary microphone on the cheap path.
        return out;
    }

    let (voiced, variety) = voicing(samples);
    out.voiced_frames = voiced;
    out.pitch_variety = variety;
    out.pitch_checked = true;
    out.has_speech = voiced >= MIN_VOICED_FRAMES && variety >= MIN_PITCH_VARIETY;
    out
}

/// Count the frames carrying a pitch, and how much that pitch moves.
fn voicing(samples: &[f32]) -> (u32, f32) {
    let decimated = decimate(samples);
    let mut lags: Vec<usize> = Vec::new();
    let mut start = 0;
    while start + PITCH_FRAME <= decimated.len() {
        if let Some(lag) = pitch_lag(&decimated[start..start + PITCH_FRAME]) {
            lags.push(lag);
        }
        start += PITCH_HOP;
    }
    let voiced = lags.len() as u32;
    if voiced < MIN_VOICED_FRAMES {
        // Too little to divide by: a handful of frames all land on different
        // lags by chance, which would read as a wide pitch range.
        return (voiced, 0.0);
    }
    lags.sort_unstable();
    lags.dedup();
    let variety = lags.len() as f32 / voiced.min(VARIETY_FRAMES) as f32;
    (voiced, variety.min(1.0))
}

/// Box-average down to `PITCH_RATE`. Crude as a filter, which is fine: it is a
/// low-pass, and everything being looked for is at the low end.
fn decimate(samples: &[f32]) -> Vec<f32> {
    samples
        .as_chunks::<DECIMATION>()
        .0
        .iter()
        .map(|pair| pair.iter().sum::<f32>() / DECIMATION as f32)
        .collect()
}

/// The lag of this frame's strongest periodicity, if it is periodic enough to
/// call voiced.
fn pitch_lag(frame: &[f32]) -> Option<usize> {
    let n = frame.len();
    let mean = frame.iter().sum::<f32>() / n as f32;
    let centred: Vec<f32> = frame.iter().map(|x| x - mean).collect();

    // Running sum of squares, so each lag's two energies are a subtraction
    // rather than another pass over the frame. Without this the normalisation
    // costs three times what the correlation does.
    let mut energy = vec![0.0f32; n + 1];
    for i in 0..n {
        energy[i + 1] = energy[i] + centred[i] * centred[i];
    }
    if energy[n] <= 0.0 {
        return None;
    }

    let mut best = 0.0;
    let mut best_lag = None;
    for lag in MIN_LAG..=MAX_LAG.min(n - 1) {
        let overlap = n - lag;
        let correlation: f32 = (0..overlap).map(|i| centred[i] * centred[i + lag]).sum();
        let scale = (energy[overlap] * (energy[n] - energy[lag])).sqrt();
        if scale > 0.0 {
            let normalised = correlation / scale;
            if normalised > best {
                best = normalised;
                best_lag = Some(lag);
            }
        }
    }
    best_lag.filter(|_| best >= VOICED)
}

/// The measurement, for shells reporting why a dictation was dropped.
#[uniffi::export]
pub fn measure_speech(samples: Vec<f32>) -> SpeechMeasurement {
    measure(&samples)
}

/// `sorted` must be ascending. `p` is 0.0–1.0.
fn percentile(sorted: &[f32], p: f32) -> f32 {
    let last = sorted.len() - 1;
    sorted[(last as f32 * p).round() as usize]
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::f32::consts::TAU;

    /// Steady tone, as a stand-in for a voiced sound.
    fn tone(seconds: f32, amplitude: f32) -> Vec<f32> {
        let n = (SAMPLE_RATE as f32 * seconds) as usize;
        (0..n)
            .map(|i| amplitude * (TAU * 180.0 * i as f32 / SAMPLE_RATE as f32).sin())
            .collect()
    }

    /// Deterministic pseudo-noise, so the tests do not need a rand dependency
    /// and do not flake.
    fn noise(seconds: f32, amplitude: f32) -> Vec<f32> {
        let n = (SAMPLE_RATE as f32 * seconds) as usize;
        let mut state = 0x2545_F491_4F6C_DD1Du64;
        (0..n)
            .map(|_| {
                state ^= state << 13;
                state ^= state >> 7;
                state ^= state << 17;
                let unit = (state >> 40) as f32 / 8_388_608.0 - 1.0;
                unit * amplitude
            })
            .collect()
    }

    /// Bursts against gaps: the shape of someone talking.
    fn speech(amplitude: f32, floor: f32) -> Vec<f32> {
        let mut out = Vec::new();
        for i in 0..6 {
            out.extend(tone(0.25, if i % 2 == 0 { amplitude } else { floor }));
        }
        out
    }

    /// A voice, in the one way that matters here: periodic, with a pitch that
    /// keeps moving, broken by unvoiced stretches.
    fn voice(amplitude: f32) -> Vec<f32> {
        let mut out = Vec::new();
        let mut phase = 0.0f32;
        for segment in 0..14 {
            // Intonation. A real fundamental never sits still, and a detector
            // that cannot tell a voice from a fan depends on exactly this.
            let f0 = 95.0 + (segment as f32 * 17.0) % 110.0;
            let voiced = segment % 3 != 2;
            let n = (SAMPLE_RATE as f32 * 0.18) as usize;
            for _ in 0..n {
                phase += TAU * f0 / SAMPLE_RATE as f32;
                // A few harmonics: a glottal pulse is not a sine wave.
                let v = (phase).sin() + 0.5 * (2.0 * phase).sin() + 0.3 * (3.0 * phase).sin();
                out.push(if voiced {
                    amplitude * v / 1.8
                } else {
                    amplitude * 0.05
                });
            }
        }
        out
    }

    /// Mix in room tone. Gain control has to have something in the gaps to
    /// lift; a synthetic gap of pure digital silence cannot be amplified, so
    /// without this the test cannot reproduce what a real microphone does.
    fn with_room(signal: &[f32], amplitude: f32) -> Vec<f32> {
        let room = noise(signal.len() as f32 / SAMPLE_RATE as f32, amplitude);
        signal.iter().zip(room).map(|(s, r)| s + r).collect()
    }

    /// What a webcam microphone's gain control does: drag every 100 ms window
    /// to the same level, flattening the gaps between words into the words.
    fn gain_controlled(samples: &[f32]) -> Vec<f32> {
        const WINDOW: usize = SAMPLE_RATE as usize / 10;
        let mut out = Vec::with_capacity(samples.len());
        for block in samples.chunks(WINDOW) {
            let level = rms(block).max(1e-5);
            let gain = (0.08 / level).min(40.0);
            out.extend(block.iter().map(|s| (s * gain).clamp(-1.0, 1.0)));
        }
        out
    }

    #[test]
    fn digital_silence_is_not_speech() {
        assert!(!contains_speech(&vec![0.0; SAMPLE_RATE as usize * 2]));
    }

    #[test]
    fn room_tone_is_not_speech() {
        // The actual bug: hold the key in a quiet room, say nothing, and
        // Whisper answers "Thank you."
        assert!(!contains_speech(&noise(2.0, 0.004)));
    }

    #[test]
    fn a_loud_room_is_still_not_speech() {
        // A Bluetooth headset's gain control lifts an empty room to speech
        // level. Only the flatness gives it away, which is why the ratio and
        // not the volume is the main rule.
        assert!(!contains_speech(&noise(2.0, 0.25)));
    }

    #[test]
    fn speaking_is_speech() {
        assert!(contains_speech(&speech(0.2, 0.002)));
    }

    #[test]
    fn quiet_speaking_is_still_speech() {
        // Losing what someone actually said is far worse than a stray
        // "Thank you.", so the quiet talker has to get through.
        assert!(contains_speech(&speech(0.03, 0.001)));
    }

    #[test]
    fn speech_over_a_noisy_room_is_speech() {
        let mut mixed = speech(0.15, 0.0);
        for (i, s) in noise(mixed.len() as f32 / SAMPLE_RATE as f32, 0.02)
            .into_iter()
            .enumerate()
        {
            mixed[i] += s;
        }
        assert!(contains_speech(&mixed));
    }

    #[test]
    fn a_single_click_in_a_silent_room_is_not_speech() {
        // One slammed door is not a sentence. Percentiles rather than peak.
        let mut clip = noise(2.0, 0.002);
        for s in clip.iter_mut().take(FRAME_SAMPLES / 2) {
            *s = 0.9;
        }
        assert!(!contains_speech(&clip));
    }

    #[test]
    fn a_distant_quiet_microphone_still_counts_as_speech() {
        // A webcam microphone across the desk. Perfectly intelligible to the
        // model, and far below what a headset would call speech — an absolute
        // threshold set at speech level threw this away, which is exactly the
        // failure this check is not allowed to have.
        assert!(contains_speech(&speech(0.004, 0.0002)));
    }

    #[test]
    fn a_dead_microphone_is_not_speech() {
        // The only thing the absolute floor is for: dither on a muted input,
        // where the ratio is large but there is no signal at all.
        assert!(!contains_speech(&noise(2.0, 0.00002)));
    }

    #[test]
    fn speech_survives_a_microphone_with_gain_control() {
        // The regression that cost a working dictation. Automatic gain control
        // lifts the silence between words up to the level of the words, which
        // erases the loudness structure entirely — the ratio here collapses to
        // roughly 1. Only the pitch test can still see a voice in this.
        let squashed = gain_controlled(&with_room(&voice(0.05), 0.004));
        let m = measure(&squashed);
        assert!(
            m.ratio < ABOVE_ROOM,
            "test is not exercising what it claims: gain control should have              flattened the loudness structure, but the ratio is still {}",
            m.ratio
        );
        assert!(
            m.has_speech,
            "gain-controlled speech must still be speech: {m:?}"
        );
    }

    #[test]
    fn talking_for_longer_does_not_make_it_less_like_speech() {
        // The measure used to divide by every voiced frame, so it fell as the
        // dictation went on and a long one failed outright. Same speech, three
        // times the length: the verdict must not move.
        // Through gain control, so the loudness test cannot answer first and
        // leave the pitch search — the thing under test — unrun.
        let once = gain_controlled(&with_room(&voice(0.05), 0.004));
        let thrice = gain_controlled(&with_room(
            &[voice(0.05), voice(0.05), voice(0.05)].concat(),
            0.004,
        ));
        let short = measure(&once);
        let long = measure(&thrice);
        assert!(
            short.has_speech && long.has_speech,
            "short {short:?}, long {long:?}"
        );
        assert!(
            long.voiced_frames > short.voiced_frames * 2,
            "test is not exercising what it claims: the long clip should have far \
             more voiced frames, got {} against {}",
            long.voiced_frames,
            short.voiced_frames
        );
        assert!(
            long.pitch_variety >= short.pitch_variety,
            "length must not lower the score: {} over {} frames against {} over {}",
            long.pitch_variety,
            long.voiced_frames,
            short.pitch_variety,
            short.voiced_frames
        );
    }

    #[test]
    fn a_steady_hum_is_not_speech() {
        // A fan is as periodic as a vowel and never stops, so counting voiced
        // frames alone calls it speech. It holds one pitch; a voice cannot.
        let mut hum = tone(3.0, 0.05);
        for (i, s) in noise(3.0, 0.01).into_iter().enumerate() {
            hum[i] += s;
        }
        let m = measure(&hum);
        assert!(
            m.voiced_frames > MIN_VOICED_FRAMES,
            "test is not exercising what it claims: a steady tone should read              as voiced, but only {} frames did",
            m.voiced_frames
        );
        assert!(!m.has_speech, "a hum is not speech: {m:?}");
    }

    #[test]
    fn whispering_is_still_speech() {
        // No vocal fold, no pitch, nothing for the voicing test to find. The
        // loudness structure is all that is left, which is why the two tests
        // are an either-or and not an and.
        let mut whispered = Vec::new();
        for segment in 0..8 {
            let loud = segment % 2 == 0;
            whispered.extend(noise(0.2, if loud { 0.05 } else { 0.001 }));
        }
        let m = measure(&whispered);
        assert!(
            m.has_speech,
            "a whisper is still something the user said: {m:?}"
        );
    }

    #[test]
    fn a_recording_too_short_to_judge_is_not_speech() {
        assert!(!contains_speech(&tone(0.05, 0.3)));
    }
}
