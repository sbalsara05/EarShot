#include "voice_clip.h"

namespace earshot {

namespace {
const int16_t kStep[89] = {
    7,     8,     9,     10,    11,    12,    13,    14,    16,    17,    19,    21,    23,
    25,    28,    31,    34,    37,    41,    45,    50,    55,    60,    66,    73,    80,
    88,    97,    107,   118,   130,   143,   157,   173,   190,   209,   230,   253,   279,
    307,   337,   371,   408,   449,   494,   544,   598,   658,   724,   796,   876,   963,
    1060,  1166,  1282,  1411,  1552,  1707,  1878,  2066,  2272,  2499,  2749,  3024,  3327,
    3660,  4026,  4428,  4871,  5358,  5894,  6484,  7132,  7845,  8630,  9493,  10442, 11487,
    12635, 13899, 15289, 16818, 18500, 20350, 22385, 24623, 27086, 29794, 32767};
const int8_t kIndexStep[16] = {-1, -1, -1, -1, 2, 4, 6, 8, -1, -1, -1, -1, 2, 4, 6, 8};
}  // namespace

VoiceClip::VoiceClip(const uint8_t* adpcm, size_t bytes)
    : data_(adpcm), bytes_(bytes), pos_(0), pred_(0), index_(0) {}

void VoiceClip::rewind() {
  pos_ = 0;
  pred_ = 0;
  index_ = 0;
}

void VoiceClip::read(int16_t* out, size_t samples) {
  for (size_t i = 0; i < samples; ++i) {
    if (bytes_ == 0) {
      out[i] = 0;
      continue;
    }
    if (pos_ >= bytes_ * 2) rewind();
    uint8_t byte = data_[pos_ >> 1];
    uint8_t n = (pos_ & 1) ? (uint8_t)(byte >> 4) : (uint8_t)(byte & 0x0F);
    ++pos_;

    int32_t step = kStep[index_];
    int32_t diff = step >> 3;
    if (n & 4) diff += step;
    if (n & 2) diff += step >> 1;
    if (n & 1) diff += step >> 2;
    pred_ += (n & 8) ? -diff : diff;
    if (pred_ > 32767) pred_ = 32767;
    if (pred_ < -32768) pred_ = -32768;
    index_ += kIndexStep[n];
    if (index_ < 0) index_ = 0;
    if (index_ > 88) index_ = 88;
    out[i] = (int16_t)pred_;
  }
}

}  // namespace earshot
