#!/usr/bin/env bash
# macOS + Xcode 26: builds whisper.xcframework, downloads a Whisper model, regenerates the project.
set -euo pipefail
cd "$(dirname "$0")/.."
WCPP_REV=${WCPP_REV:-5922450fbce1ed9d1648babd0d5ac4520055b436}   # the commit the pipeline was tested with
MODEL=${MODEL:-ggml-small.en}                                      # ggml-base.en is faster, a little less accurate
if [ ! -d Frameworks/whisper.xcframework ]; then
  rm -rf /tmp/whisper.cpp && git clone https://github.com/ggml-org/whisper.cpp /tmp/whisper.cpp
  (cd /tmp/whisper.cpp && git checkout "$WCPP_REV" && ./build-xcframework.sh)
  mkdir -p Frameworks && cp -R /tmp/whisper.cpp/build-apple/whisper.xcframework Frameworks/
fi
mkdir -p Models
[ -f "Models/$MODEL.bin" ] || curl -L -o "Models/$MODEL.bin" "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/$MODEL.bin"
# A fine-tuned EMS model from earshot-data, if you have one
for f in ../models/whisper-ems-small.en*.bin; do [ -f "$f" ] && cp "$f" Models/; done
command -v xcodegen >/dev/null || brew install xcodegen
xcodegen generate
echo "Open app/Earshot.xcodeproj, set your signing team, run on an iPad or iPhone."
