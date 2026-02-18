# MimiClaw Hardware Integration Guide

## Board: xingzhi-cube 1.83" 2mic (ESP32-S3)

- **SoC**: ESP32-S3 (dual-core 240MHz)
- **Flash**: 16MB (Octal)
- **PSRAM**: 8MB (Octal)
- **Display**: 1.83" SPI LCD 284x240 (ST7789V-like with custom vendor init)
- **Speaker DAC**: ES8311 (I2C addr 0x18)
- **Mic ADC**: ES7210 4-channel (I2C addr 0x40, 2 mics connected)
- **Buttons**: 3 (GPIO0, GPIO39, GPIO40) — all active LOW
- **LED**: WS2812 on GPIO48
- **Speaker PA**: GPIO4 (active HIGH)

---

## Pin Map

| Function       | GPIO | Notes                          |
|----------------|------|--------------------------------|
| I2C SDA        | 12   | Shared: ES8311 + ES7210        |
| I2C SCL        | 11   | 400kHz                         |
| I2S MCLK       | 5    | Shared TX/RX, 256x multiplier  |
| I2S BCLK       | 15   | Shared TX/RX                   |
| I2S LRCLK (WS) | 16   | Shared TX/RX                   |
| I2S DOUT       | 6    | ESP32 → ES8311 (speaker)       |
| I2S DIN        | 7    | ES7210 → ESP32 (mic)           |
| Speaker PA EN  | 4    | Active HIGH, must enable for sound |
| LCD SPI CLK    | 9    | SPI2_HOST, 40MHz               |
| LCD SPI MOSI   | 10   |                                |
| LCD CS         | 14   |                                |
| LCD DC         | 8    |                                |
| LCD RST        | 18   | Hardware reset (active LOW)    |
| LCD Backlight  | 13   | LEDC PWM (TIMER_0, CH_0)      |
| Button WAKE    | 0    | Top button, tracks press+release |
| Button MUTE    | 39   | Left button                    |
| Button VOLUME  | 40   | Right button                   |
| WS2812 LED     | 48   |                                |

---

## Audio Subsystem

### Critical Lessons Learned

1. **Init order matters**: I2S channels MUST be created BEFORE codecs.
   `esp_codec_dev_new()` requires a non-NULL `data_if` parameter, which comes from
   `audio_codec_new_i2s_data()` — and that needs the I2S channel handle.

2. **esp_codec_dev handles I2S enable**: After `esp_codec_dev_open()`, the I2S channel
   is already enabled. Do NOT call `i2s_channel_enable()` again or it returns an error.

3. **Use esp_codec_dev_write/read, not raw i2s_channel_write/read**: The codec dev
   abstraction handles volume control, format conversion, and proper I2S interaction.

4. **Speaker PA must be explicitly enabled**: GPIO4 must be set HIGH before any audio
   output. Forgetting this = silence even if everything else works.

5. **ES7210 outputs stereo (2-channel interleaved)**: Even though there are 2 physical
   mics, the codec outputs interleaved L/R samples. Extract channel 0 for mono.

### Init Sequence (audio_hal.c)

```
1. Configure Speaker PA GPIO (output, start LOW)
2. Init I2C master bus (SDA=12, SCL=11, 400kHz)
3. Probe I2C addresses: 0x18 (ES8311), 0x40 (ES7210)
4. Create I2S channel pair (TX + RX on same port)
   - TX: Standard Philips mode, 16kHz, 16-bit, stereo
   - RX: TDM mode, 4 slots (ES7210 is 4-ch TDM device)
   - MCLK multiple: 256 (256 x 16000 = 4.096MHz)
   - DMA: 6 descriptors, 240 frames each
5. Create I2S data interfaces:
   - audio_codec_new_i2s_data() for TX (speaker)
   - audio_codec_new_i2s_data() for RX (mic)
6. Create codec control interfaces via I2C
7. Create ES8311 codec → esp_codec_dev_new() with TX data_if
8. Create ES7210 codec → esp_codec_dev_new() with RX data_if
9. esp_codec_dev_open() on both (configures codec registers + enables I2S)
10. Set volume (0-100, we use 60 for comfortable level)
```

### Audio Playback

```c
// Get output device
esp_codec_dev_handle_t dev = audio_hal_get_output_dev();

// Enable PA
audio_hal_speaker_pa(true);

// Write stereo interleaved 16-bit samples
// Mono source must be duplicated to L+R channels
esp_codec_dev_write(dev, stereo_buf, stereo_bytes);

// Disable PA when done
audio_hal_speaker_pa(false);
```

