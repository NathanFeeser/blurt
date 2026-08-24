//! Minimal 16-bit PCM WAV reader, enough to feed the pipeline from a file.
//!
//! Deliberately dependency-free and deliberately limited: the eval harness
//! controls its own fixtures, so supporting every exotic WAV variant is not
//! worth a decoder dependency in a dev tool.

use anyhow::{bail, Context, Result};

pub struct Wav {
    pub samples: Vec<f32>,
    pub sample_rate: u32,
    pub channels: u16,
}

pub fn read(bytes: &[u8]) -> Result<Wav> {
    if bytes.len() < 12 || &bytes[0..4] != b"RIFF" || &bytes[8..12] != b"WAVE" {
        bail!("not a RIFF/WAVE file");
    }

    let mut pos = 12;
    let mut sample_rate = 0u32;
    let mut channels = 0u16;
    let mut bits = 0u16;
    let mut format = 0u16;
    let mut data: Option<&[u8]> = None;

    while pos + 8 <= bytes.len() {
        let id = &bytes[pos..pos + 4];
        let size = u32::from_le_bytes(bytes[pos + 4..pos + 8].try_into()?) as usize;
        let body_start = pos + 8;
        let body_end = (body_start + size).min(bytes.len());

        match id {
            b"fmt " => {
                let b = &bytes[body_start..body_end];
                if b.len() < 16 {
                    bail!("truncated fmt chunk");
                }
                format = u16::from_le_bytes(b[0..2].try_into()?);
                channels = u16::from_le_bytes(b[2..4].try_into()?);
                sample_rate = u32::from_le_bytes(b[4..8].try_into()?);
                bits = u16::from_le_bytes(b[14..16].try_into()?);
            }
            b"data" => data = Some(&bytes[body_start..body_end]),
            _ => {}
        }
        // Chunks are word-aligned, so an odd size is followed by a pad byte.
        pos = body_start + size + (size % 2);
    }

    let data = data.context("no data chunk")?;
    if format != 1 || bits != 16 {
        bail!("only 16-bit PCM WAV is supported (got format {format}, {bits}-bit). Convert with: ffmpeg -i in.wav -ar 16000 -ac 1 -c:a pcm_s16le out.wav");
    }
    if channels == 0 || sample_rate == 0 {
        bail!("missing or invalid fmt chunk");
    }

    let samples = data
        .as_chunks::<2>()
        .0
        .iter()
        .map(|c| i16::from_le_bytes(*c) as f32 / 32768.0)
        .collect();

    Ok(Wav {
        samples,
        sample_rate,
        channels,
    })
}

/// Downmix to mono and linearly resample to `target_rate`.
///
/// Linear interpolation is not a good resampler — it aliases. It is fine here
/// because fixtures should already be 16 kHz; this exists so a stray 44.1 kHz
/// file produces a usable result instead of an error. Real capture paths
/// resample in the platform audio layer.
pub fn to_mono_16k(wav: &Wav, target_rate: u32) -> Vec<f32> {
    let mono: Vec<f32> = if wav.channels <= 1 {
        wav.samples.clone()
    } else {
        wav.samples
            .chunks(wav.channels as usize)
            .map(|frame| frame.iter().sum::<f32>() / frame.len() as f32)
            .collect()
    };

    if wav.sample_rate == target_rate || mono.is_empty() {
        return mono;
    }

    let ratio = target_rate as f64 / wav.sample_rate as f64;
    let out_len = ((mono.len() as f64) * ratio).round() as usize;
    (0..out_len)
        .map(|i| {
            let src = i as f64 / ratio;
            let idx = src.floor() as usize;
            let frac = (src - idx as f64) as f32;
            let a = mono[idx.min(mono.len() - 1)];
            let b = mono[(idx + 1).min(mono.len() - 1)];
            a + (b - a) * frac
        })
        .collect()
}
