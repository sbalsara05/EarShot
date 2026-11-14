#!/usr/bin/env bash
# End to end on a laptop: the real firmware core (simulator, built-in voice, Opus) -> WebSocket ->
# capture -> the live pipeline the iPad uses (LiveSession) -> whisper.cpp -> chart.
# Needs: a C++ compiler, PlatformIO's Opus sources (cd firmware && pio pkg install -e atom-voices3r),
# python3 with websockets, libopus, whisper.cpp (core/scripts/setup_linux.sh) and a ggml model.
set -euo pipefail
cd "$(dirname "$0")/../.."
MODEL=${MODEL:-models/ggml-base.en.bin}
OUT=${OUT:-core/out/e2e_firmware}
PY=${PYTHON:-python3}
mkdir -p "$OUT"
make -C firmware sim >/dev/null
"$PY" core/tools/record_clip.py "$OUT/voice.clipcap" --sim firmware/build/sim_clip --seconds 14
(cd core && swift build -c release >/dev/null && .build/release/earshot-eval "../$OUT/voice.clipcap" --asr-model "../$MODEL" --out "../$OUT" 2>/dev/null)
echo "expected (firmware/BLUETOOTH.md): sixty eight year old male with chest pain for thirty minutes, radiating to the"
echo "left arm. Blood pressure is one fifty over ninety. Heart rate is one hundred and four. Aspirin given at fourteen ten."
