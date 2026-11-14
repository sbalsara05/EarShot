// Host-side tests for the portable firmware core. Build and run with `make test`.
#include <stdio.h>
#include <string.h>
#include <deque>
#include <math.h>
#include <stdlib.h>
#include <string>
#include <vector>

#include "button.h"
#include "clip_app.h"
#include "clip_fsm.h"
#include "protocol.h"
#include "voice_clip.h"
#include "voice_clip_data.h"
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

  // Not listening: a double click starts; nothing else does anything.
  t = step(ClipState::NotListening, Input::DoubleTap);
  CHECK(t.next == ClipState::Listening && t.effect == Effect::Started);
  t = step(ClipState::NotListening, Input::CmdStart);
  CHECK(t.next == ClipState::Listening && t.effect == Effect::Started);
  t = step(ClipState::NotListening, Input::ShortPress);  // a single click never starts a capture
  CHECK(t.next == ClipState::NotListening && t.effect == Effect::None);
  t = step(ClipState::NotListening, Input::LongPress);
  CHECK(t.next == ClipState::NotListening && t.effect == Effect::None);
  t = step(ClipState::NotListening, Input::CmdMarker);
  CHECK(t.next == ClipState::NotListening && t.effect == Effect::None);
  t = step(ClipState::NotListening, Input::CmdStop);
  CHECK(t.next == ClipState::NotListening && t.effect == Effect::None);

  // Listening: a single click marks; a double click or a hold stops.
  t = step(ClipState::Listening, Input::ShortPress);
  CHECK(t.next == ClipState::Listening && t.effect == Effect::Marker);
  t = step(ClipState::Listening, Input::CmdMarker);
  CHECK(t.next == ClipState::Listening && t.effect == Effect::Marker);
  t = step(ClipState::Listening, Input::DoubleTap);
  CHECK(t.next == ClipState::NotListening && t.effect == Effect::Stopped);
  t = step(ClipState::Listening, Input::LongPress);
  CHECK(t.next == ClipState::NotListening && t.effect == Effect::Stopped);
  t = step(ClipState::Listening, Input::CmdStop);
  CHECK(t.next == ClipState::NotListening && t.effect == Effect::Stopped);
  t = step(ClipState::Listening, Input::CmdStart);       // already listening: nothing to do
  CHECK(t.next == ClipState::Listening && t.effect == Effect::None);

  CHECK(strcmp(stateName(ClipState::NotListening), "not_listening") == 0);
  CHECK(strcmp(stateName(ClipState::Listening), "listening") == 0);
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
  // "find" beep
  bool beeping = false;
  int beeps = 0;              // times a beep started
  int beeps_with_mic_on = 0;  // must stay 0: a beep would land in the recording
  int beep_dones = 0;
  void beep(bool on) override {
    if (on && !beeping) {
      ++beeps;
      if (mic_on) ++beeps_with_mic_on;
    }
    beeping = on;
  }
  void beepDone() override { ++beep_dones; }
  bool networkUp() override { return net; }
  void log(const char*) override {}
};

struct AppRig {
  FakeHal hal;
  FakeTransport tr;
  ClipApp app;
  // The app's part in a double click: the clip only reports it ("toggle"); the app decides and
  // answers. Here the stand-in app ends a recording that is running and starts one otherwise.
  bool app_answers;
  uint32_t toggles_seen;
  AppRig() : app(hal, tr, ClipConfig(), 99), app_answers(true), toggles_seen(0) {}

