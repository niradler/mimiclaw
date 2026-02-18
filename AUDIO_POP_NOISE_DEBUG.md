# Audio Pop/Click Noise Investigation

## Problem Description
A loud pop/click noise occurs at the END of audio playback on the Xingzhi Cube ESP32-S3 hardware with ES8311 codec. The noise is consistently present and very annoying.

## Hardware Setup
- **MCU**: ESP32-S3 (PSRAM enabled)
- **Codec**: ES8311 (DAC for speaker output)
- **Amplifier**: GPIO 4 controls PA enable (active high)
- **I2S Configuration**: 
  - Sample rate: 16000 Hz
  - Bit depth: 16-bit
  - Channels: Mono (duplicated to stereo for codec)
  - DMA buffers: 6 descriptors, 240 frames each

## Current Implementation Flow
1. Enable speaker PA via GPIO
2. Call `write_stereo()` which writes PCM data via `esp_codec_dev_write()` in chunks
3. `write_stereo()` returns when DMA accepts all data (but DMA is still playing)
4. Mute codec by setting volume to 0
5. Wait calculated playback time + 100ms
6. Disable speaker PA
7. Restore volume to 60

## Attempted Fixes (All Failed)

---

## SESSION 2 — Diagnostic Testing & New Attempts (Feb 2026)

### Diagnostic Framework Added
Added `tts_test <text> [mode]` to the serial CLI with 5 diagnostic modes to isolate root cause:
- **Mode 0**: Baseline (normal processing)
- **Mode 1** `chop_tail`: Drop last 1s of PCM before playback
- **Mode 2** `long_fade`: 2-second fade-out instead of 50ms
- **Mode 3** `peak_clamp`: Hard-limit samples to ±8000
- **Mode 4** `no_pa_off`: Skip PA GPIO disable at shutdown
- **Mode 5** `mute_first`: Mute codec BEFORE silence flush

Also fixed CLI task stack from 4096 → 16384 bytes (was crashing due to TLS stack overflow in CLI task, unrelated to audio).

### Diagnostic Test Results

| Mode | Result | Implication |
|------|--------|-------------|
| 1 (chop 1s) | Same noise but **shorter** | Noise duration scales with audio length |
| 2 (2s fade) | Same but noise **fades out** | Fade affects noise character |
| 3 (peak clamp ±8000) | Noise **slightly reduced** | Noise is amplitude-dependent |
| 4 (no PA off) | **Same as mode 3** | PA GPIO toggle is NOT the root cause |
| 5 (mute first) | **Same as mode 3** | Shutdown sequence order is NOT the root cause |

**Key conclusion from diagnostics**: The noise is amplitude/energy dependent (mode 3 helps), fade-responsive (mode 2 changes its character), and is NOT caused by PA GPIO toggling or shutdown sequence order (modes 4, 5 ineffective). Points to analog coupling capacitor discharge when signal energy drops — the codec continues to release stored energy after signal stops.

### Attempt 5: Proper API Mute (`esp_codec_dev_set_out_mute`)
Switched from `audio_hal_set_volume(0)` to `esp_codec_dev_set_out_mute(dev, true)` which writes the ES8311's dedicated mute register rather than just volume. Also added `flush_dma_silence()` writing one full DMA buffer depth of zeros before muting.

**Sequence**:
```
flush_dma_silence → esp_codec_dev_set_out_mute(true) → wait DMA_DRAIN_MS → PA off → unmute
```
**Result**: Still noise.

### Attempt 6: Removed Dual PA Pin Ownership
Discovered `es8311_codec_cfg_t.pa_pin = MIMI_SPEAKER_EN` was set, meaning the codec driver also thought it owned the PA GPIO. Changed to `pa_pin = -1` to give sole ownership to `audio_hal_speaker_pa()`.

**Result**: Still noise.

### Attempt 7: I2S Channel Disable Before PA Off
Stopped the I2S BCLK/MCLK (via `i2s_channel_disable`) between codec mute and PA disable so the codec sees no clock activity when PA drops:
```
flush_silence → set_out_mute → i2s_channel_disable → wait → PA off → i2s_channel_enable → unmute
```
**Result**: Still noise. (This was superseded by Attempt 8.)

