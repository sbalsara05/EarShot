#!/bin/bash
# Run once after cloning: builds llama.cpp for iPhone, iPad, the simulator and the Mac (about ten minutes),
# and downloads the language model (2.7 GB). Neither is kept in the repo. Needs Xcode and cmake.
set -euo pipefail
cd "$(dirname "$0")"

TAG=b12383   # the llama.cpp build this package was written and measured against
MODEL=Qwen3.5-4B-Q4_K_M.gguf
MODEL_URL=https://huggingface.co/unsloth/Qwen3.5-4B-GGUF/resolve/main/$MODEL
MODEL_SHA=00fe7986ff5f6b463e62455821146049db6f9313603938a70800d1fb69ef11a4

if [ ! -d Frameworks/llama.xcframework ]; then
  work=$(mktemp -d)
  git clone --quiet --depth 1 --branch "$TAG" https://github.com/ggml-org/llama.cpp "$work/llama.cpp"
  (cd "$work/llama.cpp" && ./build-xcframework.sh)
  built=$work/llama.cpp/build-apple/llama.xcframework
  mkdir -p Frameworks
  # Only the three kinds of device the app and the Mac tool run on; the full framework is four times the size.
  xcodebuild -create-xcframework -framework "$built/ios-arm64/llama.framework" -framework "$built/ios-arm64_x86_64-simulator/llama.framework" \
    -framework "$built/macos-arm64_x86_64/llama.framework" -output Frameworks/llama.xcframework
  rm -rf "$work"
fi

mkdir -p Models
if [ ! -f "Models/$MODEL" ]; then
  curl -L --fail -o "Models/$MODEL.part" "$MODEL_URL"
  mv "Models/$MODEL.part" "Models/$MODEL"
fi
echo "$MODEL_SHA  Models/$MODEL" | shasum -a 256 -c -

(cd ../app && xcodegen generate)
