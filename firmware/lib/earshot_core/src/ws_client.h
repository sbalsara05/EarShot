// Minimal WebSocket client (RFC 6455) over an abstract byte transport.
// The same code runs on the ESP32 (WiFiClient) and in the laptop simulator (POSIX socket).
#pragma once
#include <stddef.h>
#include <stdint.h>
#include <string>
#include <vector>

namespace earshot {

// A connected TCP byte stream. Implemented per platform.
class Transport {
 public:
  virtual ~Transport() {}
  virtual bool connect(const char* host, uint16_t port) = 0;
  virtual bool connected() = 0;
  // Returns bytes written; 0 means the connection failed.
  virtual size_t write(const uint8_t* data, size_t len) = 0;
  // Non-blocking. Returns bytes read, 0 if nothing is waiting, -1 if the peer closed.
  virtual int read(uint8_t* buf, size_t len) = 0;
  virtual void close() = 0;
};

class WsClient {
 public:
  enum class State : uint8_t { Closed, Handshaking, Open };

  WsClient(Transport& transport, uint32_t random_seed);

  // Connects TCP and sends the HTTP upgrade request. The link is usable once state() is Open,
  // which happens inside poll() when the server's 101 response arrives.
  bool open(const char* host, uint16_t port, const char* path);
  void close();

  State state() const { return state_; }
  bool isOpen() const { return state_ == State::Open; }

  // Reads whatever is waiting. Returns true when a complete text message was placed in `out`;
  // call again until it returns false. Pings are answered here.
  bool poll(std::string& out);

  bool sendText(const std::string& text);
  // Sends one binary message made of two parts (header + body) without an extra copy by the caller.
  bool sendBinary(const uint8_t* head, size_t head_len, const uint8_t* body, size_t body_len);

 private:
  bool sendFrame(uint8_t opcode, const uint8_t* a, size_t a_len, const uint8_t* b, size_t b_len);
  bool writeAll(const uint8_t* data, size_t len);
  bool parseFrame(std::string& out);
  uint32_t nextRandom();

  Transport& t_;
  State state_;
  uint32_t rng_;
  std::vector<uint8_t> rx_;
  std::vector<uint8_t> tx_;
  std::string fragment_;
  bool in_fragment_;
};

}  // namespace earshot