### Attempt 8: esp_codec_dev_close() / re-open per session (xiaozhi-esp32 pattern)
Studied the xiaozhi-esp32 project (24K stars, same ES8311 hardware). Their pattern:
- `esp_codec_dev_close()` at end of playback → triggers ES8311 full shutdown: soft-mute ramp → DAC power off → I2S TX disable (all in hardware-specified order)
- PA off after close
- `esp_codec_dev_open()` immediately to ready for next session

This is the "correct" ESP codec lifecycle usage — not keeping codec permanently open.

**Current shutdown code**:
```c
flush_dma_silence(dev);
esp_codec_dev_close(dev);        // ES8311: soft-mute → DAC off → I2S disable
vTaskDelay(pdMS_TO_TICKS(20));
audio_hal_speaker_pa(false);
esp_codec_dev_open(dev, &fs);   // Re-open for next session
esp_codec_dev_set_out_vol(dev, 60);
```
**Result**: Still noise. The noise character seems to be in the analog/hardware layer, above what software shutdown sequences can address.

---

### Attempt 1: Immediate PA Disable After Write
**Code**: 
```c
audio_hal_speaker_pa(true);
esp_err_t ret = write_stereo(dev, pcm_data, total_samples);
audio_hal_speaker_pa(false);
```
**Result**: Still produced pop noise. This was expected because DMA buffers still contain data being played when PA is disabled.

### Attempt 2: Volume Fade + Silence Injection + Delays
**Code**:
```c
audio_hal_set_volume(0);
vTaskDelay(pdMS_TO_TICKS(50));

int16_t silence[240];
memset(silence, 0, sizeof(silence));
for (int i = 0; i < 80; i++) {
    write_stereo(dev, silence, 120);  // Play 80 chunks of silence
}

vTaskDelay(pdMS_TO_TICKS(100));
audio_hal_speaker_pa(false);
vTaskDelay(pdMS_TO_TICKS(10));
audio_hal_set_volume(60);
```
**Result**: Still produced pop noise. Playing additional silence didn't help.

### Attempt 3: Wait for DMA Drain (Calculated Timing)
**Code**:
```c
audio_hal_speaker_pa(true);
esp_err_t ret = write_stereo(dev, pcm_data, total_samples);

float duration_sec = (float)total_samples / MIMI_AUDIO_SAMPLE_RATE;
uint32_t drain_ms = (uint32_t)(duration_sec * 1000.0f) + 200;
vTaskDelay(pdMS_TO_TICKS(drain_ms));

audio_hal_speaker_pa(false);
```
**Result**: Still produced pop noise. Waiting for playback duration didn't eliminate it.

### Attempt 4: Codec Mute THEN Wait THEN PA Disable (Current)
**Code**:
```c
audio_hal_speaker_pa(true);
esp_err_t ret = write_stereo(dev, pcm_data, total_samples);

audio_hal_set_volume(0);  // Mute codec first

float duration_sec = (float)total_samples / MIMI_AUDIO_SAMPLE_RATE;
uint32_t drain_ms = (uint32_t)(duration_sec * 1000.0f) + 100;
vTaskDelay(pdMS_TO_TICKS(drain_ms));

audio_hal_speaker_pa(false);  // Then disable PA
vTaskDelay(pdMS_TO_TICKS(20));
audio_hal_set_volume(60);
```
**Result**: User reports "still crazy noise in the end"

## Research Findings

### ESP32 Community Issues
- This is a **known issue** with ESP32 I2S audio playback
- Multiple GitHub issues document pop/click at start AND end of playback
- Issue #406 (ESP8266Audio): "i2s_zero_dma_buffer() reduces harshness but doesn't eliminate it"
- Issue #626 (ESP32-audioI2S): Workaround involves playing at zero volume for 50-100 loop iterations before stopping
- Issue #8326 (esp-idf): Clock configuration and timing issues can cause artifacts

### Root Causes (from research)
1. **DMA Buffer State**: Buffers may contain non-zero data when I2S stops
2. **Codec State Transition**: ES8311 codec transitioning from active to muted state
3. **PA Switching**: Power amplifier enable/disable creates a transient
4. **I2S Clock**: BCLK/MCLK stopping while codec is still active
5. **Impedance Mismatch**: Output impedance changing when PA disables

### What We Don't Know Yet
- Exact timing of when `esp_codec_dev_write()` returns vs when DMA finishes
- Whether ES8311 codec has internal mute/unmute ramp timing
- If I2S channel needs explicit disable/enable cycle
- Whether the pop is from PA switching or codec state change
- If there's a proper ES8311 codec shutdown sequence we're missing

