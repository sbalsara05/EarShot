#!/usr/bin/env bash
# Gets what the transcription package needs and plain git does not hold. Run once, from anywhere.
#   - the whisper.cpp framework, built from source (about ten minutes; needs Xcode and cmake)
#   - the Whisper model, 488 MB, from Git LFS (needs git-lfs: brew install git-lfs)
set -euo pipefail
cd "$(dirname "$0")"
REVISION=5922450fbce1ed9d1648babd0d5ac4520055b436   # the whisper.cpp commit this was tested with
MODEL=ggml-ems-small.en-ft-f16.bin
SHA256=e9a2eb3d92c8cb0141232b9b9c05ac982c3634ad54a4adbe1ca0d40bac87fc97

if [ ! -d Frameworks/whisper.xcframework ]; then
  work=$(mktemp -d)
  git clone https://github.com/ggml-org/whisper.cpp "$work/whisper.cpp"
  (cd "$work/whisper.cpp" && git checkout "$REVISION" && ./build-xcframework.sh)
  mkdir -p Frameworks
  cp -R "$work/whisper.cpp/build-apple/whisper.xcframework" Frameworks/
  rm -rf "$work"
fi

# Without git-lfs the model file is a few lines of text that point at the real one.
git lfs install --local >/dev/null
git lfs pull --include "transcribe/Models/$MODEL"
if [ "$(shasum -a 256 "Models/$MODEL" | cut -d' ' -f1)" != "$SHA256" ]; then
  echo "error: Models/$MODEL is not the model this was tested with. Is git-lfs installed?" >&2
  exit 1
fi

(cd ../app && xcodegen generate)
echo "Ready. Build the app, or try: swift run -c release transcribe-wav Models/$MODEL some-call.wav"
