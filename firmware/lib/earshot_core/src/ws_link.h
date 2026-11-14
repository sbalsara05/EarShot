// The Wi-Fi link: a WebSocket to the tablet gateway, reconnecting whenever it drops.
#pragma once
#include "hal.h"
#include "link.h"
#include "ws_client.h"

namespace earshot {

class WsLink : public Link {
 public:
  WsLink(Hal& hal, Transport& transport, uint32_t random_seed, const char* host, uint16_t port,
         const char* path, uint32_t reconnect_ms, uint32_t handshake_timeout_ms);

  void service(uint32_t now_ms) override;
  bool isOpen() const override { return ws_.isOpen(); }
  bool lostUnexpectedly() const override { return lost_ && !ws_.isOpen(); }
  bool poll(std::string& out) override { return ws_.poll(out); }
  bool sendText(const std::string& text) override { return ws_.sendText(text); }
  bool sendBinary(const uint8_t* head, size_t head_len, const uint8_t* body, size_t body_len) override {
    return ws_.sendBinary(head, head_len, body, body_len);
  }

 private:
  Hal& hal_;
  WsClient ws_;
  const char* host_;
  uint16_t port_;
  const char* path_;
  uint32_t reconnect_ms_;
  uint32_t handshake_timeout_ms_;
  bool tried_connect_;
  uint32_t last_attempt_;
  bool was_open_;
  bool lost_;  // the last open connection ended without the server's goodbye
};

}  // namespace earshot
