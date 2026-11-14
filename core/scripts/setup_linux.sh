#!/usr/bin/env bash
# Install Swift 6.2.1, llama.cpp (shared lib, pkg-config "llama", pinned), whisper.cpp (shared lib,
# pkg-config "whisper", built on llama.cpp's ggml) and the models on Ubuntu 24.04.
#
# llama.cpp and whisper.cpp each bundle ggml. Two copies of ggml in one process clash (same symbols),
# so llama.cpp is built first and installs ggml, and whisper.cpp is built against that ggml
# (WHISPER_USE_SYSTEM_GGML), as Homebrew does on macOS.
#
#   EARSHOT_NO_LLAMA=1   skip llama.cpp and Phi (then build core with EARSHOT_NO_LLAMA=1)
#   EARSHOT_SKIP_MODELS=1  skip model downloads
set -euo pipefail
cd "$(dirname "$0")/../.."
PREFIX=${PREFIX:-/usr/local}
SWIFT_DIR=${SWIFT_DIR:-/opt/swift}
LLAMA_TAG=${LLAMA_TAG:-v1.0.0}                                    # = commit b1b770d90d94cad9e9ea5b993bdbc383a522fb28
LLAMA_COMMIT=b1b770d90d94cad9e9ea5b993bdbc383a522fb28
SUDO=$([ "$(id -u)" = 0 ] && echo "" || echo sudo)
# llama.cpp's build uses clang-only warning flags; Swift's toolchain ships clang
CC_FLAGS=()
command -v clang >/dev/null && CC_FLAGS=(-DCMAKE_C_COMPILER=clang -DCMAKE_CXX_COMPILER=clang++)

if ! command -v swift >/dev/null; then
  curl -sSL -o /tmp/swift.tar.gz https://download.swift.org/swift-6.2.1-release/ubuntu2404/swift-6.2.1-RELEASE/swift-6.2.1-RELEASE-ubuntu24.04.tar.gz
  mkdir -p "$SWIFT_DIR" && tar xzf /tmp/swift.tar.gz -C "$SWIFT_DIR" --strip-components=1
  echo "add to PATH: export PATH=$SWIFT_DIR/usr/bin:\$PATH"
fi

if [ "${EARSHOT_NO_LLAMA:-0}" != 1 ] && ! pkg-config --exists llama 2>/dev/null; then
  rm -rf /tmp/llama.cpp && git clone --depth 1 --branch "$LLAMA_TAG" https://github.com/ggml-org/llama.cpp /tmp/llama.cpp
  [ "$(git -C /tmp/llama.cpp rev-parse HEAD)" = "$LLAMA_COMMIT" ] || { echo "llama.cpp $LLAMA_TAG is not commit $LLAMA_COMMIT"; exit 1; }
  cmake -S /tmp/llama.cpp -B /tmp/llama.cpp/build -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=ON \
    -DLLAMA_BUILD_EXAMPLES=OFF -DLLAMA_BUILD_TESTS=OFF -DLLAMA_BUILD_TOOLS=OFF -DLLAMA_BUILD_SERVER=OFF -DLLAMA_BUILD_APP=OFF -DLLAMA_BUILD_COMMON=OFF -DLLAMA_OPENSSL=OFF \
    -DCMAKE_INSTALL_PREFIX="$PREFIX" "${CC_FLAGS[@]}"
  cmake --build /tmp/llama.cpp/build -j"$(nproc)"
  $SUDO cmake --install /tmp/llama.cpp/build
  $SUDO ldconfig
fi

if ! pkg-config --exists whisper 2>/dev/null; then
  # llama.cpp installs ggml as a CMake package (no ggml.pc); whisper's WHISPER_USE_SYSTEM_GGML finds it there
  SYSTEM_GGML=OFF
  ls "$PREFIX"/lib*/cmake/ggml/ggml-config.cmake >/dev/null 2>&1 && SYSTEM_GGML=ON
  rm -rf /tmp/whisper.cpp && git clone --depth 1 https://github.com/ggml-org/whisper.cpp /tmp/whisper.cpp
  cmake -S /tmp/whisper.cpp -B /tmp/whisper.cpp/build -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=ON \
    -DWHISPER_BUILD_EXAMPLES=OFF -DWHISPER_BUILD_TESTS=OFF -DWHISPER_USE_SYSTEM_GGML=$SYSTEM_GGML -DCMAKE_INSTALL_PREFIX="$PREFIX" -DCMAKE_PREFIX_PATH="$PREFIX" "${CC_FLAGS[@]}"
  cmake --build /tmp/whisper.cpp/build -j"$(nproc)"
  $SUDO cmake --install /tmp/whisper.cpp/build
  $SUDO ldconfig
fi

if [ "${EARSHOT_SKIP_MODELS:-0}" != 1 ]; then
  mkdir -p models
  [ -f models/ggml-small.en.bin ] || curl -sSL -o models/ggml-small.en.bin https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-small.en.bin
  [ "${EARSHOT_NO_LLAMA:-0}" = 1 ] || core/scripts/fetch_phi.sh Q4_K_M
fi
echo "done. build: cd core && swift build -c release"
