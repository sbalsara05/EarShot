// Copy this file to include/config.h (which is git-ignored) and fill in your values.
#pragma once

// Wi-Fi the clip and the tablet/laptop share. 2.4 GHz only.
#define WIFI_SSID     "your-wifi-name"
#define WIFI_PASSWORD "your-wifi-password"

// Where the tablet gateway (or sim/tablet.py --no-sim --lan) is listening.
#define GATEWAY_HOST "192.168.1.50"
#define GATEWAY_PORT 8765

// Audio compression. 32 = Opus at 32 kbit/s: 4,400 bytes per second with headers, which fits a
// Bluetooth link to iOS and tested the same as raw audio for transcripts.
// 0 = raw audio: 32,000 bytes per second, fine over Wi-Fi only.
#define AUDIO_OPUS_KBPS 32

// Software gain on the microphone. Leave unset for the board default (1); raise it (2, 4, 8)
// if the audio the tablet receives is too quiet.
// #define MIC_MAGNIFICATION 4

// ---- M5Stack Atom VoiceS3R pins (change these when porting to another board)
#define BUTTON_PIN 41      // USER_BUT, active low
#define LED_PIN 2          // Grove port, yellow wire (G2): data line of an external WS2812 ring
#define LED_COUNT 12       // pixels on the ring; harmless if no ring is attached
#define LED_BRIGHTNESS 40  // 0-255
