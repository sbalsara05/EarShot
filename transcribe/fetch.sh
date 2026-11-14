#!/usr/bin/env bash
# Gets what the transcription package needs and the repo does not hold: the whisper.cpp framework, built from
# source (about ten minutes, needs Xcode and cmake), and the Whisper model (465 MB). Run once, from anywhere.
set -euo pipefail
cd "$(dirname "$0")"
REVISION=5922450fbce1ed9d1648babd0d5ac4520055b436   # the whisper.cpp commit this was tested with
MODEL=ggml-small.en
if [ ! -d Frameworks/whisper.xcframework ]; then
  work=$(mktemp -d)
  git clone https://github.com/ggml-org/whisper.cpp "$work/whisper.cpp"
  (cd "$work/whisper.cpp" && git checkout "$REVISION" && ./build-xcframework.sh)
  mkdir -p Frameworks
  cp -R "$work/whisper.cpp/build-apple/whisper.xcframework" Frameworks/
  rm -rf Frameworks/whisper.xcframework/tvos-* Frameworks/whisper.xcframework/xros-* "$work"
fi
mkdir -p Models
[ -f "Models/$MODEL.bin" ] || curl -L -o "Models/$MODEL.bin" "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/$MODEL.bin"
(cd ../app && xcodegen generate)
echo "Ready. Build the app, or try: swift run -c release transcribe-wav Models/$MODEL.bin some-call.wav"