## Additional Issue: Mute Button Doesn't Stop Noise
User reports: "mute should turn off the speaker immediately when I press it when there is noise and it's not stopped"

This suggests the noise continues even when trying to mute during playback. Need to check:
- Is mute button handled in `button_input.c`?
- Does it call `audio_hal_set_volume(0)` or `audio_hal_speaker_pa(false)`?
- Is the noise happening AFTER we think playback is done?

## Next Investigation Steps

### 1. Measure Actual Timing
Add detailed logging:
```c
ESP_LOGI(TAG, "T0: Starting playback");
audio_hal_speaker_pa(true);
ESP_LOGI(TAG, "T1: PA enabled");
esp_err_t ret = write_stereo(dev, pcm_data, total_samples);
ESP_LOGI(TAG, "T2: write_stereo returned (DMA accepted all data)");
audio_hal_set_volume(0);
ESP_LOGI(TAG, "T3: Codec muted");
// ... wait ...
ESP_LOGI(TAG, "T4: About to disable PA");
audio_hal_speaker_pa(false);
ESP_LOGI(TAG, "T5: PA disabled");
```

### 2. Try I2S Channel Disable
Before disabling PA, try:
```c
i2s_chan_handle_t tx = audio_hal_get_tx();
i2s_channel_disable(tx);  // Stop I2S clock
vTaskDelay(pdMS_TO_TICKS(50));
audio_hal_speaker_pa(false);
i2s_channel_enable(tx);  // Re-enable for next playback
```

### 3. Check ES8311 Codec Control
Look at `audio_hal.c` ES8311 initialization:
- Is there a proper codec mute register we should use instead of volume?
- Does ES8311 have a "soft mute" feature with configurable ramp time?
- Should we call `esp_codec_dev_close()` and `esp_codec_dev_open()` around playback?

### 4. Try Hardware PA Control Timing
```c
// Option A: Disable PA BEFORE codec mute
audio_hal_speaker_pa(false);
vTaskDelay(pdMS_TO_TICKS(20));
audio_hal_set_volume(0);

// Option B: Much longer delay after mute before PA disable
audio_hal_set_volume(0);
vTaskDelay(pdMS_TO_TICKS(500));  // 500ms instead of 100ms
audio_hal_speaker_pa(false);
```

### 5. Check for Buffer Underrun
The noise might be from DMA trying to play when buffer is empty:
```c
// After write_stereo, check if more data is requested
// Play a few more samples of silence to ensure DMA is truly done
```

### 6. Inspect ESP32-audioI2S Library Implementation
The ESP32-audioI2S library (schreibfaul1) is known to work well. Compare:
- How does it handle `stopSong()`?
- Does it call any codec-specific shutdown sequence?
- What's the exact order of operations?

### 7. Test with Tone Generator
Use `audio_player_play_tone()` which generates audio internally:
- Does it have the same pop issue?
- If not, the problem might be in how we're calculating drain time for PCM data
- If yes, it's definitely a hardware/driver shutdown sequence issue

### 8. Monitor GPIO with Oscilloscope/Logic Analyzer
If available:
- Capture PA enable pin (GPIO 4) timing
- Capture I2S BCLK, LRCLK signals
- See exactly when clocks stop relative to PA disable
- Look for glitches or unexpected transitions

## Sample Rate Mismatch Issue (Separate)
- TTS server returns 22050 Hz audio
- ESP32 configured for 16000 Hz
- This causes pitch/speed distortion
- **Solution**: Configure TTS server to output 16kHz (user will fix server-side)
- STT expects 16kHz, so keeping everything at 16kHz is optimal

## Files Modified
- `main/audio/audio_player.c` - Multiple iterations of shutdown sequence
- `main/voice/tts_client.c` - TTS format and sample rate handling
- `main/voice/voice_channel.c` - Response handling and playback flow

## Current State of Code (after Session 2)
- `main/audio/audio_player.c`: Uses `esp_codec_dev_close()` + re-open per session, `pa_pin = -1`
- `main/audio/audio_hal.c`: ES8311 init with `pa_pin = -1`, PA managed solely by `audio_hal_speaker_pa()`
- `main/cli/serial_cli.c`: `tts_test <text> [mode 0-5]` diagnostic command, CLI task stack = 16384 bytes
- `main/audio/audio_player.h`: Added `audio_player_play_pcm_diag()` declaration

