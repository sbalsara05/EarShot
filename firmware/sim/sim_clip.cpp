// Simulated clip: the real firmware core (lib/earshot_core) running on a laptop.
//
//   button  <- lines on stdin:  down | up | short | long | double | quit
//   LED     -> JSON lines on stdout: {"sim":"led","color":"amber"}
//   mic     <- a generated tone, a 16 kHz mono 16-bit WAV file (--wav), the voice recording
//              built into the firmware (--voice), or live audio fed on
//              stdin ("mic ext", then "a <base64 pcm>" lines; "mic tone" switches back).
//              The browser UI uses this to make the laptop microphone the clip's microphone.
//   network -> a real TCP socket to the mock tablet (default 127.0.0.1:8765)
//
// Normally started by sim/tablet.py; can also be run by hand and driven by typing.
#include <arpa/inet.h>
#include <errno.h>
#include <math.h>
#include <netdb.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <poll.h>
#include <signal.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <time.h>
#include <unistd.h>

#include <deque>
#include <string>
#include <vector>

#include "clip_app.h"
#include "voice_clip.h"
#include "voice_clip_data.h"
#include "opus_audio_encoder.h"

using namespace earshot;

static uint64_t monoMs() {
  struct timespec ts;
  clock_gettime(CLOCK_MONOTONIC, &ts);
  return (uint64_t)ts.tv_sec * 1000 + ts.tv_nsec / 1000000;
}

static void out(const char* fmt, ...) __attribute__((format(printf, 1, 2)));
static void out(const char* fmt, ...) {
  va_list ap;
  va_start(ap, fmt);
  vprintf(fmt, ap);
  va_end(ap);
  putchar('\n');
  fflush(stdout);
}

class PosixTransport : public Transport {
 public:
  PosixTransport() : fd_(-1) {}
  ~PosixTransport() override { close(); }

  bool connect(const char* host, uint16_t port) override {
    close();
    char port_str[8];
    snprintf(port_str, sizeof port_str, "%u", (unsigned)port);
    struct addrinfo hints, *res = NULL;
    memset(&hints, 0, sizeof hints);
    hints.ai_family = AF_UNSPEC;
    hints.ai_socktype = SOCK_STREAM;
    if (getaddrinfo(host, port_str, &hints, &res) != 0 || !res) return false;
    for (struct addrinfo* ai = res; ai; ai = ai->ai_next) {
      int fd = socket(ai->ai_family, ai->ai_socktype, ai->ai_protocol);
      if (fd < 0) continue;
      if (::connect(fd, ai->ai_addr, ai->ai_addrlen) == 0) {
        int one = 1;
        setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof one);
        fd_ = fd;
        break;
      }
      ::close(fd);
    }
    freeaddrinfo(res);
    return fd_ >= 0;
  }
  bool connected() override { return fd_ >= 0; }
  size_t write(const uint8_t* data, size_t len) override {
    if (fd_ < 0) return 0;
    ssize_t n = ::send(fd_, data, len, 0);
    if (n <= 0) {
      close();
      return 0;
    }
    return (size_t)n;
  }
  int read(uint8_t* buf, size_t len) override {
    if (fd_ < 0) return -1;
    ssize_t n = ::recv(fd_, buf, len, MSG_DONTWAIT);
    if (n > 0) return (int)n;
    if (n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR)) return 0;
    close();
    return -1;
  }
  void close() override {
    if (fd_ >= 0) ::close(fd_);
    fd_ = -1;
  }

 private:
  int fd_;
};

class SimHal : public Hal {
 public:
  SimHal()
      : t0_(monoMs()), button_(false), quit_(false), mic_on_(false), next_frame_(0),
        phase_(0), freq_(440.0), wav_pos_(0), voice_(false), ext_mic_(false), ext_primed_(false) {}

  // The recording the Feather build plays in place of a microphone, decoded by the same code.
  void loadVoiceClip() {
    VoiceClip clip(kVoiceClipAdpcm, kVoiceClipBytes);
    wav_.resize(clip.totalSamples());
    clip.read(wav_.data(), wav_.size());
    voice_ = true;
  }

  bool loadWav(const char* path) {
    FILE* f = fopen(path, "rb");
    if (!f) return false;
    uint8_t hdr[44];
    bool ok = fread(hdr, 1, 44, f) == 44 && memcmp(hdr, "RIFF", 4) == 0;
    if (ok) {
      int16_t s;
      while (fread(&s, 2, 1, f) == 1) wav_.push_back(s);
    }
    fclose(f);
    return ok && !wav_.empty();
  }
  void setTone(double hz) { freq_ = hz; }
  bool quitRequested() const { return quit_; }
  const char* micSource() const {
    return ext_mic_ ? "ext" : wav_.empty() ? "tone" : voice_ ? "voice" : "wav";
  }

