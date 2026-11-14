// The clip's connection to the tablet, whatever carries it. Two messages kinds go over it:
// text (JSON events and commands) and binary (audio frames). See protocol.h for their contents.
//
// Implementations: WsLink (Wi-Fi + WebSocket, in this library) and the Bluetooth LE link in the
// device firmware (src/ble_link.h).
#pragma once
#include <stddef.h>
#include <stdint.h>
#include <string>

namespace earshot {

class Link {
 public:
  virtual ~Link() {}
  // Called once per main-loop pass: connect, reconnect, time out.
  virtual void service(uint32_t now_ms) = 0;
  // True while messages can be sent. After the far end reconnects, this must read false for at
  // least one pass so the clip knows to introduce itself again.
  virtual bool isOpen() const = 0;
  // True while the link is closed because the tablet vanished (out of range, lost power)
  // rather than disconnecting on purpose. False before the first connection and after a
  // deliberate disconnect. The clip's light tells the two apart.
  virtual bool lostUnexpectedly() const = 0;
  // Returns true when a text message from the tablet was placed in `out`; call until false.
  virtual bool poll(std::string& out) = 0;
  virtual bool sendText(const std::string& text) = 0;
  // Sends one binary message made of two parts (header + body).
  virtual bool sendBinary(const uint8_t* head, size_t head_len, const uint8_t* body, size_t body_len) = 0;
};

}  // namespace earshot
