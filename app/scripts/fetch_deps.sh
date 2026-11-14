#!/usr/bin/env bash
# macOS + Xcode 26: builds whisper.xcframework and llama.xcframework, downloads a Whisper model,
# regenerates the project. Phi (optional, off by default in the app): PHI=1 also fetches the
# Q4_K_M and IQ4_XS models (core/scripts/fetch_phi.sh) and bundles them; or copy a .gguf into the
# app's Documents folder from Finder instead, which keeps the app small.
set -euo pipefail
cd "$(dirname "$0")/.."
WCPP_REV=${WCPP_REV:-5922450fbce1ed9d1648babd0d5ac4520055b436}   # the commit the pipeline was tested with
LLAMA_TAG=${LLAMA_TAG:-v1.0.0}                                    # = commit b1b770d90d94cad9e9ea5b993bdbc383a522fb28 (as core/)
MODEL=${MODEL:-ggml-small.en}                                      # ggml-base.en is faster, a little less accurate
if [ ! -d Frameworks/whisper.xcframework ]; then
  rm -rf /tmp/whisper.cpp && git clone https://github.com/ggml-org/whisper.cpp /tmp/whisper.cpp
  (cd /tmp/whisper.cpp && git checkout "$WCPP_REV" && ./build-xcframework.sh)
  mkdir -p Frameworks && cp -R /tmp/whisper.cpp/build-apple/whisper.xcframework Frameworks/
fi
if [ ! -d Frameworks/llama.xcframework ]; then
  rm -rf /tmp/llama.cpp && git clone --depth 1 --branch "$LLAMA_TAG" https://github.com/ggml-org/llama.cpp /tmp/llama.cpp
  (cd /tmp/llama.cpp && ./build-xcframework.sh)
  mkdir -p Frameworks && cp -R /tmp/llama.cpp/build-apple/llama.xcframework Frameworks/
fi
mkdir -p Models
if [ "${PHI:-0}" = 1 ]; then
  ../core/scripts/fetch_phi.sh Q4_K_M && ../core/scripts/fetch_phi.sh IQ4_XS
  cp ../models/phi-3.5-mini-instruct-Q4_K_M.gguf ../models/phi-3.5-mini-instruct-IQ4_XS.gguf Models/
fi
[ -f "Models/$MODEL.bin" ] || curl -L -o "Models/$MODEL.bin" "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/$MODEL.bin"
# A fine-tuned EMS model from earshot-data, if you have one
for f in ../models/whisper-ems-small.en*.bin; do [ -f "$f" ] && cp "$f" Models/; done
command -v xcodegen >/dev/null || brew install xcodegen
xcodegen generate
echo "Open app/Earshot.xcodeproj, set your signing team, run on an iPad or iPhone."
