// Earshot clip firmware for the M5Stack Atom VoiceS3R (ESP32-S3, ES8311 mic codec).
//
// All behaviour (button gestures, listening state, streaming, protocol)
// lives in lib/earshot_core and is shared with the laptop simulator. This file only connects
// that core to the real hardware: button pin, LED ring, microphone and Wi-Fi.
//
// Built with -DEARSHOT_WOKWI (the `wokwi` environment) it runs on Wokwi's virtual ESP32-S3
// instead: same button, LED ring and Wi-Fi code, but Wokwi cannot simulate the microphone
// bus, so the mic is replaced by a generated tone and M5Unified is left out.
#include <Arduino.h>
#include <WiFi.h>
#include <Adafruit_NeoPixel.h>
#include <esp_system.h>
#if __has_include(<esp_random.h>)
#include <esp_random.h>  // esp_random() lives here on newer ESP-IDF versions
#endif

#ifdef EARSHOT_WOKWI
#include "config.example.h"  // pins only; the network settings below are fixed by the simulator
#undef WIFI_SSID
#undef WIFI_PASSWORD
#undef GATEWAY_HOST
#define WIFI_SSID "Wokwi-GUEST"              // Wokwi's virtual access point
#define WIFI_PASSWORD ""
#define GATEWAY_HOST "host.wokwi.internal"   // this laptop, as seen from the simulated board
#undef LED_BRIGHTNESS
#define LED_BRIGHTNESS 255                   // full brightness: the virtual ring is hard to see when dimmed
#else
#include <M5Unified.h>
#if __has_include("config.h")
#include "config.h"
#else
#error "Copy include/config.example.h to include/config.h and fill in Wi-Fi and gateway details."
#endif
#endif

#include "clip_app.h"

// Audio compression: Opus at AUDIO_OPUS_KBPS kbit/s, or raw audio when it is 0.
#ifndef AUDIO_OPUS_KBPS
#define AUDIO_OPUS_KBPS 32
#endif
#ifdef EARSHOT_WOKWI
#undef AUDIO_OPUS_KBPS
#define AUDIO_OPUS_KBPS 0  // Wokwi's emulated chip is too slow to encode Opus in real time
#endif
#if AUDIO_OPUS_KBPS > 0
#include "opus_audio_encoder.h"
// Opus keeps its working buffers on the stack; the default 8 KB loop stack is far too small.
SET_LOOP_TASK_STACK_SIZE(48 * 1024);
static earshot::OpusAudioEncoder* g_opus = nullptr;
#endif

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

// ---------------------------------------------------------------- hardware

class Esp32Hal : public earshot::Hal {
 public:
  Esp32Hal() : ring_(LED_COUNT, LED_PIN, NEO_GRB + NEO_KHZ800), mic_on_(false), next_(0), primed_(0) {}

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
      case earshot::LedColor::Off: c = 0; break;
    }
    ring_.fill(c);
    ring_.show();
  }

#ifdef EARSHOT_WOKWI
  // Stand-in microphone for Wokwi: a 440 Hz tone, one 20 ms frame at a time.
  bool micStart() override {
    mic_on_ = true;
    next_frame_ms_ = ::millis() + earshot::kFrameMs;
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
    for (size_t i = 0; i < samples; ++i) {
      out[i] = (int16_t)(6000.0f * sinf(2.0f * PI * 440.0f * (float)phase_ / earshot::kSampleRate));
      phase_ = (phase_ + 1) % earshot::kSampleRate;
    }
    return samples;
  }
#else
  bool micStart() override {
    if (mic_on_) return true;
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
#endif

  bool networkUp() override { return WiFi.status() == WL_CONNECTED; }
  void log(const char* message) override { Serial.printf("[clip] %s\n", message); }

 private:
  Adafruit_NeoPixel ring_;
  bool mic_on_;
  uint8_t next_;
  uint8_t primed_;
  int16_t bufs_[3][earshot::kFrameSamples];
  uint32_t next_frame_ms_ = 0;  // Wokwi stand-in mic only
  uint32_t phase_ = 0;
};

