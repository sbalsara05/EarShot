// Earshot clip firmware for the ESP32-S3.
//
// All behaviour (button gestures, listening state, streaming, protocol) lives in
// lib/earshot_core and is shared with the laptop simulator. This file only connects that core
// to the real hardware: button pin, light, microphone and the link to the tablet.
//
// One source, three builds (see platformio.ini and build_config.h):
//   atom-voices3r   M5Stack Atom VoiceS3R: the real clip, with its microphone
//   feather-s3      Adafruit ESP32-S3 Feather: no microphone, so it plays a stored voice
//                   recording as if it were one; BOOT button and the onboard NeoPixel
//   wokwi           Wokwi's virtual ESP32-S3: a tone for the microphone, Wi-Fi only
//
// The link is Bluetooth LE by default (ble_link.h), or Wi-Fi + WebSocket with LINK_BLUETOOTH 0.
#include "build_config.h"

#include <Adafruit_NeoPixel.h>
#include <esp_system.h>
#if __has_include(<esp_mac.h>)
#include <esp_mac.h>  // esp_efuse_mac_get_default() lives here on newer ESP-IDF versions
#endif
#if __has_include(<esp_random.h>)
#include <esp_random.h>  // esp_random() lives here on newer ESP-IDF versions
#endif

#if EARSHOT_MIC_M5
#include <M5Unified.h>
#endif
#if EARSHOT_MIC_VOICE
#include "voice_clip.h"
#include "voice_clip_data.h"
#endif
#if LINK_BLUETOOTH
#include "ble_link.h"
#else
#include <WiFi.h>
#endif

#include "clip_app.h"

#if AUDIO_OPUS_KBPS > 0
#include "opus_audio_encoder.h"
// Opus keeps its working buffers on the stack; the default 8 KB loop stack is far too small.
SET_LOOP_TASK_STACK_SIZE(48 * 1024);
static earshot::OpusAudioEncoder* g_opus = nullptr;
#endif

#if !LINK_BLUETOOTH
// ---------------------------------------------------------------- network transport

class Esp32Transport : public earshot::Transport {
 public:
  bool connect(const char* host, uint16_t port) override {
    client_.stop();
    if (!client_.connect(host, port, 700 /* ms */)) return false;
    client_.setNoDelay(true);  // audio frames should leave immediately
    return true;
  }
  bool connected() override { return client_.connected(); }
  size_t write(const uint8_t* data, size_t len) override { return client_.write(data, len); }
  int read(uint8_t* buf, size_t len) override {
    if (client_.available() > 0) return client_.read(buf, len);
    return client_.connected() ? 0 : -1;
  }
  void close() override { client_.stop(); }

 private:
  WiFiClient client_;
};
#endif  // !LINK_BLUETOOTH

// ---------------------------------------------------------------- hardware

class Esp32Hal : public earshot::Hal {
 public:
  Esp32Hal()
      : ring_(LED_COUNT, LED_PIN, NEO_GRB + NEO_KHZ800),
        mic_on_(false)
#if EARSHOT_MIC_VOICE
        ,
        voice_(kVoiceClipAdpcm, kVoiceClipBytes)
#endif
  {
  }

  void begin() {
    pinMode(BUTTON_PIN, INPUT_PULLUP);
    ring_.begin();
    ring_.setBrightness(LED_BRIGHTNESS);
    ring_.clear();
    ring_.show();
  }

  uint32_t millis() override { return ::millis(); }
  void sleepMs(uint32_t ms) override { delay(ms); }
  bool buttonPressed() override { return digitalRead(BUTTON_PIN) == LOW; }

