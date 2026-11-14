// Resolves the build's settings: which board, which microphone, which link.
// Everything board-specific in the firmware hangs off the macros defined here.
#pragma once
#include <Arduino.h>

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
#undef LINK_BLUETOOTH
#define LINK_BLUETOOTH 0                     // Wokwi does not simulate Bluetooth on the ESP32-S3
#undef AUDIO_OPUS_KBPS
#define AUDIO_OPUS_KBPS 0                    // nor is its emulated chip fast enough for Opus
#elif __has_include("config.h")
#include "config.h"
#define EARSHOT_HAVE_CONFIG 1
#else
#include "config.example.h"  // fine for Bluetooth, which needs no network details
#endif

// ---- link: Bluetooth LE unless config.h says LINK_BLUETOOTH 0 (Wi-Fi + WebSocket)
#ifndef LINK_BLUETOOTH
#define LINK_BLUETOOTH 1
#endif
#if !LINK_BLUETOOTH && !defined(EARSHOT_WOKWI) && !defined(EARSHOT_HAVE_CONFIG)
#error "Wi-Fi link: copy include/config.example.h to include/config.h and fill in Wi-Fi and gateway details."
#endif

// ---- audio compression: Opus at AUDIO_OPUS_KBPS kbit/s, or raw audio when it is 0
#ifndef AUDIO_OPUS_KBPS
#define AUDIO_OPUS_KBPS 32
#endif
#if LINK_BLUETOOTH && AUDIO_OPUS_KBPS == 0
#error "Raw audio does not fit in a Bluetooth packet. Set AUDIO_OPUS_KBPS to 32, or LINK_BLUETOOTH to 0."
#endif
#if LINK_BLUETOOTH && AUDIO_OPUS_KBPS > 56
#error "At more than 56 kbit/s an Opus frame no longer fits in one Bluetooth packet."
#endif

// ---- board: pins and microphone
#if defined(EARSHOT_BOARD_FEATHER)
// Adafruit ESP32-S3 Feather. No microphone and no LED ring, so:
#undef BUTTON_PIN
#undef LED_PIN
#undef LED_COUNT
#define BUTTON_PIN 0            // the BOOT button, active low
#define LED_PIN PIN_NEOPIXEL    // the onboard NeoPixel (its power pin is switched on by the board support code)
#define LED_COUNT 1
#define EARSHOT_BOARD_NAME "ESP32-S3 Feather"
#define EARSHOT_MIC_VOICE 1     // plays the stored voice recording as the microphone
#elif defined(EARSHOT_WOKWI)
#define EARSHOT_BOARD_NAME "Wokwi virtual ESP32-S3"
#define EARSHOT_MIC_TONE 1      // a generated 440 Hz tone
#else
#define EARSHOT_BOARD_NAME "Atom VoiceS3R"
#define EARSHOT_MIC_M5 1        // the real microphone, through M5Unified
#endif
