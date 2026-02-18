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

## Conclusion
The audio pop/click at end of playback is a persistent hardware/driver issue that hasn't been solved by:
- Timing adjustments
- Codec muting
- Silence injection
- PA enable sequencing

Need to investigate at a deeper level, possibly involving ES8311 codec register control, I2S channel lifecycle, or hardware-level solutions (capacitors, pulldowns, etc.).