  void setLed(earshot::LedColor color) override {
    uint32_t c = 0;
    switch (color) {
      case earshot::LedColor::Green: c = ring_.Color(0, 255, 60); break;
      case earshot::LedColor::White: c = ring_.Color(255, 255, 255); break;
      case earshot::LedColor::Blue: c = ring_.Color(0, 60, 255); break;
      case earshot::LedColor::Red: c = ring_.Color(255, 0, 0); break;
      case earshot::LedColor::Off: c = 0; break;
    }
    ring_.fill(c);
    ring_.show();
  }

#if EARSHOT_MIC_M5
  bool micStart() override {
    if (mic_on_) return true;
    beepDone();  // the speaker and the microphone share one audio chip: only one at a time
    auto cfg = M5.Mic.config();
    // Keep M5Unified's board defaults for the Atom VoiceS3R (stereo I2S input, pins, codec
    // clocking): the ES8311 derives its clock from the bit clock, so changing the input format
    // would mis-clock it. record() below asks for mono 16 kHz output.
    cfg.sample_rate = earshot::kSampleRate;
#ifdef MIC_MAGNIFICATION
    cfg.magnification = MIC_MAGNIFICATION;
#endif
    M5.Mic.config(cfg);
    mic_on_ = M5.Mic.begin();
    next_ = 0;
    primed_ = 0;
    return mic_on_;
  }

  void micStop() override {
    if (mic_on_) M5.Mic.end();
    mic_on_ = false;
    memset(bufs_, 0, sizeof bufs_);  // nothing captured stays in memory after power-off
  }

  // M5.Mic.record() queues a buffer and returns; it blocks while two buffers are already
  // queued. So with three buffers in rotation, when record(buffer N) returns, buffer N-2 is
  // complete. That blocking is what paces the main loop at one frame (20 ms) per pass.
  size_t micRead(int16_t* out, size_t samples) override {
    if (!mic_on_ || samples != earshot::kFrameSamples) {
      delay(5);
      return 0;
    }
    if (!M5.Mic.record(bufs_[next_], samples, earshot::kSampleRate)) {
      delay(5);
      return 0;
    }
    next_ = (next_ + 1) % 3;
    if (primed_ < 2) {
      ++primed_;
      return 0;
    }
    memcpy(out, bufs_[next_], samples * sizeof(int16_t));
    return samples;
  }
#else
  // Stand-in microphones for boards without one. Both hand out one 20 ms frame every 20 ms,
  // as a real microphone would:
  //   voice  the stored recording (Feather), from the top at every start, looping
  //   tone   a 440 Hz tone (Wokwi)
  bool micStart() override {
    mic_on_ = true;
    next_frame_ms_ = ::millis() + earshot::kFrameMs;
#if EARSHOT_MIC_VOICE
    voice_.rewind();
#endif
    return true;
  }
  void micStop() override { mic_on_ = false; }
  size_t micRead(int16_t* out, size_t samples) override {
    if (!mic_on_) {
      delay(5);
      return 0;
    }
    int32_t wait = (int32_t)(next_frame_ms_ - ::millis());
    if (wait > 0) delay(wait);
    next_frame_ms_ += earshot::kFrameMs;
    if ((int32_t)(::millis() - next_frame_ms_) > 200) next_frame_ms_ = ::millis() + earshot::kFrameMs;
#if EARSHOT_MIC_VOICE
    voice_.read(out, samples);
#else
    for (size_t i = 0; i < samples; ++i) {
      out[i] = (int16_t)(6000.0f * sinf(2.0f * PI * 440.0f * (float)phase_ / earshot::kSampleRate));
      phase_ = (phase_ + 1) % earshot::kSampleRate;
    }
#endif
    return samples;
  }
#endif

  // ---- the "find" beep
#if EARSHOT_SPEAKER_M5
  // The Atom's speaker goes through the same audio chip as its microphone, so it is started
  // for a find and shut down again afterwards (and never used while the microphone is on).
  void beep(bool on) override {
    if (on) {
      if (mic_on_) return;
      if (!spk_on_) {
        spk_on_ = M5.Speaker.begin();
        M5.Speaker.setVolume(255);
      }
      if (spk_on_) M5.Speaker.tone(BEEP_HZ, 5000);  // until beep(false); 5 s is only a backstop
    } else if (spk_on_) {
      M5.Speaker.stop();
    }
  }
  void beepDone() override {
    if (!spk_on_) return;
    M5.Speaker.stop();
    M5.Speaker.end();
    spk_on_ = false;
  }
#elif defined(BUZZER_PIN)
  // A piezo buzzer on a spare pin.
  void beep(bool on) override {
    if (on) tone(BUZZER_PIN, BEEP_HZ);
    else noTone(BUZZER_PIN);
  }
#else
  void beep(bool) override {}  // no speaker on this board: "find" only blinks the light
#endif

#if LINK_BLUETOOTH
  bool networkUp() override { return true; }  // only the Wi-Fi link asks
#else
  bool networkUp() override { return WiFi.status() == WL_CONNECTED; }
#endif
  void log(const char* message) override { Serial.printf("[clip] %s\n", message); }

