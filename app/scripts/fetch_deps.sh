#!/usr/bin/env bash
# macOS + Xcode 26: builds whisper.xcframework, checks the Whisper model, regenerates the project.
set -euo pipefail
cd "$(dirname "$0")/.."
WCPP_REV=${WCPP_REV:-5922450fbce1ed9d1648babd0d5ac4520055b436}   # the commit the pipeline was tested with
if [ ! -d Frameworks/whisper.xcframework ]; then
  rm -rf /tmp/whisper.cpp && git clone https://github.com/ggml-org/whisper.cpp /tmp/whisper.cpp
  (cd /tmp/whisper.cpp && git checkout "$WCPP_REV" && ./build-xcframework.sh)
  mkdir -p Frameworks && cp -R /tmp/whisper.cpp/build-apple/whisper.xcframework Frameworks/
fi
# The fine-tuned EMS model (models/, in git via LFS) is bundled by project.yml. Make sure it is the real
# file, not an LFS pointer; fetch it from Hugging Face if LFS is not available (needs HF_TOKEN).
(cd .. && { git lfs pull --include models/ggml-ems-small.en-ft-q5_0.bin 2>/dev/null || true; })
../core/scripts/fetch_model.sh --verify 2>/dev/null || ../core/scripts/fetch_model.sh
command -v xcodegen >/dev/null || brew install xcodegen
xcodegen generate
echo "Open app/Earshot.xcodeproj, set your signing team, run on an iPad or iPhone."
