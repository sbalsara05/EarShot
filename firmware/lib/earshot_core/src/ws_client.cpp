#include "ws_client.h"

#include <stdio.h>
#include <string.h>

namespace earshot {

namespace {
const size_t kMaxRxBuffer = 8192;   // control messages from the tablet are tiny
const size_t kMaxMessage = 4096;

std::string base64(const uint8_t* data, size_t len) {
  static const char* tbl = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
  std::string out;
  for (size_t i = 0; i < len; i += 3) {
    uint32_t v = (uint32_t)data[i] << 16;
    if (i + 1 < len) v |= (uint32_t)data[i + 1] << 8;
    if (i + 2 < len) v |= data[i + 2];
    out += tbl[(v >> 18) & 63];
    out += tbl[(v >> 12) & 63];
    out += (i + 1 < len) ? tbl[(v >> 6) & 63] : '=';
    out += (i + 2 < len) ? tbl[v & 63] : '=';
  }
  return out;
}
}  // namespace

WsClient::WsClient(Transport& transport, uint32_t random_seed)
    : t_(transport),
      state_(State::Closed),
      rng_(random_seed ? random_seed : 0x9E3779B9u),
      in_fragment_(false), peer_closed_(false) {
  tx_.reserve(1024);
}

uint32_t WsClient::nextRandom() {  // xorshift32; masking keys need no cryptographic strength
  rng_ ^= rng_ << 13;
  rng_ ^= rng_ >> 17;
  rng_ ^= rng_ << 5;
  return rng_;
}

bool WsClient::open(const char* host, uint16_t port, const char* path) {
  close();
  peer_closed_ = false;
  if (!t_.connect(host, port)) return false;

  uint8_t key[16];
  for (int i = 0; i < 16; i += 4) {
    uint32_t r = nextRandom();
    memcpy(key + i, &r, 4);
  }
  char port_str[8];
  snprintf(port_str, sizeof port_str, "%u", (unsigned)port);

  std::string req;
  req += "GET ";
  req += path;
  req += " HTTP/1.1\r\nHost: ";
  req += host;
  req += ":";
  req += port_str;
  req += "\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: ";
  req += base64(key, sizeof key);
  req += "\r\nSec-WebSocket-Version: 13\r\n\r\n";

  rx_.clear();
  fragment_.clear();
  in_fragment_ = false;
  state_ = State::Handshaking;
  if (!writeAll((const uint8_t*)req.data(), req.size())) return false;
  return true;
}

void WsClient::close() {
  if (state_ != State::Closed || t_.connected()) t_.close();
  state_ = State::Closed;
  rx_.clear();
  fragment_.clear();
  in_fragment_ = false;
}

bool WsClient::writeAll(const uint8_t* data, size_t len) {
  size_t off = 0;
  while (off < len) {
    size_t n = t_.write(data + off, len - off);
    if (n == 0) {
      close();
      return false;
    }
    off += n;
  }
  return true;
}

bool WsClient::sendFrame(uint8_t opcode, const uint8_t* a, size_t a_len, const uint8_t* b,
                         size_t b_len) {
  if (state_ != State::Open) return false;
  size_t len = a_len + b_len;
  tx_.clear();
  tx_.push_back((uint8_t)(0x80 | opcode));  // FIN + opcode
  if (len < 126) {
    tx_.push_back((uint8_t)(0x80 | len));   // MASK bit: clients must mask
  } else if (len < 65536) {
    tx_.push_back(0x80 | 126);
    tx_.push_back((uint8_t)(len >> 8));
    tx_.push_back((uint8_t)(len & 0xFF));
  } else {
    tx_.push_back(0x80 | 127);
    for (int i = 7; i >= 0; --i) tx_.push_back((uint8_t)(((uint64_t)len >> (8 * i)) & 0xFF));
  }
  uint32_t r = nextRandom();
  uint8_t mask[4];
  memcpy(mask, &r, 4);
  tx_.insert(tx_.end(), mask, mask + 4);
  size_t k = 0;
  for (size_t i = 0; i < a_len; ++i, ++k) tx_.push_back((uint8_t)(a[i] ^ mask[k & 3]));
  for (size_t i = 0; i < b_len; ++i, ++k) tx_.push_back((uint8_t)(b[i] ^ mask[k & 3]));
  return writeAll(tx_.data(), tx_.size());
}

bool WsClient::sendText(const std::string& text) {
  return sendFrame(0x1, (const uint8_t*)text.data(), text.size(), NULL, 0);
}

bool WsClient::sendBinary(const uint8_t* head, size_t head_len, const uint8_t* body,
                          size_t body_len) {
  return sendFrame(0x2, head, head_len, body, body_len);
}

bool WsClient::poll(std::string& out) {
  if (state_ == State::Closed) return false;

  uint8_t buf[256];
  for (int i = 0; i < 8; ++i) {  // bounded work per call
    int n = t_.read(buf, sizeof buf);
    if (n < 0) {
      close();
      return false;
    }
    if (n == 0) break;
    rx_.insert(rx_.end(), buf, buf + n);
    if (rx_.size() > kMaxRxBuffer) {
      close();
      return false;
    }
  }

  if (state_ == State::Handshaking) {
    static const char kEnd[] = "\r\n\r\n";
    size_t end = std::string::npos;
    for (size_t i = 0; i + 4 <= rx_.size(); ++i) {
      if (memcmp(&rx_[i], kEnd, 4) == 0) {
        end = i + 4;
        break;
      }
    }
    if (end == std::string::npos) return false;
    static const char kOk[] = "HTTP/1.1 101";
    if (end < sizeof(kOk) - 1 || memcmp(&rx_[0], kOk, sizeof(kOk) - 1) != 0) {
      close();
      return false;
    }
    rx_.erase(rx_.begin(), rx_.begin() + end);
    state_ = State::Open;
  }

  return parseFrame(out);
}

bool WsClient::parseFrame(std::string& out) {
  while (state_ == State::Open) {
    if (rx_.size() < 2) return false;
    uint8_t b0 = rx_[0], b1 = rx_[1];
    bool fin = (b0 & 0x80) != 0;
    uint8_t opcode = b0 & 0x0F;
    bool masked = (b1 & 0x80) != 0;
    uint64_t len = b1 & 0x7F;
    size_t hdr = 2;
    if (len == 126) {
      if (rx_.size() < 4) return false;
      len = ((uint64_t)rx_[2] << 8) | rx_[3];
      hdr = 4;
    } else if (len == 127) {
      if (rx_.size() < 10) return false;
      len = 0;
      for (int i = 0; i < 8; ++i) len = (len << 8) | rx_[2 + i];
      hdr = 10;
    }
    if (len > kMaxMessage) {
      close();
      return false;
    }
    size_t mask_len = masked ? 4 : 0;
    size_t total = hdr + mask_len + (size_t)len;
    if (rx_.size() < total) return false;

    std::string payload((const char*)&rx_[hdr + mask_len], (size_t)len);
    if (masked) {
      for (size_t i = 0; i < payload.size(); ++i) payload[i] ^= rx_[hdr + (i & 3)];
    }
    rx_.erase(rx_.begin(), rx_.begin() + total);

    switch (opcode) {
      case 0x1:  // text
        if (fin) {
          out.swap(payload);
          return true;
        }
        fragment_ = payload;
        in_fragment_ = true;
        break;
      case 0x0:  // continuation
        if (!in_fragment_) break;
        fragment_ += payload;
        if (fragment_.size() > kMaxMessage) {
          close();
          return false;
        }
        if (fin) {
          in_fragment_ = false;
          out.swap(fragment_);
          fragment_.clear();
          return true;
        }
        break;
      case 0x8:  // close
        sendFrame(0x8, (const uint8_t*)payload.data(), payload.size() >= 2 ? 2 : 0, NULL, 0);
        peer_closed_ = true;  // the server said goodbye on purpose
        close();
        return false;
      case 0x9:  // ping -> pong
        if (!sendFrame(0xA, (const uint8_t*)payload.data(), payload.size(), NULL, 0)) return false;
        break;
      default:  // pong, binary: nothing to do
        break;
    }
  }
  return false;
}

}  // namespace earshot
