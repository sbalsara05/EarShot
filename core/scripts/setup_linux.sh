#!/usr/bin/env bash
# Install Swift 6.2.1 + whisper.cpp (shared lib, pkg-config "whisper") + the stock model on Ubuntu 24.04 x86_64.
set -euo pipefail
PREFIX=${PREFIX:-/usr/local}
SWIFT_DIR=${SWIFT_DIR:-/opt/swift}
if ! command -v swift >/dev/null; then
  curl -sSL -o /tmp/swift.tar.gz https://download.swift.org/swift-6.2.1-release/ubuntu2404/swift-6.2.1-RELEASE/swift-6.2.1-RELEASE-ubuntu24.04.tar.gz
  mkdir -p "$SWIFT_DIR" && tar xzf /tmp/swift.tar.gz -C "$SWIFT_DIR" --strip-components=1
  echo "add to PATH: export PATH=$SWIFT_DIR/usr/bin:\$PATH"
fi
if ! pkg-config --exists whisper 2>/dev/null; then
  rm -rf /tmp/whisper.cpp && git clone --depth 1 https://github.com/ggml-org/whisper.cpp /tmp/whisper.cpp
  cmake -S /tmp/whisper.cpp -B /tmp/whisper.cpp/build -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=ON \
    -DWHISPER_BUILD_EXAMPLES=OFF -DWHISPER_BUILD_TESTS=OFF -DCMAKE_INSTALL_PREFIX="$PREFIX"
  cmake --build /tmp/whisper.cpp/build -j"$(nproc)" && sudo cmake --install /tmp/whisper.cpp/build && sudo ldconfig
fi
mkdir -p models
[ -f models/ggml-small.en.bin ] || curl -sSL -o models/ggml-small.en.bin https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-small.en.bin
echo "done. build: cd core && swift build -c release"
