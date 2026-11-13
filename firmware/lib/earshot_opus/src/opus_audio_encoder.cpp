#include "opus_audio_encoder.h"

#include <opus.h>

#ifdef ARDUINO
#include <Arduino.h>
static uint32_t nowMicros() { return micros(); }
#else
static uint32_t nowMicros() { return 0; }
#endif

namespace earshot {

OpusAudioEncoder::OpusAudioEncoder(uint32_t bitrate_bps, int complexity)
    : enc_(NULL), bitrate_(bitrate_bps), max_us_(0) {
  int err = 0;
  enc_ = opus_encoder_create(16000, 1, OPUS_APPLICATION_VOIP, &err);
  if (err != OPUS_OK || !enc_) {
    enc_ = NULL;
    return;
  }
  opus_encoder_ctl(enc_, OPUS_SET_BITRATE((opus_int32)bitrate_bps));
  opus_encoder_ctl(enc_, OPUS_SET_VBR(0));  // constant bitrate: every packet the same size
  opus_encoder_ctl(enc_, OPUS_SET_COMPLEXITY(complexity));
  opus_encoder_ctl(enc_, OPUS_SET_SIGNAL(OPUS_SIGNAL_VOICE));
  opus_encoder_ctl(enc_, OPUS_SET_DTX(0));  // keep sending during silence; gaps then mean loss
}

OpusAudioEncoder::~OpusAudioEncoder() {
  if (enc_) opus_encoder_destroy(enc_);
}

void OpusAudioEncoder::reset() {
  if (enc_) opus_encoder_ctl(enc_, OPUS_RESET_STATE);
}

size_t OpusAudioEncoder::encode(const int16_t* pcm, size_t samples, uint8_t* out, size_t out_max) {
  if (!enc_) return 0;
  uint32_t t0 = nowMicros();
  opus_int32 n = opus_encode(enc_, pcm, (int)samples, out, (opus_int32)out_max);
  uint32_t dt = nowMicros() - t0;
  if (dt > max_us_) max_us_ = dt;
  return n > 0 ? (size_t)n : 0;
}

}  // namespace earshot
