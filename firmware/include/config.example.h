// Copy this file to include/config.h (which is git-ignored) and fill in your values.
// With the Bluetooth link nothing here needs changing, and the file can be left uncopied.
#pragma once

// How the clip reaches the tablet.
//   1 = Bluetooth LE: the tablet finds the clip and connects (see BLUETOOTH.md).
//   0 = Wi-Fi: the clip connects to the tablet's WebSocket server, using the settings below.
#define LINK_BLUETOOTH 1

// ---- Wi-Fi link only
// Wi-Fi the clip and the tablet/laptop share. 2.4 GHz only.
#define WIFI_SSID     "your-wifi-name"
#define WIFI_PASSWORD "your-wifi-password"

// Where the tablet gateway (or sim/tablet.py --no-sim --lan) is listening.
#define GATEWAY_HOST "192.168.1.50"
#define GATEWAY_PORT 8765

// ---- both links
// Audio compression. 32 = Opus at 32 kbit/s: 4,400 bytes per second with headers, which fits a
// Bluetooth link to iOS and tested the same as raw audio for transcripts.
// 0 = raw audio: 32,000 bytes per second, Wi-Fi only (it does not fit a Bluetooth packet).
#define AUDIO_OPUS_KBPS 32

// Software gain on the microphone. Leave unset for the board default (1); raise it (2, 4, 8)
// if the audio the tablet receives is too quiet.
// #define MIC_MAGNIFICATION 4

// "Find clip" beep on a board with no speaker (the Feather): wire a piezo buzzer between a free
// pin and GND and name the pin here. The Atom uses its built-in speaker and ignores this.
// #define BUZZER_PIN 5

// ---- M5Stack Atom VoiceS3R pins. The Feather build ignores these and uses its own
// (src/build_config.h).
#define BUTTON_PIN 41      // USER_BUT, active low
#define LED_PIN 2          // Grove port, yellow wire (G2): data line of an external WS2812 ring
#define LED_COUNT 12       // pixels on the ring; harmless if no ring is attached
#define LED_BRIGHTNESS 40  // 0-255