  void run(uint32_t ms) {
    uint32_t end = hal.now + ms;
    while ((int32_t)(end - hal.now) > 0) {
      uint32_t before = hal.now;
      app.tick();
      if (app.stats().toggles != toggles_seen) {
        toggles_seen = app.stats().toggles;
        if (app_answers)
          tr.serverSendText(app.state() == ClipState::Listening ? "{\"cmd\":\"stop\"}" : "{\"cmd\":\"start\"}");
      }
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

static void test_app_gestures() {
  printf("app: double click to start, click to mark, double click or hold to stop\n");
  AppRig r;
  r.app.begin();
  CHECK(r.app.state() == ClipState::NotListening);
  CHECK(!r.hal.mic_on);

  r.run(1000);                                      // powered, connected, nobody has clicked
  CHECK(r.app.linkOpen());
  CHECK(r.hal.led == LedColor::Green);              // green = tablet connected, not listening
  CHECK_EQ(r.hal.mic_starts, 0);                    // the microphone has never been on
  CHECK_EQ(r.app.stats().frames_captured, 0);
  CHECK_EQ(r.audioFrames(), 0);
  CHECK_EQ(r.textCount("\"type\":\"hello\""), 1);
  CHECK_EQ(r.textCount("\"state\":\"not_listening\",\"listening\":false"), 1);

  r.shortPress();                                   // a single click does not start a capture
  r.longPress();                                    // nor does a hold
  CHECK(r.app.state() == ClipState::NotListening);
  CHECK_EQ(r.hal.mic_starts, 0);
  CHECK_EQ(r.audioFrames(), 0);

  // A double click is only reported: the clip sends "toggle" and waits for the tablet.
  r.app_answers = false;
  r.doubleTap();
  CHECK_EQ(r.textCount("\"type\":\"toggle\",\"target\":\"recording\",\"source\":\"button\""), 1);
  CHECK(r.app.state() == ClipState::NotListening);  // nothing happens until the tablet answers
  CHECK_EQ(r.hal.mic_starts, 0);
  CHECK_EQ(r.textCount("\"type\":\"consent\""), 0);
  r.app_answers = true;

  r.command("start");                               // the tablet decides: consent logged, capture starts
  CHECK(r.app.state() == ClipState::Listening);
  CHECK(r.hal.led == LedColor::Red);
  CHECK(r.hal.mic_on);
  CHECK_EQ(r.hal.mic_starts, 1);
  CHECK_EQ(r.textCount("\"type\":\"consent\",\"event\":\"granted\",\"source\":\"tablet\""), 1);
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

  // A single click while listening drops a mark and nothing else: the capture carries on.
  // The mark is stamped with the moment the button went down, not the moment the click was
  // recognised (about 0.4 s later, once the double-click window has passed).
  int frames_before = r.audioFrames();
  uint32_t pressed_at = r.hal.now;
  r.shortPress();
  CHECK_EQ(r.app.stats().markers, 1);
  CHECK_EQ(r.textCount("\"type\":\"marker\",\"id\":1,\"source\":\"button\""), 1);
  CHECK(r.app.state() == ClipState::Listening);
  CHECK(r.hal.mic_on);
  CHECK_EQ(r.textCount("\"event\":\"granted\""), 1);
  CHECK_EQ(r.textCount("\"event\":\"stopped\""), 0);
  bool flashed = false;
  for (size_t i = 0; i < r.hal.led_history.size(); ++i) flashed |= r.hal.led_history[i] == LedColor::White;
  CHECK(flashed);
  {
    f = r.frames();
    long t_ms = -1, seq = -1;
    for (size_t i = 0; i < f.size(); ++i) {
      size_t at = f[i].payload.find("\"type\":\"marker\"");
      if (f[i].opcode != 0x1 || at == std::string::npos) continue;
      t_ms = atol(f[i].payload.c_str() + f[i].payload.find("\"t_ms\":") + 7);
      seq = atol(f[i].payload.c_str() + f[i].payload.find("\"audio_seq\":") + 12);
    }
    CHECK(t_ms >= (long)pressed_at && t_ms <= (long)pressed_at + 80);   // not ~450 ms later
    CHECK(seq >= frames_before - 1 && seq <= frames_before + 4);        // the frame at the click
  }

  // A double click while listening sends exactly the same message as one while not
  // listening; the stand-in app answers "stop" this time.
  r.doubleTap();
  CHECK_EQ(r.textCount("\"type\":\"toggle\",\"target\":\"recording\",\"source\":\"button\""), 2);
  {
    f = r.frames();
    std::vector<std::string> toggles;
    for (size_t i = 0; i < f.size(); ++i)
      if (f[i].opcode == 0x1 && f[i].payload.find("\"target\":\"recording\"") != std::string::npos)
        toggles.push_back(f[i].payload.substr(0, f[i].payload.find("\"t_ms\"")));
    CHECK(toggles.size() == 2 && toggles[0] == toggles[1]);   // identical apart from the time
  }
  CHECK(r.app.state() == ClipState::NotListening);
  CHECK(!r.hal.mic_on);
  CHECK(r.hal.led == LedColor::Green);
  CHECK_EQ(r.textCount("\"type\":\"consent\",\"event\":\"stopped\",\"source\":\"tablet\""), 1);
  int after_stop = r.audioFrames();
  r.run(1000);
  CHECK_EQ(r.audioFrames(), after_stop);            // nothing more is sent
  CHECK_EQ(r.textCount("\"state\":\"not_listening\",\"listening\":false"), 2);

  r.shortPress();                                   // no marks when not listening
  CHECK_EQ(r.app.stats().markers, 1);

  // The next patient: each capture starts its frame counter at 0 again.
  r.doubleTap();
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

  r.longPress();                                    // a hold still stops a capture
  CHECK(r.app.state() == ClipState::NotListening);
  CHECK(!r.hal.mic_on);
  CHECK_EQ(r.textCount("\"type\":\"consent\",\"event\":\"stopped\",\"source\":\"button\""), 1);
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
  r.doubleTap();
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

  r.shortPress();                                      // marker while offline
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

  // A double click with no tablet does nothing, now or later: no capture starts, and no
  // stale toggle is delivered when the tablet comes back.
  AppRig q;
  q.tr.up = false;
  q.app.begin();
  q.run(200);
  q.doubleTap();
  CHECK(q.app.state() == ClipState::NotListening);
  CHECK_EQ(q.hal.mic_starts, 0);
  q.tr.up = true;
  q.run(3000);
  CHECK(q.app.linkOpen());
  CHECK(q.app.state() == ClipState::NotListening);
  CHECK_EQ(q.textCount("\"target\":\"recording\""), 0);
  CHECK_EQ(q.textCount("\"type\":\"consent\""), 0);
  CHECK_EQ(q.audioFrames(), 0);

  // A capture stopped by a hold while offline is reported when the tablet returns.
  q.doubleTap();                                       // online now: the app answers "start"
  CHECK(q.app.state() == ClipState::Listening);
  q.tr.up = false;
  q.tr.drop();
  q.run(500);
  q.longPress();
  CHECK(q.app.state() == ClipState::NotListening);
  CHECK(!q.hal.mic_on);
  q.tr.up = true;
  q.run(3000);
  CHECK(q.app.linkOpen());
  std::vector<WsFrame> g = q.frames();
  CHECK(g.size() >= 3);
  if (g.size() >= 3) {
    CHECK(g[0].payload.find("\"type\":\"hello\"") != std::string::npos);
    CHECK(g[1].payload.find("\"event\":\"stopped\",\"source\":\"button\"") != std::string::npos);
    CHECK(g[2].payload.find("\"state\":\"not_listening\"") != std::string::npos);
  }
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
  app.onButtonEvent(ButtonEvent::DoubleTap);          // reported to the tablet, not acted on
  CHECK_EQ(app.stats().toggles, 1);
  CHECK(app.state() == ClipState::NotListening);
  tr.serverSendText("{\"cmd\":\"start\"}");          // the tablet decides: start
  for (int i = 0; i < 5; ++i) app.tick();
  CHECK(app.state() == ClipState::Listening);
  app.onButtonEvent(ButtonEvent::ShortPress);
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
  app.onButtonEvent(ButtonEvent::DoubleTap);
  for (int i = 0; i < 100; ++i) app.tick();
  CHECK(app.state() == ClipState::Listening);
  bool blinked = false;
  for (size_t i = 1; i < hal.led_history.size(); ++i) blinked |= hal.led_history[i] == LedColor::Off;
  CHECK(!blinked);                                    // green stays steady, no "not connected" blink
  CHECK(hal.led == LedColor::Red);
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

  tr.serverSendText("{\"cmd\":\"start\"}");
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
  tr.serverSendText("{\"cmd\":\"start\"}");          // next capture
  for (int i = 0; i < 5; ++i) app.tick();
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

// ---------------------------------------------------------------- packet link (Bluetooth)

// Stands in for the Bluetooth link: one message per packet, a size limit, a tablet that can
// go away and come back, and sends that can fail for a moment.
class FakeLink : public Link {
 public:
  bool up;                 // a tablet is connected and subscribed
  bool lost;               // the tablet vanished (out of range) rather than disconnecting
  bool app_answers;        // answer the clip's "toggle" the way the app would
  bool clip_listening;     // what the clip last said about itself
  bool reopened;           // the tablet reconnected since the last pass
  int fail_text;           // this many text sends fail before one succeeds
  size_t max_bytes;
  std::vector<std::string> texts;
  std::vector<std::string> audio;
  std::deque<std::string> from_tablet;
  FakeLink() : up(false), lost(false), app_answers(true), clip_listening(false), reopened(false), fail_text(0), max_bytes(kBleMaxMessage), open_(false) {}

  void connect() { up = true; lost = false; reopened = true; }
  void disconnect() { up = false; lost = false; }   // the tablet hangs up on purpose
  void vanish() { up = false; lost = true; }        // the tablet goes out of range
  bool lostUnexpectedly() const override { return lost && !open_; }
  void service(uint32_t) override {
    if (reopened) {  // read as closed for one pass, as link.h requires
      reopened = false;
      open_ = false;
      return;
    }
    open_ = up;
  }
  bool isOpen() const override { return open_; }
  bool poll(std::string& out) override {
    if (from_tablet.empty()) return false;
    out = from_tablet.front();
    from_tablet.pop_front();
    return true;
  }
  bool sendText(const std::string& t) override {
    if (!open_ || t.size() > max_bytes) return false;
    if (fail_text > 0) {
      --fail_text;
      return false;
    }
    texts.push_back(t);
    // Stand in for the app: follow the clip's state, and answer a toggle with start or stop.
    if (t.find("\"listening\":true") != std::string::npos) clip_listening = true;
    if (t.find("\"listening\":false") != std::string::npos) clip_listening = false;
    if (app_answers && t.find("\"target\":\"recording\"") != std::string::npos)
      from_tablet.push_back(clip_listening ? "{\"cmd\":\"stop\"}" : "{\"cmd\":\"start\"}");
    return true;
  }
  bool sendBinary(const uint8_t* h, size_t hl, const uint8_t* b, size_t bl) override {
    if (!open_ || hl + bl > max_bytes) return false;
    audio.push_back(std::string((const char*)h, hl) + std::string((const char*)b, bl));
    return true;
  }
  int count(const char* needle) const {
    int n = 0;
    for (size_t i = 0; i < texts.size(); ++i) n += texts[i].find(needle) != std::string::npos;
    return n;
  }

 private:
  bool open_;
};

static void test_app_packet_link() {
  printf("app: packet link (Bluetooth)\n");
  FakeHal hal;
  FakeLink link;
  FakeEncoder enc;
  ClipConfig cfg;
  cfg.encoder = &enc;
  cfg.device_id = "ESP-CLIP-A3F2";
  ClipApp app(hal, link, cfg);
  app.begin();

  for (int i = 0; i < 10; ++i) app.tick();
  CHECK(!app.linkOpen());                              // nobody connected: nothing sent
  CHECK_EQ(link.texts.size(), 0);

  link.connect();
  for (int i = 0; i < 5; ++i) app.tick();
  CHECK(app.linkOpen());
  CHECK_EQ(link.texts.size(), 2);                      // introduces itself: hello, then state
  CHECK(link.texts.size() == 2 && link.texts[0].find("\"type\":\"hello\"") != std::string::npos &&
        link.texts[0].find("\"device\":\"ESP-CLIP-A3F2\"") != std::string::npos &&
        link.texts[1].find("\"state\":\"not_listening\"") != std::string::npos);

  // A command from the tablet starts a capture; every audio frame is one packet that fits.
  link.from_tablet.push_back("{\"cmd\":\"start\"}");
  for (int i = 0; i < 50; ++i) app.tick();
  CHECK(app.state() == ClipState::Listening);
  CHECK_EQ(link.count("\"event\":\"granted\",\"source\":\"tablet\""), 1);
  CHECK(link.audio.size() >= 45);
  bool sizes_ok = true;
  for (size_t i = 0; i < link.audio.size(); ++i) sizes_ok = sizes_ok && link.audio[i].size() == 8 + 80;
  CHECK(sizes_ok);
  CHECK_EQ(app.stats().frames_dropped, 0);

  // A send that fails for a moment is tried again, and events still arrive in order.
  link.fail_text = 3;
  size_t before = link.texts.size();
  app.onButtonEvent(ButtonEvent::ShortPress);
  app.onButtonEvent(ButtonEvent::ShortPress);
  for (int i = 0; i < 10; ++i) app.tick();
  CHECK_EQ(link.texts.size(), before + 2);
  CHECK(link.texts.size() == before + 2 &&
        link.texts[before].find("\"type\":\"marker\",\"id\":1") != std::string::npos &&
        link.texts[before + 1].find("\"type\":\"marker\",\"id\":2") != std::string::npos);

  // The tablet goes away mid-capture: the clip keeps listening, audio is dropped (not stored),
  // and what happened meanwhile is delivered when it comes back.
  link.up = false;
  for (int i = 0; i < 5; ++i) app.tick();
  CHECK(!app.linkOpen());
  size_t audio_before = link.audio.size();
  app.onButtonEvent(ButtonEvent::ShortPress);           // marker 3 while disconnected
  for (int i = 0; i < 20; ++i) app.tick();
  CHECK(app.state() == ClipState::Listening);
  CHECK_EQ(link.audio.size(), audio_before);
  CHECK(app.stats().frames_dropped >= 15);
  CHECK_EQ(link.count("\"id\":3"), 0);

  int hellos = link.count("\"type\":\"hello\"");
  link.connect();
  for (int i = 0; i < 10; ++i) app.tick();
  CHECK(app.linkOpen());
  CHECK_EQ(link.count("\"type\":\"hello\""), hellos + 1);   // says hello again
  CHECK_EQ(link.count("\"id\":3"), 1);                         // the missed marker arrives
  CHECK(link.texts.back().find("\"state\":\"listening\"") != std::string::npos);
  CHECK(link.audio.size() > audio_before);                      // and audio flows again

  // A tablet that reconnects between two passes (never seen as "down") still gets a hello.
  hellos = link.count("\"type\":\"hello\"");
  link.connect();
  for (int i = 0; i < 5; ++i) app.tick();
  CHECK_EQ(link.count("\"type\":\"hello\""), hellos + 1);

  // Raw audio is too big for a packet: it is dropped rather than sent broken.
  FakeHal hal2;
  FakeLink link2;
  ClipApp raw(hal2, link2, ClipConfig());
  raw.begin();
  link2.connect();
  for (int i = 0; i < 5; ++i) raw.tick();
  raw.onButtonEvent(ButtonEvent::DoubleTap);           // the stand-in app answers "start"
  for (int i = 0; i < 25; ++i) raw.tick();
  CHECK_EQ(link2.audio.size(), 0);
  CHECK(raw.stats().frames_dropped >= 15);
}

static void test_message_sizes() {
  printf("protocol: every message fits one Bluetooth packet\n");
  const uint32_t big = 0xFFFFFFFFu;  // longest possible numbers
  CHECK(helloJson("ESP-CLIP-A3F2", "opus", 32000).size() <= kBleMaxMessage);
  CHECK(stateJson(ClipState::NotListening, big).size() <= kBleMaxMessage);
  CHECK(stateJson(ClipState::Listening, big).size() <= kBleMaxMessage);
  CHECK(consentJson("granted", "button", big).size() <= kBleMaxMessage);
  CHECK(consentJson("stopped", "tablet", big).size() <= kBleMaxMessage);
  CHECK(markerJson(big, "button", big, big).size() <= kBleMaxMessage);
  CHECK(toggleJson("recording", "button", big).size() <= kBleMaxMessage);
  CHECK(toggleJson("call", "button", big).size() <= kBleMaxMessage);
  CHECK(toggleJson("recording", "button", 123456) ==
        "{\"type\":\"toggle\",\"target\":\"recording\",\"source\":\"button\",\"t_ms\":123456}");
  CHECK(toggleJson("call", "button", 91500) ==
        "{\"type\":\"toggle\",\"target\":\"call\",\"source\":\"button\",\"t_ms\":91500}");
  CHECK(kAudioHeaderBytes + 80 <= kBleMaxMessage);     // one Opus frame at 32 kbit/s
  CHECK(kBleMaxMessage <= 182);                        // what iOS allows per packet
}

// ---------------------------------------------------------------- stored voice recording

static void test_voice_clip() {
  printf("voice recording\n");
  VoiceClip clip(kVoiceClipAdpcm, kVoiceClipBytes);
  size_t total = clip.totalSamples();
  CHECK_EQ(total, kVoiceClipBytes * 2);
  CHECK_EQ(total % kFrameSamples, 0);                  // loops on a frame boundary
  CHECK(total >= 5 * kSampleRate && total <= 30 * kSampleRate);
  CHECK(strlen(kVoiceClipText) > 20);

  std::vector<int16_t> a(total), b(total);
  clip.read(a.data(), total);
  CHECK_EQ(clip.position(), total);

  // It is speech-like: a quiet start, plenty of signal overall, and no clipping.
  double lead = 0, all = 0;
  int peak = 0;
  for (size_t i = 0; i < total; ++i) {
    double v = a[i];
    all += v * v;
    if (i < 1600) lead += v * v;
    if (abs(a[i]) > peak) peak = abs(a[i]);
  }
  double rms_all = sqrt(all / total), rms_lead = sqrt(lead / 1600);
  CHECK(rms_all > 1000);
  CHECK(rms_lead < 100);
  CHECK(peak > 12000 && peak < 32000);

  clip.read(b.data(), total);                          // second time round is identical
  CHECK(memcmp(a.data(), b.data(), total * sizeof(int16_t)) == 0);

  int16_t frame[kFrameSamples];                        // reading in frames gives the same audio
  clip.rewind();
  bool same = true;
  for (size_t f = 0; f < 100; ++f) {
    clip.read(frame, kFrameSamples);
    same = same && memcmp(frame, &a[f * kFrameSamples], sizeof frame) == 0;
  }
  CHECK(same);

  VoiceClip empty(NULL, 0);                            // no data: silence, no crash
  empty.read(frame, kFrameSamples);
  CHECK(frame[0] == 0 && frame[kFrameSamples - 1] == 0);
}

// ---------------------------------------------------------------- find clip

static int ledChanges(const FakeHal& hal, size_t from, LedColor c) {
  int n = 0;
  for (size_t i = from; i < hal.led_history.size(); ++i) n += hal.led_history[i] == c;
  return n;
}

static void test_find() {
  printf("find clip: blink and beep\n");
  Transition t;
  t = step(ClipState::NotListening, Input::CmdFind);     // never changes the state
  CHECK(t.next == ClipState::NotListening && t.effect == Effect::Find);
  t = step(ClipState::Listening, Input::CmdFind);
  CHECK(t.next == ClipState::Listening && t.effect == Effect::Find);
  Input in;
  CHECK(parseCommand("{\"cmd\":\"find\"}", in) && in == Input::CmdFind);

  {  // not listening: blinks white and beeps for 3.2 s, then goes dark and quiet
    AppRig r;
    r.app.begin();
    r.run(300);
    CHECK(r.app.linkOpen());
    size_t mark = r.hal.led_history.size();
    r.command("find");                                   // runs 100 ms
    CHECK(r.app.finding());
    CHECK(r.app.state() == ClipState::NotListening);
    CHECK_EQ(r.app.stats().finds, 1);
    r.run(1400);
    CHECK(r.app.finding());
    CHECK(r.hal.beeps >= 3);                             // one beep every 400 ms
    CHECK(ledChanges(r.hal, mark, LedColor::White) >= 5);   // 125 ms on, 125 ms off
    r.run(2000);                                         // 3.5 s since the command
    CHECK(!r.app.finding());
    CHECK(!r.hal.beeping);
    CHECK(r.hal.beeps >= 7 && r.hal.beeps <= 9);         // 3.2 s at one per 400 ms
    CHECK_EQ(r.hal.beep_dones, 1);                       // the speaker is released once, at the end
    CHECK(r.hal.led == LedColor::Green);
    CHECK_EQ(r.hal.mic_starts, 0);                       // find never turns the microphone on
    CHECK_EQ(r.audioFrames(), 0);
    CHECK_EQ(r.textCount("\"type\":\"consent\""), 0);

    r.command("find");                                   // asking again mid-find restarts the timer
    r.run(2000);
    r.command("find");
    r.run(2000);
    CHECK(r.app.finding());                              // 4.1 s after the first, 2.1 s after the second
    r.run(1500);
    CHECK(!r.app.finding());
  }
  {  // listening: blinks only. No beep, the capture carries on, and the light ends up green
    AppRig r;
    r.app.begin();
    r.run(300);
    r.doubleTap();
    CHECK(r.app.state() == ClipState::Listening);
    int frames_before = r.audioFrames();
    size_t mark = r.hal.led_history.size();
    r.command("find");
    r.run(1000);
    CHECK(r.app.finding());
    CHECK(r.app.state() == ClipState::Listening);
    CHECK(ledChanges(r.hal, mark, LedColor::White) >= 3);
    CHECK(ledChanges(r.hal, mark, LedColor::Red) >= 3);     // red shows between blinks
    CHECK(r.audioFrames() >= frames_before + 40);        // audio kept flowing
    r.run(2500);
    CHECK(!r.app.finding());
    CHECK_EQ(r.hal.beeps, 0);
    CHECK_EQ(r.hal.beeps_with_mic_on, 0);
    CHECK(r.hal.led == LedColor::Red);
    CHECK(r.hal.mic_on);
  }
  {  // a capture that starts during a find silences it before the microphone turns on
    AppRig r;
    r.app.begin();
    r.run(300);
    r.command("find");
    r.run(150);                                          // 250 ms in: between beeps
    r.command("find");                                   // restart, so a beep is sounding right now
    CHECK(r.hal.beeping);
    r.tr.serverSendText("{\"cmd\":\"start\"}");
    r.run(20);
    CHECK(r.app.state() == ClipState::Listening);
    CHECK(!r.hal.beeping);
    CHECK(r.hal.beep_dones >= 1);
    int beeps = r.hal.beeps;
    r.run(3500);
    CHECK_EQ(r.hal.beeps, beeps);                        // no more beeps once listening
    CHECK_EQ(r.hal.beeps_with_mic_on, 0);
    CHECK(r.hal.led == LedColor::Red);
  }
  {  // stopping a capture mid-find lets the beeps begin
    AppRig r;
    r.app.begin();
    r.run(300);
    r.doubleTap();
    r.command("find");
    r.app.onButtonEvent(ButtonEvent::LongPress);
    CHECK(r.app.state() == ClipState::NotListening);
    r.run(1500);
    CHECK(r.hal.beeps >= 2);
    CHECK_EQ(r.hal.beeps_with_mic_on, 0);
  }
}

// ---------------------------------------------------------------- hold: end the call

static void test_end_call() {
  printf("hold: mic off at once, then the tablet is told to end the call\n");
  {  // while recording: the capture stops here, then "end" follows, in that order
    AppRig r;
    r.app.begin();
    r.run(300);
    r.command("start");
    CHECK(r.app.state() == ClipState::Listening);
    r.longPress();
    CHECK(r.app.state() == ClipState::NotListening);
    CHECK(!r.hal.mic_on);
    CHECK_EQ(r.app.stats().call_toggles, 1);
    std::vector<WsFrame> f = r.frames();
    size_t stopped = 0, state = 0, end = 0;
    for (size_t i = 0; i < f.size(); ++i) {
      if (f[i].opcode != 0x1) continue;
      if (f[i].payload.find("\"event\":\"stopped\",\"source\":\"button\"") != std::string::npos) stopped = i;
      if (f[i].payload.find("\"state\":\"not_listening\"") != std::string::npos) state = i;
      if (f[i].payload.find("\"type\":\"toggle\",\"target\":\"call\",\"source\":\"button\"") != std::string::npos) end = i;
    }
    CHECK(stopped > 0 && state > stopped && end > state);
    int after = r.audioFrames();
    r.run(500);
    CHECK_EQ(r.audioFrames(), after);                    // no audio after the stop

    // While paused (connected, not recording): "end" alone. Nothing about consent, mic stays off.
    int consents = r.textCount("\"type\":\"consent\"");
    size_t mark = r.hal.led_history.size();
    r.longPress();
    CHECK_EQ(r.textCount("\"target\":\"call\""), 2);
    CHECK_EQ(r.textCount("\"type\":\"consent\""), consents);
    CHECK(r.app.state() == ClipState::NotListening);
    CHECK_EQ(r.hal.mic_starts, 1);
    CHECK(ledChanges(r.hal, mark, LedColor::White) >= 1);   // the clip shows the hold was taken
    CHECK(r.hal.led == LedColor::Green);
  }
  {  // after a call is ended, the next double click starts a fresh one
    AppRig r;
    r.app.begin();
    r.run(300);
    r.doubleTap();                                       // call 1: the stand-in app answers "start"
    CHECK(r.app.state() == ClipState::Listening);
    r.run(400);
    r.longPress();                                       // end call 1
    CHECK(r.app.state() == ClipState::NotListening);
    CHECK_EQ(r.app.stats().call_toggles, 1);
    int toggles = r.textCount("\"target\":\"recording\"");
    r.doubleTap();                                       // call 2
    CHECK_EQ(r.textCount("\"target\":\"recording\""), toggles + 1);
    CHECK(r.app.state() == ClipState::Listening);
    CHECK(r.hal.mic_on);
    CHECK_EQ(r.app.stats().captures, 2);
    r.run(300);
    std::vector<WsFrame> f = r.frames();                 // its audio counts from 0 again
    size_t last_granted = 0;
    for (size_t i = 0; i < f.size(); ++i)
      if (f[i].opcode == 0x1 && f[i].payload.find("\"event\":\"granted\"") != std::string::npos) last_granted = i;
    size_t next_audio = last_granted + 1;
    while (next_audio < f.size() && f[next_audio].opcode != 0x2) ++next_audio;
    CHECK(next_audio < f.size());
    if (next_audio < f.size()) CHECK_EQ(seqOf(f[next_audio]), 0);
  }
  {  // no tablet: the microphone still goes off, and no "end" turns up later
    AppRig r;
    r.app.begin();
    r.run(300);
    r.command("start");
    r.tr.up = false;
    r.tr.drop();
    r.run(500);
    r.longPress();
    CHECK(r.app.state() == ClipState::NotListening);
    CHECK(!r.hal.mic_on);
    CHECK_EQ(r.app.stats().call_toggles, 0);
    r.tr.up = true;
    r.run(3000);
    CHECK(r.app.linkOpen());
    CHECK_EQ(r.textCount("\"event\":\"stopped\",\"source\":\"button\""), 1);   // the stop is reported
    CHECK_EQ(r.textCount("\"target\":\"call\""), 0);                                 // the hold is not replayed
  }
  {  // a standalone clip has no call to end: a hold just stops the capture
    FakeHal hal;
    FakeLink link;
    ClipConfig alone;
    alone.gateway_enabled = false;
    ClipApp solo(hal, link, alone);
    solo.begin();
    solo.onButtonEvent(ButtonEvent::DoubleTap);
    CHECK(solo.state() == ClipState::Listening);
    solo.onButtonEvent(ButtonEvent::LongPress);
    CHECK(solo.state() == ClipState::NotListening);
    CHECK_EQ(solo.stats().call_toggles, 0);
    CHECK_EQ(link.texts.size(), 0);
  }
}

// ---------------------------------------------------------------- what the light shows

// Runs the app for `ms` of clip time and returns how often the light changed to each colour.
struct LedCount {
  int blue, green, red, white, off;
};
static LedCount runAndCount(ClipApp& app, FakeHal& hal, uint32_t ms) {
  size_t from = hal.led_history.size();
  uint32_t end = hal.now + ms;
  while ((int32_t)(end - hal.now) > 0) {
    uint32_t before = hal.now;
    app.tick();
    if (hal.now == before) hal.now += 1;
  }
  LedCount c = {0, 0, 0, 0, 0};
  for (size_t i = from; i < hal.led_history.size(); ++i) {
    c.blue += hal.led_history[i] == LedColor::Blue;
    c.green += hal.led_history[i] == LedColor::Green;
    c.red += hal.led_history[i] == LedColor::Red;
    c.white += hal.led_history[i] == LedColor::White;
    c.off += hal.led_history[i] == LedColor::Off;
  }
  return c;
}

static void test_light() {
  printf("light: blue ready, green connected, red listening, flashing red when the tablet is lost\n");
  FakeHal hal;
  FakeLink link;
  ClipApp app(hal, link, ClipConfig());
  app.begin();

  // Powered, no tablet: one blue blink every 2 seconds. Never green (nothing is connected)
  // and never red (the microphone is off).
  LedCount c = runAndCount(app, hal, 6000);
  CHECK(c.blue >= 2 && c.blue <= 4);
  CHECK(c.off >= 2);
  CHECK_EQ(c.green, 0);
  CHECK_EQ(c.red, 0);
  CHECK_EQ(hal.mic_starts, 0);

  // A tablet connects: solid green, and it stays green.
  link.connect();
  runAndCount(app, hal, 100);
  CHECK(app.linkOpen());
  CHECK(hal.led == LedColor::Green);
  c = runAndCount(app, hal, 6000);
  CHECK_EQ(c.blue + c.red + c.off + c.white, 0);       // no change at all
  CHECK(hal.led == LedColor::Green);

  // Listening and connected: solid red.
  app.onButtonEvent(ButtonEvent::DoubleTap);
  c = runAndCount(app, hal, 4000);
  CHECK_EQ(c.blue + c.green, 0);
  CHECK(hal.led == LedColor::Red);
  CHECK(hal.mic_on);

  // The tablet goes away mid-capture: red flashes. No blue, and no green.
  link.up = false;
  c = runAndCount(app, hal, 4000);
  CHECK_EQ(c.blue + c.green, 0);
  CHECK(c.red >= 2 && c.off >= 2);

  // The tablet comes back mid-capture: solid red again.
  link.connect();
  runAndCount(app, hal, 200);
  c = runAndCount(app, hal, 3000);
  CHECK_EQ(c.off + c.blue + c.green, 0);
  CHECK(hal.led == LedColor::Red);

  // The capture is stopped while connected: back to green.
  app.onButtonEvent(ButtonEvent::LongPress);
  runAndCount(app, hal, 200);
  CHECK(hal.led == LedColor::Green);
  CHECK(!hal.mic_on);

  // The tablet disconnects on purpose while idle (the app's Disconnect button): back to the
  // blue blink, ready for a tablet to connect. No red.
  link.disconnect();
  c = runAndCount(app, hal, 6000);
  CHECK(c.blue >= 2 && c.blue <= 4);
  CHECK_EQ(c.red + c.green, 0);

  // It connects again: green.
  link.connect();
  runAndCount(app, hal, 200);
  CHECK(hal.led == LedColor::Green);

  // The tablet goes out of range while idle: red flashes, though the microphone stays off.
  link.vanish();
  c = runAndCount(app, hal, 6000);
  CHECK(c.red >= 4 && c.off >= 4);
  CHECK_EQ(c.blue + c.green, 0);
  CHECK(!hal.mic_on);
  CHECK(app.state() == ClipState::NotListening);

  // It comes back into range: solid green again.
  link.connect();
  runAndCount(app, hal, 200);
  c = runAndCount(app, hal, 3000);
  CHECK_EQ(c.red + c.off + c.blue, 0);
  CHECK(hal.led == LedColor::Green);

  // A deliberate disconnect in the middle of a capture still flashes red: the microphone is
  // on and nothing is receiving the audio.
  app.onButtonEvent(ButtonEvent::DoubleTap);
  runAndCount(app, hal, 500);
  link.disconnect();
  c = runAndCount(app, hal, 4000);
  CHECK(c.red >= 2 && c.off >= 2);
  CHECK_EQ(c.blue + c.green, 0);
  CHECK(hal.mic_on);
  app.onButtonEvent(ButtonEvent::LongPress);            // stopped with no tablet: blue, not red
  c = runAndCount(app, hal, 6000);
  CHECK(c.blue >= 2);
  CHECK_EQ(c.red + c.green, 0);

  // "Find" while waiting is still the fast white blink.
  link.connect();
  runAndCount(app, hal, 100);
  link.from_tablet.push_back("{\"cmd\":\"find\"}");
  link.up = false;                                     // the tablet drops right after asking
  c = runAndCount(app, hal, 3000);
  CHECK(c.white >= 8);

  // A standalone clip (no tablet to wait for) stays dark.
  FakeHal hal2;
  FakeLink link2;
  ClipConfig alone;
  alone.gateway_enabled = false;
  ClipApp solo(hal2, link2, alone);
  solo.begin();
  c = runAndCount(solo, hal2, 6000);
  CHECK_EQ(c.blue + c.green, 0);
  CHECK(hal2.led == LedColor::Off);
  solo.onButtonEvent(ButtonEvent::DoubleTap);          // listening is red there too, and steady
  c = runAndCount(solo, hal2, 3000);
  CHECK(hal2.led == LedColor::Red);
  CHECK_EQ(c.off + c.blue + c.green, 0);
}

static void test_wifi_link_loss_kind() {
  printf("wi-fi link: a server goodbye is deliberate, a dead connection is a loss\n");
  {  // the connection simply dies: lost, so the light flashes red
    AppRig r;
    r.app.begin();
    r.run(300);
    CHECK(r.app.linkOpen());
    r.tr.up = false;                                     // and it cannot reconnect
    r.tr.drop();
    r.run(300);
    CHECK(!r.app.linkOpen());
    size_t mark = r.hal.led_history.size();
    r.run(4000);
    CHECK(ledChanges(r.hal, mark, LedColor::Red) >= 2);
    CHECK_EQ(ledChanges(r.hal, mark, LedColor::Blue), 0);
  }
  {  // the server sends a WebSocket Close: deliberate, so the light goes to the blue blink
    AppRig r;
    r.app.begin();
    r.run(300);
    CHECK(r.app.linkOpen());
    r.tr.up = false;
    r.tr.serverSend(0x8, "");
    r.run(300);
    CHECK(!r.app.linkOpen());
    size_t mark = r.hal.led_history.size();
    r.run(6000);
    CHECK(ledChanges(r.hal, mark, LedColor::Blue) >= 2);
    CHECK_EQ(ledChanges(r.hal, mark, LedColor::Red), 0);
  }
}

int main() {
  test_button();
  test_fsm();
  test_ws_client();
  test_app_gestures();
  test_app_tablet_commands();
  test_app_link_loss();
  test_app_external_button();
  test_app_standalone();
  test_app_encoder();
  test_app_packet_link();
  test_message_sizes();
  test_voice_clip();
  test_end_call();
  test_find();
  test_light();
  test_wifi_link_loss_kind();
  printf("\n%d checks, %d failed\n", g_checks, g_failed);
  return g_failed ? 1 : 0;
}
