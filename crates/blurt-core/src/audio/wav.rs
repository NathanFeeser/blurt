use super::CHANNELS;

/// Encode f32 samples as a 16-bit PCM WAV.
///
/// Every STT provider accepts WAV, and at 16 kHz mono an utterance is small
/// enough that compressing it would cost more latency than it saves bandwidth
/// (a 5 s clip is ~160 KB). Revisit only if we support long-form capture.
pub fn encode_wav_pcm16(samples: &[f32], sample_rate: u32) -> Vec<u8> {
    let data_len = samples.len() * 2;
    let mut out = Vec::with_capacity(44 + data_len);

    let byte_rate = sample_rate * CHANNELS as u32 * 2;
    let block_align = CHANNELS * 2;

    out.extend_from_slice(b"RIFF");
    out.extend_from_slice(&((36 + data_len) as u32).to_le_bytes());
    out.extend_from_slice(b"WAVE");

    out.extend_from_slice(b"fmt ");
    out.extend_from_slice(&16u32.to_le_bytes()); // subchunk size
    out.extend_from_slice(&1u16.to_le_bytes()); // PCM
    out.extend_from_slice(&CHANNELS.to_le_bytes());
    out.extend_from_slice(&sample_rate.to_le_bytes());
    out.extend_from_slice(&byte_rate.to_le_bytes());
    out.extend_from_slice(&block_align.to_le_bytes());
    out.extend_from_slice(&16u16.to_le_bytes()); // bits per sample

    out.extend_from_slice(b"data");
    out.extend_from_slice(&(data_len as u32).to_le_bytes());
    for &s in samples {
        let clamped = s.clamp(-1.0, 1.0);
        // Asymmetric scaling: i16 range is -32768..=32767, so scaling by 32767
        // for positives and 32768 for negatives uses the full range without
        // wrapping on -1.0.
        let v = if clamped < 0.0 {
            (clamped * 32768.0) as i16
        } else {
            (clamped * 32767.0) as i16
        };
        out.extend_from_slice(&v.to_le_bytes());
    }

    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn header_is_well_formed() {
        let wav = encode_wav_pcm16(&[0.0; 100], 16_000);
        assert_eq!(&wav[0..4], b"RIFF");
        assert_eq!(&wav[8..12], b"WAVE");
        assert_eq!(&wav[36..40], b"data");
        assert_eq!(wav.len(), 44 + 200);
        assert_eq!(u32::from_le_bytes(wav[4..8].try_into().unwrap()), 236);
    }

    #[test]
    fn extremes_do_not_wrap() {
        let wav = encode_wav_pcm16(&[1.0, -1.0], 16_000);
        assert_eq!(i16::from_le_bytes(wav[44..46].try_into().unwrap()), 32767);
        assert_eq!(i16::from_le_bytes(wav[46..48].try_into().unwrap()), -32768);
    }
}
