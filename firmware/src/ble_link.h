// The Bluetooth LE link to the tablet.
//
// The clip is the peripheral: it advertises, the tablet (the central) connects and subscribes.
// After that every message is one notification. Channel IDs and message contents are in
// lib/earshot_core/src/protocol.h; BLUETOOTH.md describes the same thing for the app side.
//
// Keeping the connection is shared work. This side's part: advertise from power-on, start
// advertising again the instant a connection drops, and introduce itself afresh on every new
// subscription. The tablet's part is to connect again whenever it sees the clip.
#pragma once
#include "build_config.h"
#if LINK_BLUETOOTH

#include <NimBLEDevice.h>
#include <atomic>
#include <string>

#include "link.h"

class BleLink : public earshot::Link,
                private NimBLEServerCallbacks,
                private NimBLECharacteristicCallbacks {
 public:
  BleLink();

  // Starts the Bluetooth stack and begins advertising under `name`.
  bool begin(const char* name);

  // ---- earshot::Link
  void service(uint32_t now_ms) override;
  bool isOpen() const override { return open_; }
  bool lostUnexpectedly() const override { return lost_ && !connected_; }
  bool poll(std::string& out) override;
  bool sendText(const std::string& text) override;
  bool sendBinary(const uint8_t* head, size_t head_len, const uint8_t* body, size_t body_len) override;

  // ---- for the status line
  bool connected() const { return connected_; }
  uint16_t packetBytes() const { return payload_; }          // most bytes one packet may carry
  float intervalMs() const { return interval_units_ * 1.25f; }  // how often the two sides talk
  uint32_t failedSends() const { return failed_sends_; }

 private:
  void onConnect(NimBLEServer* server, NimBLEConnInfo& info) override;
  void onDisconnect(NimBLEServer* server, NimBLEConnInfo& info, int reason) override;
  void onConnParamsUpdate(NimBLEConnInfo& info) override;
  void onWrite(NimBLECharacteristic* chr, NimBLEConnInfo& info) override;
  void onSubscribe(NimBLECharacteristic* chr, NimBLEConnInfo& info, uint16_t sub_value) override;

  NimBLEServer* server_;
  NimBLECharacteristic* audio_;
  NimBLECharacteristic* events_;
  NimBLECharacteristic* commands_;
  QueueHandle_t rx_;  // commands written by the tablet, handed from the Bluetooth task to loop()

  // Written on the Bluetooth task, read in loop().
  std::atomic<bool> connected_;
  std::atomic<bool> events_subscribed_;
  std::atomic<bool> audio_subscribed_;
  std::atomic<uint16_t> conn_handle_;
  std::atomic<uint16_t> interval_units_;  // 1.25 ms each
  std::atomic<uint32_t> session_;         // bumps on every new subscription and every disconnect
  std::atomic<bool> lost_;                // the last disconnect was not the tablet's own choice

  // Used in loop() only.
  bool open_;
  uint32_t seen_session_;
  uint16_t payload_;
  uint32_t subscribed_since_;
  bool warned_small_;
  uint32_t failed_sends_;
};

#endif  // LINK_BLUETOOTH
