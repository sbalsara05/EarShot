#!/usr/bin/env bash
# Downloads the fine-tuned EMS Whisper model (whisper.cpp ggml, f16 / unquantized) into models/ and checks its sha256.
# The Hugging Face repo is private: export HF_TOKEN first. The token is only sent in the request header.
#   HF_TOKEN=... core/scripts/fetch_model.sh
# Exits non-zero if HF_TOKEN is missing, the download fails, or the checksum does not match.
set -euo pipefail
cd "$(dirname "$0")/../.."

FILE=ggml-ems-small.en-ft-f16.bin
URL=https://huggingface.co/shouryadav/whisper-ems-small.en-ft-fmt/resolve/main/$FILE
SHA256=e9a2eb3d92c8cb0141232b9b9c05ac982c3634ad54a4adbe1ca0d40bac87fc97
DEST=models/$FILE

sha() { shasum -a 256 "$1" | cut -d' ' -f1; }

# --verify [file]: only check a copy (default models/$FILE); used before bundling it into the app.
if [ "${1:-}" = "--verify" ]; then
  f=${2:-$DEST}
  [ -f "$f" ] || { echo "error: $f not found (run core/scripts/fetch_model.sh)" >&2; exit 4; }
  got=$(sha "$f")
  [ "$got" = "$SHA256" ] || { echo "error: sha256 mismatch for $f (got $got, want $SHA256)" >&2; exit 3; }
  echo "$f sha256 OK"; exit 0
fi

mkdir -p models
if [ -f "$DEST" ] && [ "$(sha "$DEST")" = "$SHA256" ]; then
  echo "$DEST already present, sha256 OK"; exit 0
fi
if [ -z "${HF_TOKEN:-}" ]; then
  echo "error: HF_TOKEN is not set (the model repo is private)" >&2; exit 2
fi

# Header from stdin so the token never appears in the process list.
printf 'Authorization: Bearer %s\n' "$HF_TOKEN" | curl -fL --retry 3 -H @- -o "$DEST.part" "$URL"
got=$(sha "$DEST.part")
if [ "$got" != "$SHA256" ]; then
  rm -f "$DEST.part"
  echo "error: sha256 mismatch for $FILE (got $got, want $SHA256)" >&2; exit 3
fi
mv "$DEST.part" "$DEST"
echo "$DEST downloaded, sha256 OK"