### Audio Recording

```c
// Get input device
esp_codec_dev_handle_t dev = audio_hal_get_input_dev();

// Read stereo interleaved data
esp_codec_dev_read(dev, buf, bytes);

// Extract mono (left channel):
for (int i = 0; i < num_frames; i++) {
    mono[i] = stereo[i * 2];  // take left channel
}
```

### Volume & Amplitude

- Codec volume: 60 (out of 100) — set via `esp_codec_dev_set_out_vol()`
- Tone amplitude: 10000 (out of 32767) — good for comfortable listening
- These values were tuned on hardware; 100/30000 was painfully loud

### Dependencies

- Component: `espressif/esp_codec_dev: "^1.3.0"` (in `idf_component.yml`)
- ESP-IDF requires: `esp_driver_i2c`, `esp_driver_i2s`

---

## Display Subsystem

### Critical Lessons Learned

1. **NOT a standard ST7789**: The display uses a custom controller that requires a
   vendor-specific init sequence of ~30 commands BEFORE the ST7789 panel driver is used.
   Using just `esp_lcd_new_panel_st7789()` without vendor init = blank screen.

2. **Vendor init comes from ESPHome YAML**: The xingzhi-cube ESPHome config file
   contains the exact init command sequence. These are sent via `esp_lcd_panel_io_tx_param()`
   before creating the ST7789 panel.

3. **Orientation requires specific transforms**: The 284x240 resolution needs
   `swap_xy=true`, `mirror_y=true`, `gap_x=36`. Without the gap offset, the image
   is shifted.

### Init Sequence (display_driver.c)

```
1. Init LEDC PWM backlight (GPIO13, TIMER_0, CH_0, 5kHz, 8-bit)
2. Init SPI bus (SPI2_HOST, CLK=9, MOSI=10, 40MHz)
3. Create panel IO (CS=14, DC=8)
4. Hardware reset (GPIO18: LOW 20ms → HIGH 120ms)
5. Send 30 vendor-specific init commands via esp_lcd_panel_io_tx_param()
6. Create ST7789 panel (for draw_bitmap API, reset_gpio=-1 since already reset)
7. esp_lcd_panel_init() — sends SLPOUT + COLMOD + MADCTL + DISPON
8. Invert colors (invert_colors: true)
9. Set gap: x=36, y=0
10. Transform: swap_xy=true, mirror_x=false, mirror_y=true
11. Set backlight to 80%
```

### Display API

```c
display_init();                          // Full init
display_fill_color(DISPLAY_COLOR_GREEN); // Fill solid color
display_set_backlight(80);               // 0-100%
display_set_state(DISPLAY_STATE_IDLE);   // Color-coded states
```

### Color Format

RGB565, byte-swapped for big-endian SPI:
- Black:  0x0000
- White:  0xFFFF
- Red:    0x00F8
- Green:  0xE007
- Blue:   0x1F00
- Yellow: 0xE0FF

### Dependencies

- ESP-IDF requires: `esp_lcd`, `esp_driver_ledc`

---

## Button Subsystem

### Setup

All 3 buttons are active LOW with internal pull-ups enabled.

```
GPIO0  (Top)   — WAKE / Push-to-talk (tracks press AND release)
GPIO39 (Left)  — MUTE toggle (press only)
GPIO40 (Right) — VOLUME cycle (press only)
```

### Architecture

```
GPIO ISR (IRAM) → FreeRTOS Queue → Debounce Task (50ms) → User Callback
```

- ISR sends GPIO number to queue on ANY_EDGE
- Debounce task filters events within 50ms window
- Wake button generates both PRESS and RELEASE events
- Task stack: 4096 bytes (2048 caused stack overflow due to ESP_LOGI in task)

### Lesson Learned

- **Stack size 2048 is NOT enough** for a task that uses `ESP_LOGI()`. The logging
  functions need significant stack space. Use 4096 minimum for any task with logging.

---

## STT (Speech-to-Text) Client

### Server: faster-whisper

```
POST http://<host>:8000/v1/audio/transcriptions
Content-Type: multipart/form-data

Fields:
  file: audio.wav (16-bit mono PCM with WAV header)
  model: "Systran/faster-whisper-tiny"

Response: {"text": "transcribed text", "language": "en", "duration": 3.0, ...}
```