  // ---- Hal
  uint32_t millis() override { return (uint32_t)(monoMs() - t0_); }
  void sleepMs(uint32_t ms) override { usleep(ms * 1000); }
  bool buttonPressed() override {
    pumpStdin();
    return button_;
  }
  void setLed(LedColor c) override {
    const char* name = c == LedColor::Green ? "green" : c == LedColor::White ? "white" : "off";
    out("{\"sim\":\"led\",\"color\":\"%s\"}", name);
  }
  bool micStart() override {
    mic_on_ = true;
    next_frame_ = monoMs() + kFrameMs;
    ext_.clear();  // a microphone cannot hear the past: drop anything from before it was on
    ext_primed_ = false;
    if (voice_) wav_pos_ = 0;  // like the device: every capture hears the recording from the top
    return true;
  }
  void micStop() override { mic_on_ = false; }
  size_t micRead(int16_t* dst, size_t samples) override {
    if (!mic_on_) return 0;
    uint64_t now = monoMs();
    if (now < next_frame_) usleep((useconds_t)((next_frame_ - now) * 1000));  // real-time pacing
    now = monoMs();
    next_frame_ += kFrameMs;
    if (now > next_frame_ + 200) next_frame_ = now + kFrameMs;  // fell behind: resync

    if (ext_mic_) {
      // Audio fed from outside (the laptop microphone, via the browser UI). A small jitter
      // buffer smooths bursty delivery; if nothing has arrived the clip hears silence.
      if (ext_.size() < samples) ext_primed_ = false;
      else if (ext_.size() >= 3 * samples) ext_primed_ = true;
      for (size_t i = 0; i < samples; ++i) {
        if (ext_primed_) {
          dst[i] = ext_.front();
          ext_.pop_front();
        } else {
          dst[i] = 0;
        }
      }
    } else if (!wav_.empty()) {
      for (size_t i = 0; i < samples; ++i) {
        dst[i] = wav_[wav_pos_];
        wav_pos_ = (wav_pos_ + 1) % wav_.size();
      }
    } else {
      // A tone with a slow tremolo, so the level meter on the tablet side visibly moves.
      for (size_t i = 0; i < samples; ++i) {
        double t = (double)phase_++ / kSampleRate;
        double amp = 6000.0 * (0.55 + 0.45 * sin(2 * M_PI * 0.5 * t));
        dst[i] = (int16_t)(amp * sin(2 * M_PI * freq_ * t));
      }
    }
    return samples;
  }
  void beep(bool on) override { out("{\"sim\":\"beep\",\"on\":%s}", on ? "true" : "false"); }
  bool networkUp() override { return true; }
  void log(const char* message) override { out("{\"sim\":\"log\",\"msg\":\"%s\"}", message); }

 private:
  struct Scheduled {
    uint64_t at;
    bool pressed;
  };

  void schedule(uint64_t delay_ms, bool pressed) {
    Scheduled s = {monoMs() + delay_ms, pressed};
    scheduled_.push_back(s);
  }

  void handleLine(const std::string& line) {
    if (line == "down") button_ = true;
    else if (line == "up") button_ = false;
    else if (line == "short") { schedule(0, true); schedule(120, false); }
    else if (line == "long") { schedule(0, true); schedule(1800, false); }
    else if (line == "double") { schedule(0, true); schedule(90, false); schedule(220, true); schedule(310, false); }
    else if (line == "quit") quit_ = true;
    else if (line == "mic ext") { ext_mic_ = true; ext_.clear(); ext_primed_ = false; }
    else if (line == "mic tone") { ext_mic_ = false; ext_.clear(); }
    else if (line.size() > 2 && line[0] == 'a' && line[1] == ' ') feedAudio(line.c_str() + 2);
  }

  // "a <base64>": 16 kHz mono int16 little-endian samples for the simulated microphone.
  void feedAudio(const char* b64) {
    if (!ext_mic_ || !mic_on_) return;  // sound only matters while the microphone is on
    std::vector<uint8_t> bytes;
    uint32_t acc = 0;
    int bits = 0;
    for (const char* p = b64; *p && *p != '='; ++p) {
      int v;
      char c = *p;
      if (c >= 'A' && c <= 'Z') v = c - 'A';
      else if (c >= 'a' && c <= 'z') v = c - 'a' + 26;
      else if (c >= '0' && c <= '9') v = c - '0' + 52;
      else if (c == '+') v = 62;
      else if (c == '/') v = 63;
      else continue;
      acc = (acc << 6) | (uint32_t)v;
      bits += 6;
      if (bits >= 8) {
        bits -= 8;
        bytes.push_back((uint8_t)((acc >> bits) & 0xFF));
      }
    }
    for (size_t i = 0; i + 1 < bytes.size(); i += 2)
      ext_.push_back((int16_t)(bytes[i] | (bytes[i + 1] << 8)));
    const size_t cap = kFrameSamples * 15;  // at most 300 ms waiting, so latency stays bounded
    while (ext_.size() > cap) ext_.pop_front();
  }

