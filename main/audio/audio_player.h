#pragma once

#include "esp_err.h"
#include <stdint.h>
#include <stddef.h>

/**
 * Play a sine wave test tone through the speaker.
 * Blocks until playback completes.
 *
 * @param freq_hz   Tone frequency (e.g. 440 for A4)
 * @param duration_ms  Duration in milliseconds
 */
esp_err_t audio_player_play_tone(uint32_t freq_hz, uint32_t duration_ms);

/**
 * Play raw PCM audio data through the speaker.
 * Data must be 16-bit signed, mono, at MIMI_AUDIO_SAMPLE_RATE.
 * Internally duplicates to stereo for the I2S bus.
 * Blocks until playback completes.
 *
 * @param pcm_data  16-bit signed PCM samples (mono)
 * @param pcm_len   Length in bytes
 */
esp_err_t audio_player_play_pcm(const int16_t *pcm_data, size_t pcm_len);

/**
 * Play a WAV buffer (with 44-byte header) through the speaker.
 * Parses the header, extracts PCM data, and plays it.
 */
esp_err_t audio_player_play_wav(const uint8_t *wav_data, size_t wav_len);

/**
 * Diagnostic playback with selectable test mode for end-of-audio noise root cause analysis.
 *
 * mode 0 = baseline (same as audio_player_play_pcm)
 * mode 1 = chop_tail: drop last 1s of PCM before playback
 * mode 2 = long_fade: 2s fade-out instead of 50ms
 * mode 3 = peak_clamp: hard-limit samples to ±8000
 * mode 4 = no_pa_off: skip PA GPIO disable during shutdown
 * mode 5 = mute_first: mute codec BEFORE silence flush
 */
esp_err_t audio_player_play_pcm_diag(const int16_t *pcm_data, size_t pcm_len, int mode);
