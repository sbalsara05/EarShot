// Host-side tests for the portable firmware core. Build and run with `make test`.
#include <stdio.h>
#include <string.h>
#include <string>
#include <vector>

#include "button.h"
#include "clip_app.h"
#include "clip_fsm.h"
#include "protocol.h"
#include "ws_client.h"

using namespace earshot;

static int g_checks = 0, g_failed = 0;
#define CHECK(cond)                                                        \
  do {                                                                     \
    ++g_checks;                                                            \
    if (!(cond)) {                                                         \
      ++g_failed;                                                          \
      printf("  FAIL %s:%d  %s\n", __FILE__, __LINE__, #cond);             \
    }                                                                      \
  } while (0)
#define CHECK_EQ(a, b)                                                     \
  do {                                                                     \
    ++g_checks;                                                            \
    long long va = (long long)(a), vb = (long long)(b);                    \
    if (va != vb) {                                                        \
      ++g_failed;                                                          \
      printf("  FAIL %s:%d  %s == %s  (%lld vs %lld)\n", __FILE__, __LINE__, #a, #b, va, vb); \
    }                                                                      \
  } while (0)

// ---------------------------------------------------------------- button

// Feeds a level for `ms` milliseconds in 5 ms steps and collects events.
struct ButtonRig {
  Button b;
  uint32_t now;
  std::vector<ButtonEvent> events;
  ButtonRig() : now(1000) {}
  void hold(bool level, uint32_t ms) {
    for (uint32_t t = 0; t < ms; t += 5) {
      ButtonEvent e = b.update(level, now);
      if (e != ButtonEvent::None) events.push_back(e);
      now += 5;
    }
  }
};

static void test_button() {
  printf("button\n");
  {  // short press is reported only after the double-tap window closes
    ButtonRig r;
    r.hold(true, 100);
    r.hold(false, 200);
    CHECK_EQ(r.events.size(), 0);
    r.hold(false, 300);
    CHECK_EQ(r.events.size(), 1);
    CHECK(r.events.size() == 1 && r.events[0] == ButtonEvent::ShortPress);
  }
  {  // long press fires while held, release adds nothing
    ButtonRig r;
    r.hold(true, 1400);
    CHECK_EQ(r.events.size(), 0);
    r.hold(true, 300);
    CHECK_EQ(r.events.size(), 1);
    r.hold(true, 2000);
    r.hold(false, 1000);
    CHECK_EQ(r.events.size(), 1);
    CHECK(r.events[0] == ButtonEvent::LongPress);
  }
  {  // double tap
    ButtonRig r;
    r.hold(true, 80);
    r.hold(false, 120);
    r.hold(true, 80);
    r.hold(false, 800);
    CHECK_EQ(r.events.size(), 1);
    CHECK(r.events.size() == 1 && r.events[0] == ButtonEvent::DoubleTap);
  }
  {  // two slow presses are two short presses
    ButtonRig r;
    r.hold(true, 80);
    r.hold(false, 600);
    r.hold(true, 80);
    r.hold(false, 600);
    CHECK_EQ(r.events.size(), 2);
    CHECK(r.events.size() == 2 && r.events[0] == ButtonEvent::ShortPress &&
          r.events[1] == ButtonEvent::ShortPress);
  }
  {  // contact bounce shorter than the debounce time is ignored
    ButtonRig r;
    for (int i = 0; i < 20; ++i) {
      r.hold(true, 10);
      r.hold(false, 10);
    }
    r.hold(false, 800);
    CHECK_EQ(r.events.size(), 0);
  }
  {  // tap followed immediately by a hold is a long press only
    ButtonRig r;
    r.hold(true, 80);
    r.hold(false, 100);
    r.hold(true, 1700);
    r.hold(false, 800);
    CHECK_EQ(r.events.size(), 1);
    CHECK(r.events.size() == 1 && r.events[0] == ButtonEvent::LongPress);
  }
  {  // works across the 32-bit millisecond rollover (~49 days)
    ButtonRig r;
    r.now = 0xFFFFFFFFu - 60;
    r.hold(true, 100);
    r.hold(false, 600);
    CHECK_EQ(r.events.size(), 1);
  }
}

// ---------------------------------------------------------------- state machine

static void test_fsm() {
  printf("state machine\n");
  Transition t;

  // Not listening: a press starts; nothing else does anything.
  t = step(ClipState::NotListening, Input::ShortPress);
  CHECK(t.next == ClipState::Listening && t.effect == Effect::Started);
  t = step(ClipState::NotListening, Input::CmdStart);
  CHECK(t.next == ClipState::Listening && t.effect == Effect::Started);
  t = step(ClipState::NotListening, Input::LongPress);
  CHECK(t.next == ClipState::NotListening && t.effect == Effect::None);
  t = step(ClipState::NotListening, Input::DoubleTap);  // a double tap never starts a capture
  CHECK(t.next == ClipState::NotListening && t.effect == Effect::None);
  t = step(ClipState::NotListening, Input::CmdMarker);
  CHECK(t.next == ClipState::NotListening && t.effect == Effect::None);
  t = step(ClipState::NotListening, Input::CmdStop);
  CHECK(t.next == ClipState::NotListening && t.effect == Effect::None);

  // Listening: hold stops; double tap marks; a stray press does nothing.
  t = step(ClipState::Listening, Input::ShortPress);
  CHECK(t.next == ClipState::Listening && t.effect == Effect::None);
  t = step(ClipState::Listening, Input::CmdStart);
  CHECK(t.next == ClipState::Listening && t.effect == Effect::None);
  t = step(ClipState::Listening, Input::LongPress);
  CHECK(t.next == ClipState::NotListening && t.effect == Effect::Stopped);
  t = step(ClipState::Listening, Input::CmdStop);
  CHECK(t.next == ClipState::NotListening && t.effect == Effect::Stopped);
  t = step(ClipState::Listening, Input::DoubleTap);
  CHECK(t.next == ClipState::Listening && t.effect == Effect::Marker);
  t = step(ClipState::Listening, Input::CmdMarker);
  CHECK(t.next == ClipState::Listening && t.effect == Effect::Marker);

  Input in;
  CHECK(parseCommand("{\"cmd\":\"start\"}", in) && in == Input::CmdStart);
  CHECK(parseCommand("{ \"cmd\" : \"stop\" }", in) && in == Input::CmdStop);
  CHECK(parseCommand("{\"cmd\":\"marker\"}", in) && in == Input::CmdMarker);
  CHECK(!parseCommand("{\"cmd\":\"format_disk\"}", in));
  CHECK(!parseCommand("hello", in));
}

// ---------------------------------------------------------------- fake server side

struct WsFrame {
  uint8_t opcode;
  std::string payload;
};

// Stands in for the TCP link and the tablet's WebSocket server.
class FakeTransport : public Transport {
 public:
  bool up;              // can a TCP connection be made?
  bool is_connected;
  bool auto_handshake;  // reply to the upgrade request automatically
  int connects;
  std::string to_client;    // bytes the "server" has sent
  std::string from_client;  // bytes the clip has written
  size_t read_chunk;        // deliver at most this many bytes per read()

  FakeTransport()
      : up(true), is_connected(false), auto_handshake(true), connects(0), read_chunk(4096) {}

  bool connect(const char*, uint16_t) override {
    if (!up) return false;
    is_connected = true;
    ++connects;
    to_client.clear();
    from_client.clear();
    if (auto_handshake)
      to_client = "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\n"
                  "Connection: Upgrade\r\nSec-WebSocket-Accept: x\r\n\r\n";
    return true;
  }
  bool connected() override { return is_connected; }
  size_t write(const uint8_t* d, size_t n) override {
    if (!is_connected) return 0;
    from_client.append((const char*)d, n);
    return n;
  }
  int read(uint8_t* b, size_t n) override {
    if (!is_connected) return -1;
    if (to_client.empty()) return 0;
    size_t take = to_client.size() < n ? to_client.size() : n;
    if (take > read_chunk) take = read_chunk;
    memcpy(b, to_client.data(), take);
    to_client.erase(0, take);
    return (int)take;
  }
  void close() override { is_connected = false; }

  void drop() { is_connected = false; }  // peer vanished

  void serverSendText(const std::string& text) { serverSend(0x1, text); }
  void serverSend(uint8_t opcode, const std::string& payload) {
    to_client += (char)(0x80 | opcode);
    if (payload.size() < 126) {
      to_client += (char)payload.size();
    } else {
      to_client += (char)126;
      to_client += (char)(payload.size() >> 8);
      to_client += (char)(payload.size() & 0xFF);
    }
    to_client += payload;
  }

  // Decodes everything the clip wrote on this connection: the HTTP request, then frames.
  // Returns false if any frame breaks the protocol (for example, is not masked).
  bool decode(std::string& http_request, std::vector<WsFrame>& frames) const {
    size_t end = from_client.find("\r\n\r\n");
    if (end == std::string::npos) return false;
    http_request = from_client.substr(0, end + 4);
    size_t p = end + 4;
    const std::string& s = from_client;
    while (p < s.size()) {
      if (s.size() - p < 2) return false;
      uint8_t b0 = (uint8_t)s[p], b1 = (uint8_t)s[p + 1];
      if (!(b0 & 0x80)) return false;  // we never fragment
      if (!(b1 & 0x80)) return false;  // client frames must be masked
      size_t len = b1 & 0x7F;
      p += 2;
      if (len == 126) {
        len = ((size_t)(uint8_t)s[p] << 8) | (uint8_t)s[p + 1];
        p += 2;
      } else if (len == 127) {
        return false;
      }
      if (s.size() - p < 4 + len) return false;
      uint8_t mask[4];
      memcpy(mask, s.data() + p, 4);
      p += 4;
      WsFrame f;
      f.opcode = b0 & 0x0F;
      f.payload.resize(len);
      for (size_t i = 0; i < len; ++i) f.payload[i] = (char)(s[p + i] ^ mask[i & 3]);
      p += len;
      frames.push_back(f);
    }
    return true;
  }
};

static void test_ws_client() {
  printf("websocket client\n");
  FakeTransport tr;
  tr.auto_handshake = false;
  WsClient ws(tr, 1234);
  std::string msg;

  CHECK(ws.open("gw.local", 8765, "/clip"));
  CHECK(ws.state() == WsClient::State::Handshaking);
  CHECK(!ws.sendText("too early"));  // nothing may be sent before the upgrade completes
  CHECK(!ws.poll(msg));

  // Server response arrives one byte at a time.
  tr.read_chunk = 1;
  tr.to_client = "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\n\r\n";
  for (int i = 0; i < 200 && !ws.isOpen(); ++i) ws.poll(msg);
  CHECK(ws.isOpen());

  // Text from the server, split across reads, plus a ping in front.
  tr.serverSend(0x9, "hi");
  tr.serverSendText("{\"cmd\":\"marker\"}");
  bool got = false;
  for (int i = 0; i < 200 && !got; ++i) got = ws.poll(msg);
  CHECK(got);
  CHECK(msg == "{\"cmd\":\"marker\"}");
  tr.read_chunk = 4096;

  CHECK(ws.sendText("hello"));
  uint8_t head[8] = {1, 2, 3, 4, 5, 6, 7, 8};
  std::string body(640, '\x55');
  CHECK(ws.sendBinary(head, 8, (const uint8_t*)body.data(), body.size()));

  std::string http;
  std::vector<WsFrame> frames;
  CHECK(tr.decode(http, frames));
  CHECK(http.find("GET /clip HTTP/1.1\r\n") == 0);
  CHECK(http.find("Host: gw.local:8765\r\n") != std::string::npos);
  CHECK(http.find("Upgrade: websocket\r\n") != std::string::npos);
  CHECK(http.find("Sec-WebSocket-Version: 13\r\n") != std::string::npos);
  CHECK(http.find("Sec-WebSocket-Key: ") != std::string::npos);
  CHECK_EQ(frames.size(), 3);
  if (frames.size() == 3) {
    CHECK(frames[0].opcode == 0xA && frames[0].payload == "hi");  // pong
    CHECK(frames[1].opcode == 0x1 && frames[1].payload == "hello");
    CHECK(frames[2].opcode == 0x2 && frames[2].payload.size() == 648);
    CHECK(frames[2].payload.substr(0, 8) == std::string((const char*)head, 8));
    CHECK(frames[2].payload.substr(8) == body);
  }

  // A non-101 response closes the connection.
  FakeTransport bad;
  bad.auto_handshake = false;
  WsClient ws2(bad, 5);
  ws2.open("gw", 1, "/clip");
  bad.to_client = "HTTP/1.1 404 Not Found\r\n\r\n";
  ws2.poll(msg);
  CHECK(ws2.state() == WsClient::State::Closed);

  // Peer disappearing is noticed.
  tr.drop();
  ws.poll(msg);
  CHECK(ws.state() == WsClient::State::Closed);
}

// ---------------------------------------------------------------- whole app

class FakeHal : public Hal {
 public:
  uint32_t now;
  bool button;
  bool net;
  bool mic_on;
  int mic_starts, mic_stops;
  LedColor led;
  std::vector<LedColor> led_history;
  FakeHal() : now(5000), button(false), net(true), mic_on(false), mic_starts(0), mic_stops(0), led(LedColor::Off) {}

  uint32_t millis() override { return now; }
  void sleepMs(uint32_t ms) override { now += ms; }
  bool buttonPressed() override { return button; }
  void setLed(LedColor c) override {
    led = c;
    led_history.push_back(c);
  }
  bool micStart() override {
    mic_on = true;
    ++mic_starts;
    return true;
  }
  void micStop() override {
    mic_on = false;
    ++mic_stops;
  }
  size_t micRead(int16_t* out, size_t samples) override {
    if (!mic_on) return 0;
    for (size_t i = 0; i < samples; ++i) out[i] = (int16_t)(i * 7);
    now += 20;  // a real mic read blocks for one frame
    return samples;
  }
  bool networkUp() override { return net; }
  void log(const char*) override {}
};

struct AppRig {
  FakeHal hal;
  FakeTransport tr;
  ClipApp app;
  AppRig() : app(hal, tr, ClipConfig(), 99) {}

  void run(uint32_t ms) {
    uint32_t end = hal.now + ms;
    while ((int32_t)(end - hal.now) > 0) {
      uint32_t before = hal.now;
      app.tick();
      if (hal.now == before) hal.now += 1;  // guarantee progress
    }
  }
  void press(uint32_t ms) {
    hal.button = true;
    run(ms);
    hal.button = false;
  }
  void shortPress() { press(100); run(500); }
  void longPress() { press(1700); run(100); }
  void doubleTap() { press(80); run(100); press(80); run(500); }
  void command(const char* cmd) {
    tr.serverSendText(std::string("{\"cmd\":\"") + cmd + "\"}");
    run(100);
  }

  std::vector<WsFrame> frames() {
    std::string http;
    std::vector<WsFrame> f;
    CHECK(tr.decode(http, f));
    return f;
  }
  int audioFrames() {
    int n = 0;
    std::vector<WsFrame> f = frames();
    for (size_t i = 0; i < f.size(); ++i) n += f[i].opcode == 0x2;
    return n;
  }
  int textCount(const char* needle) {
    int n = 0;
    std::vector<WsFrame> f = frames();
    for (size_t i = 0; i < f.size(); ++i)
      n += f[i].opcode == 0x1 && f[i].payload.find(needle) != std::string::npos;
    return n;
  }
};

static uint32_t seqOf(const WsFrame& f) {
  const uint8_t* p = (const uint8_t*)f.payload.data();
  return p[0] | (p[1] << 8) | (p[2] << 16) | ((uint32_t)p[3] << 24);
}

static void test_app_press_to_start() {
  printf("app: press to start, mark, hold to stop\n");
  AppRig r;
  r.app.begin();
  CHECK(r.app.state() == ClipState::NotListening);
  CHECK(!r.hal.mic_on);

  r.run(1000);                                      // powered, connected, nobody has pressed
  CHECK(r.app.linkOpen());
  CHECK(r.hal.led == LedColor::Off);                // ring dark = not listening
  CHECK_EQ(r.hal.mic_starts, 0);                    // the microphone has never been on
  CHECK_EQ(r.app.stats().frames_captured, 0);
  CHECK_EQ(r.audioFrames(), 0);
  CHECK_EQ(r.textCount("\"type\":\"hello\""), 1);
  CHECK_EQ(r.textCount("\"state\":\"not_listening\",\"listening\":false"), 1);

  r.doubleTap();                                    // a double tap does not start a capture
  r.longPress();                                    // nor does a hold
  CHECK(r.app.state() == ClipState::NotListening);
  CHECK_EQ(r.hal.mic_starts, 0);
  CHECK_EQ(r.audioFrames(), 0);

  r.shortPress();                                   // one press: consent logged, capture starts
  CHECK(r.app.state() == ClipState::Listening);
  CHECK(r.hal.led == LedColor::Green);
  CHECK(r.hal.mic_on);
  CHECK_EQ(r.hal.mic_starts, 1);
  CHECK_EQ(r.textCount("\"type\":\"consent\",\"event\":\"granted\",\"source\":\"button\""), 1);
  CHECK_EQ(r.textCount("\"state\":\"listening\",\"listening\":true"), 1);
  r.run(500);
  int sent = r.audioFrames();
  CHECK(sent > 20);
  CHECK_EQ(sent, (int)r.app.stats().frames_sent);

  // Order on the wire: the consent event, then (and only then) audio. Frames count from 0.
  std::vector<WsFrame> f = r.frames();
  size_t granted_at = 0, first_audio_at = 0;
  uint32_t expect_seq = 0;
  bool layout_ok = true;
  for (size_t i = 0; i < f.size(); ++i) {
    if (!granted_at && f[i].payload.find("\"event\":\"granted\"") != std::string::npos) granted_at = i;
    if (f[i].opcode != 0x2) continue;
    if (!first_audio_at) first_audio_at = i;
    if (f[i].payload.size() != 648 || seqOf(f[i]) != expect_seq++) layout_ok = false;
  }
  CHECK(granted_at > 0 && first_audio_at > granted_at);
  CHECK(layout_ok);

  r.shortPress();                                   // a stray press while listening does nothing
  CHECK(r.app.state() == ClipState::Listening);
  CHECK_EQ(r.textCount("\"event\":\"granted\""), 1);

  r.doubleTap();                                    // double tap: timestamp marker
  CHECK_EQ(r.app.stats().markers, 1);
  CHECK_EQ(r.textCount("\"type\":\"marker\",\"id\":1,\"source\":\"button\""), 1);
  CHECK(r.app.state() == ClipState::Listening);
  bool flashed = false;
  for (size_t i = 0; i < r.hal.led_history.size(); ++i) flashed |= r.hal.led_history[i] == LedColor::White;
  CHECK(flashed);

  r.longPress();                                    // hold: stop
  CHECK(r.app.state() == ClipState::NotListening);
  CHECK(!r.hal.mic_on);
  CHECK(r.hal.led == LedColor::Off);
  CHECK_EQ(r.textCount("\"type\":\"consent\",\"event\":\"stopped\",\"source\":\"button\""), 1);
  int after_stop = r.audioFrames();
  r.run(1000);
  CHECK_EQ(r.audioFrames(), after_stop);            // nothing more is sent
  CHECK_EQ(r.textCount("\"state\":\"not_listening\",\"listening\":false"), 2);

  r.doubleTap();                                    // no markers when not listening
  CHECK_EQ(r.app.stats().markers, 1);

  // The next patient: each capture starts its frame counter at 0 again.
  r.shortPress();
  CHECK(r.app.state() == ClipState::Listening);
  CHECK_EQ(r.app.stats().captures, 2);
  r.run(300);
  f = r.frames();
  size_t last_granted = 0;
  for (size_t i = 0; i < f.size(); ++i)
    if (f[i].opcode == 0x1 && f[i].payload.find("\"event\":\"granted\"") != std::string::npos) last_granted = i;
  size_t next_audio = last_granted + 1;
  while (next_audio < f.size() && f[next_audio].opcode != 0x2) ++next_audio;
  CHECK(next_audio < f.size());
  if (next_audio < f.size()) CHECK_EQ(seqOf(f[next_audio]), 0);
  CHECK_EQ(r.textCount("\"event\":\"granted\""), 2);
}

static void test_app_tablet_commands() {
  printf("app: tablet commands\n");
  AppRig r;
  r.app.begin();
  r.run(200);

  r.command("marker");                              // ignored when not listening
  r.command("stop");
  CHECK(r.app.state() == ClipState::NotListening);
  CHECK_EQ(r.app.stats().markers, 0);
  CHECK_EQ(r.audioFrames(), 0);

  r.command("start");                               // the tablet starts the recording
  CHECK(r.app.state() == ClipState::Listening);
  CHECK(r.hal.mic_on);
  r.run(300);
  CHECK(r.audioFrames() > 5);
  CHECK_EQ(r.textCount("\"event\":\"granted\",\"source\":\"tablet\""), 1);

  r.command("start");                               // already listening: no second consent event
  CHECK_EQ(r.textCount("\"event\":\"granted\""), 1);

  r.command("marker");
  CHECK_EQ(r.textCount("\"type\":\"marker\",\"id\":1,\"source\":\"tablet\""), 1);

  r.command("stop");
  CHECK(r.app.state() == ClipState::NotListening);
  CHECK(!r.hal.mic_on);
  CHECK_EQ(r.textCount("\"event\":\"stopped\",\"source\":\"tablet\""), 1);
  int n = r.audioFrames();
  r.run(500);
  CHECK_EQ(r.audioFrames(), n);

  r.command("ask");                                 // old commands are no longer understood
  r.command("consent_grant");
  CHECK(r.app.state() == ClipState::NotListening);
}

static void test_app_link_loss() {
  printf("app: link loss\n");
  AppRig r;
  r.app.begin();
  r.run(200);
  r.shortPress();
  CHECK(r.app.state() == ClipState::Listening);
  r.run(200);
  CHECK(r.app.stats().frames_sent > 0);

  r.tr.up = false;  // tablet goes away
  r.tr.drop();
  r.run(1000);
  CHECK(!r.app.linkOpen());
  CHECK(r.app.state() == ClipState::Listening);       // the clip keeps its state
  uint32_t sent_before = r.app.stats().frames_sent;
  CHECK(r.app.stats().frames_dropped > 20);           // audio is dropped, not buffered

  r.doubleTap();                                      // marker while offline
  CHECK_EQ(r.app.stats().markers, 1);

  int connects_before = r.tr.connects;
  r.tr.up = true;  // tablet returns; clip reconnects by itself
  r.run(3000);
  CHECK(r.app.linkOpen());
  CHECK_EQ(r.tr.connects, connects_before + 1);
  CHECK(r.app.stats().frames_sent > sent_before);
  // New connection starts with hello, then the queued marker, then the current state.
  std::vector<WsFrame> f = r.frames();
  CHECK(f.size() > 3);
  if (f.size() > 3) {
    CHECK(f[0].payload.find("\"type\":\"hello\"") != std::string::npos);
    CHECK(f[1].payload.find("\"type\":\"marker\"") != std::string::npos);
    CHECK(f[2].payload.find("\"state\":\"listening\",\"listening\":true") != std::string::npos);
    // The first audio frame after the gap carries a seq that shows frames were lost.
    CHECK(f[3].opcode == 0x2 && seqOf(f[3]) > sent_before);
  }

  // Wi-Fi itself dropping also closes the link cleanly.
  r.hal.net = false;
  r.run(200);
  CHECK(!r.app.linkOpen());
  r.hal.net = true;
  r.run(3000);
  CHECK(r.app.linkOpen());

  // A capture started and stopped while offline is still reported, in order, on reconnect.
  AppRig q;
  q.tr.up = false;
  q.app.begin();
  q.run(200);
  q.shortPress();
  q.longPress();
  q.tr.up = true;
  q.run(3000);
  CHECK(q.app.linkOpen());
  std::vector<WsFrame> g = q.frames();
  size_t granted = 0, stopped = 0;
  for (size_t i = 0; i < g.size(); ++i) {
    if (g[i].payload.find("\"event\":\"granted\"") != std::string::npos) granted = i;
    if (g[i].payload.find("\"event\":\"stopped\"") != std::string::npos) stopped = i;
  }
  CHECK(granted > 0 && stopped > granted);
  CHECK_EQ(q.audioFrames(), 0);                       // that offline audio is gone, not sent late
}

static void test_app_external_button() {
  printf("app: platform-detected button events\n");
  FakeHal hal;
  FakeTransport tr;
  ClipConfig cfg;
  cfg.poll_button = false;  // as on the ESP32, where a fast task detects gestures
  ClipApp app(hal, tr, cfg, 7);
  app.begin();
  hal.button = true;  // raw level must be ignored in this mode
  for (int i = 0; i < 200; ++i) app.tick();
  CHECK(app.state() == ClipState::NotListening);
  hal.button = false;
  app.onButtonEvent(ButtonEvent::ShortPress);
  CHECK(app.state() == ClipState::Listening);
  app.onButtonEvent(ButtonEvent::DoubleTap);
  CHECK_EQ(app.stats().markers, 1);
  app.onButtonEvent(ButtonEvent::LongPress);
  CHECK(app.state() == ClipState::NotListening);
}

static void test_app_standalone() {
  printf("app: standalone (no tablet)\n");
  FakeHal hal;
  FakeTransport tr;
  ClipConfig cfg;
  cfg.gateway_enabled = false;
  ClipApp app(hal, tr, cfg, 7);
  app.begin();
  for (int i = 0; i < 300; ++i) app.tick();
  CHECK_EQ(tr.connects, 0);                           // never tries to reach a tablet
  CHECK(!app.linkOpen());
  app.onButtonEvent(ButtonEvent::ShortPress);
  for (int i = 0; i < 100; ++i) app.tick();
  CHECK(app.state() == ClipState::Listening);
  bool blinked = false;
  for (size_t i = 1; i < hal.led_history.size(); ++i) blinked |= hal.led_history[i] == LedColor::Off;
  CHECK(!blinked);                                    // green stays steady, no "not connected" blink
  CHECK(hal.led == LedColor::Green);
  CHECK(app.stats().frames_captured > 50);
  CHECK_EQ(app.stats().frames_sent, 0);
  CHECK_EQ(app.stats().frames_dropped, app.stats().frames_captured);
  app.onButtonEvent(ButtonEvent::LongPress);
  CHECK(app.state() == ClipState::NotListening);
  CHECK_EQ(tr.connects, 0);
}

// A stand-in codec: every frame becomes 80 bytes, like Opus at 32 kbit/s.
class FakeEncoder : public AudioEncoder {
 public:
  int resets, frames;
  bool fail;
  FakeEncoder() : resets(0), frames(0), fail(false) {}
  const char* codecName() const override { return "opus"; }
  uint32_t bitrate() const override { return 32000; }
  void reset() override { ++resets; }
  size_t encode(const int16_t* pcm, size_t samples, uint8_t* out, size_t out_max) override {
    if (fail || samples != kFrameSamples || out_max < 80) return 0;
    ++frames;
    for (size_t i = 0; i < 80; ++i) out[i] = (uint8_t)(pcm[i] & 0xFF);
    return 80;
  }
};

static void test_app_encoder() {
  printf("app: compressed audio\n");
  FakeHal hal;
  FakeTransport tr;
  FakeEncoder enc;
  ClipConfig cfg;
  cfg.encoder = &enc;
  ClipApp app(hal, tr, cfg, 7);
  app.begin();
  for (int i = 0; i < 50; ++i) app.tick();
  CHECK(app.linkOpen());
  CHECK_EQ(enc.frames, 0);                             // nothing is encoded while not listening

  app.onButtonEvent(ButtonEvent::ShortPress);
  for (int i = 0; i < 50; ++i) app.tick();
  CHECK_EQ(enc.resets, 1);                             // codec state is reset at the start of a capture
  CHECK(enc.frames >= 45);

  std::string http;
  std::vector<WsFrame> f;
  CHECK(tr.decode(http, f));
  int audio = 0;
  bool sizes_ok = true, hello_ok = false;
  for (size_t i = 0; i < f.size(); ++i) {
    if (f[i].opcode == 0x1 && f[i].payload.find("\"type\":\"hello\"") != std::string::npos)
      hello_ok = f[i].payload.find("\"audio\":{\"codec\":\"opus\",\"rate\":16000,\"channels\":1,"
                                   "\"frame_ms\":20,\"bitrate\":32000}") != std::string::npos;
    if (f[i].opcode != 0x2) continue;
    ++audio;
    if (f[i].payload.size() != 8 + 80) sizes_ok = false;  // header + one encoded frame
  }
  CHECK(hello_ok);                                     // the tablet is told how to decode
  CHECK(audio >= 45);
  CHECK(sizes_ok);
  CHECK_EQ(app.stats().audio_bytes_sent, 80u * app.stats().frames_sent);

  enc.fail = true;                                     // a frame that fails to encode is dropped
  uint32_t sent = app.stats().frames_sent, dropped = app.stats().frames_dropped;
  for (int i = 0; i < 10; ++i) app.tick();
  CHECK_EQ(app.stats().frames_sent, sent);
  CHECK(app.stats().frames_dropped > dropped);
  enc.fail = false;

  app.onButtonEvent(ButtonEvent::LongPress);
  app.onButtonEvent(ButtonEvent::ShortPress);          // next capture
  CHECK_EQ(enc.resets, 2);

  // With no encoder configured, audio is raw PCM and the hello says so.
  FakeHal hal2;
  FakeTransport tr2;
  ClipApp plain(hal2, tr2, ClipConfig(), 7);
  plain.begin();
  for (int i = 0; i < 20; ++i) plain.tick();
  std::vector<WsFrame> g;
  CHECK(tr2.decode(http, g));
  CHECK(!g.empty() && g[0].payload.find("\"codec\":\"pcm\"") != std::string::npos &&
        g[0].payload.find("\"bitrate\":256000") != std::string::npos);
}

int main() {
  test_button();
  test_fsm();
  test_ws_client();
  test_app_press_to_start();
  test_app_tablet_commands();
  test_app_link_loss();
  test_app_external_button();
  test_app_standalone();
  test_app_encoder();
  printf("\n%d checks, %d failed\n", g_checks, g_failed);
  return g_failed ? 1 : 0;
}