 private:
  Adafruit_NeoPixel ring_;
  bool mic_on_;
#if EARSHOT_MIC_M5
  uint8_t next_ = 0;
  uint8_t primed_ = 0;
  int16_t bufs_[3][earshot::kFrameSamples];
  bool spk_on_ = false;
#else
  uint32_t next_frame_ms_ = 0;
  uint32_t phase_ = 0;
#endif
#if EARSHOT_MIC_VOICE
  earshot::VoiceClip voice_;
#endif
};

// ---------------------------------------------------------------- button sampling task
// The button is sampled every 5 ms on its own task, so a tap is never missed while the main
// loop is busy (for example, waiting on a network connect). Detected gestures go to a queue.

static QueueHandle_t g_button_events;

struct ButtonMsg {
  earshot::ButtonEvent event;
  uint32_t began_ms;  // when the button first went down for this gesture
};

static void buttonTask(void*) {
  earshot::Button detector;
  for (;;) {
    earshot::ButtonEvent e = detector.update(digitalRead(BUTTON_PIN) == LOW, millis());
    if (e != earshot::ButtonEvent::None) {
      ButtonMsg m = {e, detector.gestureStartMs()};
      xQueueSend(g_button_events, &m, 0);
    }
    vTaskDelay(pdMS_TO_TICKS(5));
  }
}

// ---------------------------------------------------------------- setup / loop

static Esp32Hal g_hal;
static earshot::ClipApp* g_app = nullptr;
#if LINK_BLUETOOTH
static BleLink g_ble;
static char g_name[24] = CLIP_NAME_PREFIX;
#else
static Esp32Transport g_transport;
#endif