### Implementation Notes

- Record mono 16kHz 16-bit PCM into PSRAM buffer
- Build 44-byte WAV header in memory
- Assemble multipart/form-data body in PSRAM
- Use `esp_http_client_open()` + `esp_http_client_write()` for streaming upload
  (body can be ~100KB+ for a few seconds of audio)
- Parse JSON response with cJSON, extract "text" field
- Round-trip latency: ~1.2 seconds on LAN for 3s recording

---

## TTS (Text-to-Speech) Client

### Server: OpenAI-compatible TTS API

```
POST http://<host>:8000/v1/audio/speech
Content-Type: application/json

Body: {"model": "pyttsx3", "input": "text to speak", "speed": 1.0}

Response: WAV audio binary (may be different sample rate than 16kHz)
```

### Implementation Notes

- Response audio may come back at 22050 Hz (not 16kHz). The audio_player handles
  this because it just writes samples — but playback speed will be slightly off
  (22050/16000 = 1.38x slower pitch). For production, reconfigure I2S clock or
  resample.
- Allocate 512KB PSRAM buffer for response (typical response ~160KB for short sentences)
- Response can be WAV (with RIFF header) or raw PCM — check for "RIFF" magic bytes
- Stereo WAV responses are downmixed to mono (left channel) before playback

---

## Merging Back to Main Project

### Files to Add

| File | Purpose |
|------|---------|
| `main/audio/audio_hal.h` + `.c` | I2C + I2S + codec init |
| `main/audio/audio_player.h` + `.c` | PCM/WAV/tone playback |
| `main/audio/test_audio.h` + `.c` | Debug test (can remove in production) |
| `main/display/display_driver.h` + `.c` | SPI LCD driver |
| `main/input/button_input.h` + `.c` | GPIO button handler |
| `main/voice/stt_client.h` + `.c` | faster-whisper HTTP client |
| `main/voice/tts_client.h` + `.c` | TTS HTTP client |
| `main/idf_component.yml` | esp_codec_dev dependency |

### CMakeLists.txt Changes

Add to SRCS:
```
"audio/audio_hal.c"
"audio/audio_player.c"
"audio/test_audio.c"
"display/display_driver.c"
"input/button_input.c"
"voice/stt_client.c"
"voice/tts_client.c"
```

Add to REQUIRES:
```
esp_driver_i2c esp_driver_i2s esp_driver_gpio esp_lcd esp_driver_ledc
```

### mimi_config.h Additions

All pin defines (I2C, I2S, SPI LCD, buttons, speaker PA, LED) and:
```c
#define MIMI_AUDIO_SAMPLE_RATE   16000
#define MIMI_AUDIO_BITS          16
#define MIMI_AUDIO_CHANNELS      1
#define MIMI_I2S_DMA_DESC_NUM    6
#define MIMI_I2S_DMA_FRAME_NUM   240
#define MIMI_LCD_WIDTH           284
#define MIMI_LCD_HEIGHT          240
```

### mimi_secrets.h Additions

```c
#define MIMI_SECRET_STT_HOST     "192.168.x.x"
#define MIMI_SECRET_STT_PORT     "8000"
#define MIMI_SECRET_STT_MODEL    "Systran/faster-whisper-tiny"
#define MIMI_SECRET_TTS_MODEL    "pyttsx3"
```

### Init Order in app_main()

```c
audio_hal_init();      // I2C + I2S + codecs
display_init();        // SPI LCD + backlight
button_input_init(cb); // GPIO buttons
// voice_channel_init() — Stage 9
```

### CLI Test Commands

| Command | Description |
|---------|-------------|
| `play_tone <freq> <ms>` | Play sine wave (loops 10x) |
| `audio_test` | Raw I2S + codec + mic loopback |
| `display_test` | Cycle through colors |
| `button_test` | Listen for button presses |
| `stt_test <seconds>` | Record + transcribe |
| `tts_test "<text>"` | Synthesize + play |

### Memory Budget (PSRAM)

| Item | Size |
|------|------|
| STT recording (10s max) | 320 KB |
| TTS response buffer | 512 KB |
| LCD row buffer (DMA) | ~1 KB |
| **Total new PSRAM** | **~833 KB** |
| Remaining from ~7.7MB free | **~6.9 MB** |
