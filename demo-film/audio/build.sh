#!/usr/bin/env bash
# One-command rebuild of the v3 soundtrack (synthetic ambient bed + Foley). Usage: ./build.sh
set -euo pipefail
cd "$(dirname "$0")/src"
nice python3 sfx.py       # Foley (recorded samples) -> src/.sfx_dry.wav
nice python3 music.py     # synthetic bed, ducked by the Foley -> src/.music_dry.wav
nice python3 mix.py       # shared room, levels, limiter -> music.wav, sfx_only.wav, mix.wav, mix_preview.mp3
nice python3 harmony.py   # fails the build on any harmony violation
nice python3 check.py     # format, loudness, onsets, band energy, ducking, spectrogram -> check_report.txt