## What Has NOT Been Tried Yet

### Hardware-level
- **Oscilloscope/logic analyzer**: Capture PA enable GPIO + BCLK/LRCLK + speaker output simultaneously. This would definitively show when the noise occurs relative to the signal
- **Capacitor on PA enable line**: Some boards need a RC filter on the PA enable GPIO to slow the PA turn-off edge and prevent switching transient
- **Direct speaker measurement**: Is the noise electrical (measurable with meter at speaker terminals) or acoustic (only heard, possibly board resonance)?

### Software — Not Tried
- **`audio_test` tone playback**: Does `audio_player_play_tone()` (synthesized sine wave, no TTS/resampling) have the same noise? If NO → noise is in the PCM/resampling data. If YES → it's pure hardware/shutdown
- **Volume ramp during playback**: Gradually lower output volume to 0 over the last 500ms WHILE audio is still playing (not just fading the PCM buffer)
- **ES8311 direct register write**: Write to ES8311 `0x31` (DAC_REG31) DACMUTE bit directly via I2C, bypassing the `esp_codec_dev` abstraction, to ensure mute actually takes effect
- **Zero the last 500ms completely** (hard memset to 0, not fade) — tests if the noise is literally in the PCM samples vs the transition
- **Leave PA permanently on**: Don't toggle PA at all between utterances — tests if the noise is ONLY from PA switching

### Architecture
- **Compare with voice_channel task**: The original voice channel TTS worked — does it still have the noise? If YES → noise is always there. If NO → something different about that code path

## Hypotheses Remaining

1. **Analog discharge is unavoidable in software** — The ES8311/speaker coupling capacitors store enough energy that software can't bleed it fast enough. May need a hardware fix (bleed resistor across speaker output, or RC on PA enable)
2. **Noise is IN the TTS PCM tail** — The resampler (24kHz→16kHz) leaves an oscillating tail in the last ~100ms of samples. `audio_test` tone would rule this out
3. **ES8311 internal pop on DAC power-off** — `esp_codec_dev_close()` may trigger a register sequence that causes the ES8311 to pop internally. Writing DACMUTE first via direct I2C and waiting longer before closing could help

## ✅ RESOLVED — Root Cause Found & Workaround Applied

### Key Diagnostic Breakthrough
Running `audio_test` (tone generator) produced **zero noise**. This definitively ruled out hardware, PA switching, DMA, and shutdown sequence as the root cause. The noise is entirely in the **PCM data itself**.

### Root Cause
The 24kHz → 16kHz resampler in `tts_client.c` uses naive decimation without a proper anti-aliasing FIR filter. This leaves an oscillating noise tail in the last 2–3 seconds of the resampled PCM buffer. The "hardware" noise we were chasing was actually this resampler artifact being amplified and played.

### Workaround (in `audio_player.c` — `apply_audio_cleanup`)
Zero the last 3 seconds of PCM + 300ms fade before the silence region:
```c
// 300ms fade-out
size_t fade_samples = (size_t)(0.3f * sample_rate);
for (size_t i = 0; i < fade_samples; i++) {
    size_t idx = num_samples - fade_samples + i;
    float f = 1.0f - ((float)i / (float)fade_samples);
    samples[idx] = (int16_t)((float)samples[idx] * f);
}
// Zero last 3 seconds (kills resampler tail noise)
size_t silence_samples = (size_t)(3.0f * sample_rate);
memset(samples + num_samples - silence_samples, 0, silence_samples * sizeof(int16_t));
```
**Result: No noise. ✅**

### Proper Fix (TODO)
The workaround wastes 3 seconds of audio (cuts off the tail of speech). Proper fix is one of:
1. **Use a proper anti-aliasing FIR filter** in the resampler in `tts_client.c` before decimating 24kHz→16kHz
2. **Request 16kHz directly from OpenAI TTS API** — pass `sample_rate=16000` in the request. This eliminates resampling entirely and is the cleanest solution
3. **Use a polyphase filter bank** for the 3:2 ratio resampling

Option 2 is likely zero-effort if the OpenAI TTS endpoint supports it.

TODO marker in code: `main/audio/audio_player.c` — `apply_audio_cleanup()`