void setup() {
#if EARSHOT_MIC_M5
  auto cfg = M5.config();
  cfg.serial_baudrate = 115200;
  cfg.internal_mic = true;
  // Must be true even for capture alone: M5Unified sets up this board's microphone inside its
  // speaker set-up, and skips both when the speaker is switched off here.
  cfg.internal_spk = true;
  cfg.internal_imu = false;
  cfg.internal_rtc = false;
  M5.begin(cfg);
#else
  Serial.begin(115200);
#endif
  g_hal.begin();
  Serial.printf("\n[clip] Earshot clip firmware %s on %s\n", earshot::kFirmwareVersion, EARSHOT_BOARD_NAME);
#if EARSHOT_MIC_M5
  if (!M5.Mic.isEnabled()) Serial.println("[clip] WARNING: M5Unified found no microphone on this board");
#elif EARSHOT_MIC_VOICE
  Serial.printf("[clip] microphone: none on this board; playing a %.1f s voice recording instead\n",
                (float)(kVoiceClipBytes * 2) / earshot::kSampleRate);
#ifdef BUZZER_PIN
  Serial.printf("[clip] find: blinks the light and beeps the buzzer on pin %d\n", (int)BUZZER_PIN);
#else
  Serial.println("[clip] find: blinks the light only (no speaker on this board; see BUZZER_PIN)");
#endif
#else
  Serial.println("[clip] microphone: none in Wokwi; using a 440 Hz tone instead");
#endif

  g_button_events = xQueueCreate(8, sizeof(ButtonMsg));
  xTaskCreate(buttonTask, "button", 3072, nullptr, 5, nullptr);

  earshot::ClipConfig app_cfg;
  app_cfg.poll_button = false;  // buttonTask does the detection
#if AUDIO_OPUS_KBPS > 0
  g_opus = new earshot::OpusAudioEncoder(AUDIO_OPUS_KBPS * 1000UL, 1);
  if (g_opus->ok()) {
    app_cfg.encoder = g_opus;
    Serial.printf("[clip] audio: Opus at %d kbit/s\n", AUDIO_OPUS_KBPS);
  } else {
    Serial.println("[clip] WARNING: Opus encoder failed to start; sending raw audio instead");
  }
#else
  Serial.println("[clip] audio: raw (uncompressed)");
#endif

#if LINK_BLUETOOTH
  // The name the tablet shows: the prefix plus the last four digits of the chip's address.
  uint8_t mac[6] = {0};
  esp_efuse_mac_get_default(mac);
  snprintf(g_name, sizeof g_name, CLIP_NAME_PREFIX "%02X%02X", mac[4], mac[5]);
  app_cfg.device_id = g_name;
  if (g_ble.begin(g_name)) Serial.printf("[clip] link: Bluetooth, advertising as %s\n", g_name);
  else Serial.println("[clip] ERROR: Bluetooth failed to start");
  g_app = new earshot::ClipApp(g_hal, g_ble, app_cfg);
#else
  WiFi.mode(WIFI_STA);
  WiFi.setSleep(false);  // lower latency for the audio stream
  WiFi.setAutoReconnect(true);
#ifdef EARSHOT_WOKWI
  WiFi.begin(WIFI_SSID, WIFI_PASSWORD, 6);  // channel 6 skips the scan in the simulator
#else
  WiFi.begin(WIFI_SSID, WIFI_PASSWORD);
#endif
  Serial.printf("[clip] link: Wi-Fi \"%s\", tablet gateway %s:%d\n", WIFI_SSID, GATEWAY_HOST, GATEWAY_PORT);
  app_cfg.gateway_host = GATEWAY_HOST;
  app_cfg.gateway_port = GATEWAY_PORT;
#ifdef EARSHOT_STANDALONE
  app_cfg.gateway_enabled = false;  // no tablet to reach (the Wokwi website)
#endif
  g_app = new earshot::ClipApp(g_hal, g_transport, app_cfg, esp_random());
#endif
  g_app->begin();
}

void loop() {
  ButtonMsg m;
  while (xQueueReceive(g_button_events, &m, 0) == pdTRUE) g_app->onButtonEvent(m.event, m.began_ms);

  g_app->tick();

  static uint32_t last_report = 0;
  uint32_t now = millis();
  if (now - last_report >= 5000) {
    last_report = now;
    const earshot::ClipStats& s = g_app->stats();
    char link[96];
#if LINK_BLUETOOTH
    if (g_ble.connected())
      snprintf(link, sizeof link, "bluetooth=connected link=%s packet=%uB interval=%.1fms failed_sends=%lu",
               g_app->linkOpen() ? "open" : "closed", (unsigned)g_ble.packetBytes(),
               g_ble.intervalMs(), (unsigned long)g_ble.failedSends());
    else
      snprintf(link, sizeof link, "bluetooth=advertising-as-%s link=closed", g_name);
#else
    snprintf(link, sizeof link, "wifi=%s link=%s",
             WiFi.status() == WL_CONNECTED ? WiFi.localIP().toString().c_str() : "down",
             g_app->linkOpen() ? "open" : "closed");
#endif
    Serial.printf("[clip] state=%s %s captured=%lu sent=%lu dropped=%lu markers=%lu rec_toggles=%lu call_toggles=%lu finds=%lu captures=%lu\n",
                  earshot::stateName(g_app->state()), link, (unsigned long)s.frames_captured,
                  (unsigned long)s.frames_sent, (unsigned long)s.frames_dropped,
                  (unsigned long)s.markers, (unsigned long)s.toggles, (unsigned long)s.call_toggles, (unsigned long)s.finds,
                  (unsigned long)s.captures);
#if AUDIO_OPUS_KBPS > 0
    // Each frame is 20 ms long, so encoding one must take well under 20 ms to keep up.
    if (g_opus && s.frames_captured > 0)
      Serial.printf("[clip] slowest Opus encode so far: %.1f ms per 20 ms frame\n",
                    g_opus->maxEncodeMicros() / 1000.0f);
#endif
  }
}
