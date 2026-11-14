#include "ws_link.h"

namespace earshot {

WsLink::WsLink(Hal& hal, Transport& transport, uint32_t random_seed, const char* host,
               uint16_t port, const char* path, uint32_t reconnect_ms,
               uint32_t handshake_timeout_ms)
    : hal_(hal),
      ws_(transport, random_seed),
      host_(host),
      port_(port),
      path_(path),
      reconnect_ms_(reconnect_ms),
      handshake_timeout_ms_(handshake_timeout_ms),
      tried_connect_(false),
      last_attempt_(0),
      was_open_(false),
      lost_(false) {}

void WsLink::service(uint32_t now) {
  // Notice an open connection ending, and whether the server closed it on purpose.
  bool open = ws_.isOpen();
  if (was_open_ && !open) lost_ = !ws_.peerClosed();
  if (open) lost_ = false;
  was_open_ = open;

  if (!hal_.networkUp()) {
    if (ws_.state() != WsClient::State::Closed) ws_.close();
    return;
  }
  switch (ws_.state()) {
    case WsClient::State::Closed:
      if (!tried_connect_ || (uint32_t)(now - last_attempt_) >= reconnect_ms_) {
        tried_connect_ = true;
        last_attempt_ = now;
        ws_.open(host_, port_, path_);
      }
      break;
    case WsClient::State::Handshaking:
      if ((uint32_t)(now - last_attempt_) >= handshake_timeout_ms_) ws_.close();
      break;
    case WsClient::State::Open:
      break;
  }
}

}  // namespace earshot
