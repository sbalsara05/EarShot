#!/usr/bin/env bash
# Phi-3.5-mini-instruct GGUF (bartowski quantization of microsoft/Phi-3.5-mini-instruct, MIT licence).
# Usage: core/scripts/fetch_phi.sh [Q4_K_M|IQ4_XS|Q8_0]   (default Q4_K_M; files go to models/, git-ignored)
# Sizes and sha256 are recorded in docs/DECISIONS.md; a mismatch deletes the file.
set -euo pipefail
cd "$(dirname "$0")/../.."
Q=${1:-Q4_K_M}
case "$Q" in
  Q4_K_M) SHA=e4165e3a71af97f1b4820da61079826d8752a2088e313af0c7d346796c38eff5 ;;
  IQ4_XS) SHA=bc4e2d58ea331ffded51fc237874306df2a711209ab0ec91dd57b49dfdb6e36a ;;
  Q8_0)   SHA=76fbf02f6fe92af57dbd818409bc8a0240026f1f3609bb405c3be94c973fb823 ;;
  *) echo "unknown quant $Q (Q4_K_M, IQ4_XS, Q8_0)"; exit 2 ;;
esac
F=models/phi-3.5-mini-instruct-$Q.gguf
mkdir -p models
if [ ! -f "$F" ]; then
  curl -sSL -o "$F.part" "https://huggingface.co/bartowski/Phi-3.5-mini-instruct-GGUF/resolve/main/Phi-3.5-mini-instruct-$Q.gguf"
  mv "$F.part" "$F"
fi
GOT=$( (command -v sha256sum >/dev/null && sha256sum "$F" || shasum -a 256 "$F") | awk '{print $1}')
if [ "$GOT" != "$SHA" ]; then echo "sha256 mismatch for $F ($GOT); deleted"; rm -f "$F"; exit 1; fi
echo "ok: $F"
