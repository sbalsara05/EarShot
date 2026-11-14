#!/usr/bin/env bash
# macOS: llama.cpp from Homebrew (pinned release v1.0.0 = commit b1b770d) for the optional Phi passes.
# Homebrew splits ggml into its own formula and its llama.pc does not list it, so the llama.h include of
# ggml.h fails; this writes a llama.pc that requires ggml into core/.pkgconfig (git-ignored).
# Then:  export PKG_CONFIG_PATH="$PWD/core/.pkgconfig:$PKG_CONFIG_PATH"; cd core && swift build -c release
# whisper.cpp: brew install whisper-cpp (or EARSHOT_NO_WHISPER=1 for transcript input only).
set -euo pipefail
cd "$(dirname "$0")/../.."
brew list llama.cpp >/dev/null 2>&1 || brew install llama.cpp
L=$(brew --prefix llama.cpp)
mkdir -p core/.pkgconfig
cat > core/.pkgconfig/llama.pc <<PC
Name: llama
Description: llama.cpp (Homebrew) with its ggml dependency
Version: $(brew list --versions llama.cpp | awk '{print $2}')
Requires: ggml
Libs: -L$L/lib -lllama
Cflags: -I$L/include
PC
core/scripts/fetch_phi.sh
echo "export PKG_CONFIG_PATH=\"$PWD/core/.pkgconfig:\$PKG_CONFIG_PATH\""