// ---------------------------------------------------------------- button sampling task
// The button is sampled every 5 ms on its own task, so a tap is never missed while the main
// loop is busy (for example, waiting on a network connect). Detected gestures go to a queue.

static QueueHandle_t g_button_events;

static void buttonTask(void*) {
  earshot::Button detector;
  for (;;) {
    earshot::ButtonEvent e = detector.update(digitalRead(BUTTON_PIN) == LOW, millis());
    if (e != earshot::ButtonEvent::None) xQueueSend(g_button_events, &e, 0);
    vTaskDelay(pdMS_TO_TICKS(5));
  }
}

// ---------------------------------------------------------------- setup / loop

static Esp32Hal g_hal;
static Esp32Transport g_transport;
static earshot::ClipApp* g_app = nullptr;

void setup() {
#ifdef EARSHOT_WOKWI
  Serial.begin(115200);
  g_hal.begin();
  Serial.printf("\n[clip] Earshot clip firmware %s (Wokwi build, tone instead of microphone)\n",
                earshot::kFirmwareVersion);
#else
  auto cfg = M5.config();
  cfg.serial_baudrate = 115200;
  cfg.internal_mic = true;
  cfg.internal_spk = false;  // mic and speaker share the codec's I2S bus; we only capture
  cfg.internal_imu = false;
  cfg.internal_rtc = false;
  M5.begin(cfg);

  g_hal.begin();
  Serial.printf("\n[clip] Earshot clip firmware %s\n", earshot::kFirmwareVersion);
  if (!M5.Mic.isEnabled()) Serial.println("[clip] WARNING: M5Unified found no microphone on this board");
#endif

  WiFi.mode(WIFI_STA);
  WiFi.setSleep(false);  // lower latency for the audio stream
  WiFi.setAutoReconnect(true);
#ifdef EARSHOT_WOKWI
  WiFi.begin(WIFI_SSID, WIFI_PASSWORD, 6);  // channel 6 skips the scan in the simulator
#else
  WiFi.begin(WIFI_SSID, WIFI_PASSWORD);
#endif

  g_button_events = xQueueCreate(8, sizeof(earshot::ButtonEvent));
  xTaskCreate(buttonTask, "button", 3072, nullptr, 5, nullptr);

  earshot::ClipConfig app_cfg;
  app_cfg.gateway_host = GATEWAY_HOST;
  app_cfg.gateway_port = GATEWAY_PORT;
  app_cfg.poll_button = false;  // buttonTask does the detection
#ifdef EARSHOT_STANDALONE
  app_cfg.gateway_enabled = false;  // no tablet to reach (the Wokwi website)
#endif
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
  g_app = new earshot::ClipApp(g_hal, g_transport, app_cfg, esp_random());
  g_app->begin();
}

void loop() {
  earshot::ButtonEvent e;
  while (xQueueReceive(g_button_events, &e, 0) == pdTRUE) g_app->onButtonEvent(e);

  g_app->tick();

  static uint32_t last_report = 0;
  uint32_t now = millis();
  if (now - last_report >= 5000) {
    last_report = now;
    const earshot::ClipStats& s = g_app->stats();
    Serial.printf("[clip] state=%s wifi=%s link=%s captured=%lu sent=%lu dropped=%lu markers=%lu captures=%lu\n",
                  earshot::stateName(g_app->state()),
                  WiFi.status() == WL_CONNECTED ? WiFi.localIP().toString().c_str() : "down",
                  g_app->linkOpen() ? "open" : "closed", (unsigned long)s.frames_captured,
                  (unsigned long)s.frames_sent, (unsigned long)s.frames_dropped,
                  (unsigned long)s.markers, (unsigned long)s.captures);
#if AUDIO_OPUS_KBPS > 0
    // Each frame is 20 ms long, so encoding one must take well under 20 ms to keep up.
    if (g_opus && s.frames_captured > 0)
      Serial.printf("[clip] slowest Opus encode so far: %.1f ms per 20 ms frame\n",
                    g_opus->maxEncodeMicros() / 1000.0f);
#endif
  }
}