  void pumpStdin() {
    struct pollfd pfd = {0, POLLIN, 0};
    while (poll(&pfd, 1, 0) > 0) {
      char buf[4096];
      ssize_t n = ::read(0, buf, sizeof buf);
      if (n <= 0) {  // parent went away
        quit_ = true;
        break;
      }
      for (ssize_t i = 0; i < n; ++i) {
        if (buf[i] == '\n') {
          handleLine(line_);
          line_.clear();
        } else if (buf[i] != '\r') {
          line_ += buf[i];
        }
      }
    }
    uint64_t now = monoMs();
    while (!scheduled_.empty() && scheduled_.front().at <= now) {
      button_ = scheduled_.front().pressed;
      scheduled_.pop_front();
    }
  }

  uint64_t t0_;
  bool button_;
  bool quit_;
  bool mic_on_;
  uint64_t next_frame_;
  uint64_t phase_;
  double freq_;
  std::vector<int16_t> wav_;
  size_t wav_pos_;
  bool voice_;
  bool ext_mic_;
  bool ext_primed_;
  std::deque<int16_t> ext_;
  std::string line_;
  std::deque<Scheduled> scheduled_;
};

int main(int argc, char** argv) {
  signal(SIGPIPE, SIG_IGN);

  std::string host = "127.0.0.1";
  int opus_kbps = 32;
  ClipConfig cfg;
  SimHal hal;
  for (int i = 1; i < argc; ++i) {
    std::string a = argv[i];
    const char* v = i + 1 < argc ? argv[i + 1] : NULL;
    if (a == "--host" && v) { host = v; ++i; }
    else if (a == "--port" && v) { cfg.gateway_port = (uint16_t)atoi(v); ++i; }
    else if (a == "--tone" && v) { hal.setTone(atof(v)); ++i; }
    else if (a == "--wav" && v) {
      if (!hal.loadWav(v)) { fprintf(stderr, "cannot read WAV %s\n", v); return 2; }
      ++i;
    }
    else if (a == "--voice") { hal.loadVoiceClip(); }
    else if (a == "--pcm") { opus_kbps = 0; }
    else if (a == "--opus" && v) { opus_kbps = atoi(v); ++i; }
    else {
      fprintf(stderr,
              "usage: sim_clip [--host H] [--port P] [--tone HZ | --wav FILE | --voice] [--opus KBPS | --pcm]\n"
              "  --voice plays the recording built into the firmware in place of a microphone\n"
              "  audio is sent as Opus at 32 kbit/s unless --opus or --pcm says otherwise\n"
              "stdin commands: down, up, short, long, double, quit\n");
      return 2;
    }
  }
  cfg.gateway_host = host.c_str();
  cfg.device_id = "earshot-clip-sim";
  OpusAudioEncoder* opus = NULL;
  if (opus_kbps > 0) {
    opus = new OpusAudioEncoder((uint32_t)opus_kbps * 1000, 1);
    if (!opus->ok()) {
      fprintf(stderr, "Opus encoder failed to start\n");
      return 2;
    }
    cfg.encoder = opus;
  }

  PosixTransport transport;
  ClipApp app(hal, transport, cfg, (uint32_t)monoMs() | 1u);
  app.begin();

  uint64_t last_status = 0;
  while (!hal.quitRequested()) {
    app.tick();
    uint64_t now = monoMs();
    if (now - last_status >= 200) {
      last_status = now;
      const ClipStats& s = app.stats();
      out("{\"sim\":\"status\",\"state\":\"%s\",\"link\":%s,\"captured\":%u,\"sent\":%u,"
          "\"dropped\":%u,\"markers\":%u,\"captures\":%u,\"audio_bytes\":%u,\"codec\":\"%s\","
          "\"mic\":\"%s\"}",
          stateName(app.state()), app.linkOpen() ? "true" : "false", s.frames_captured,
          s.frames_sent, s.frames_dropped, s.markers, s.captures, s.audio_bytes_sent,
          opus ? "opus" : "pcm", hal.micSource());
    }
  }
  return 0;
}
