# Earshot

EMS edge scribe (working name). A clip on the medic records the call; the iPad writes the chart.

| Folder | What is in it |
|---|---|
| `firmware/` | The clip: button, consent, Opus audio over Bluetooth or Wi-Fi, plus a laptop simulator |
| `app/` | The iPhone and iPad app |
| `core/` | The transcription pipeline (Swift package EarshotCore): Whisper, cleanup, rules, chart/SOAP/NEMSIS, biasing, and tests. Used by the app and by the `earshot-eval` tool |
| `shared/` | The EMS dictionary and formulary the pipeline reads |
| `eval/` | Scoring the pipeline on the data team's test calls (see `eval/README.md`) |
| `docs/` | `HYBRID.md` (how the recognisers fit together), `BIASING.md` (biasing: results, research, plan), `pipeline/` (design notes from earshot-data) |
| `models/` | The fine-tuned Whisper model (`ggml-ems-small.en-ft-f16.bin`, in git via LFS); other model files are not in git |

## Set up on a Mac (Apple silicon)

```bash
brew install whisper-cpp opus
```

The Whisper model is in git through LFS (`git lfs pull`). Without LFS, fetch it from the private
Hugging Face repo; the script checks its sha256:

```bash
HF_TOKEN=... core/scripts/fetch_model.sh
```

```bash
cd core && swift build -c release && swift test
```

If Homebrew's whisper.cpp cannot find `ggml.h` (newer Homebrew ships ggml as its own formula), add
`-Xcc -I/opt/homebrew/opt/ggml/include -Xlinker -L/opt/homebrew/opt/ggml/lib` to both commands.

Run the pipeline on a WAV, on the GPU (Metal):

```bash
core/.build/release/earshot-eval run call.wav --gpu --out out/call
```

`--gpu` is much faster than the CPU. Its results can differ slightly from CPU runs, so compare runs
made the same way. `core/.build/release/earshot-eval help` lists every option.

On Linux, `core/scripts/setup_linux.sh` installs Swift and whisper.cpp instead of `brew`.

## Checks

```bash
cd firmware && make test
```

```bash
cd core && swift test
```

```bash
core/scripts/e2e_firmware.sh
```

The last one plays the firmware simulator's built-in voice through Opus, the live pipeline and
Whisper (needs `models/ggml-base.en.bin`, PlatformIO's Opus sources and `pip install websockets`).

## Where things stand

- Pipeline: imported from earshot-data, reads the real clip firmware's protocol, tested end to end
  against the firmware simulator.
- Hybrid: Apple's live recogniser cross-checks Whisper; an optional language model is held to the
  transcript; nothing requires Apple Intelligence.
- Biasing and confidence flags: built and measured; next steps in `docs/BIASING.md`.
- App: wired to the pipeline but **never compiled** (written without Xcode). Run
  `app/scripts/fetch_deps.sh` on a Mac to build whisper.cpp for iOS and regenerate the Xcode project.
- Bluetooth in the app: `app/Earshot/ClipLink.swift`; its decoded audio goes to `app/Earshot/Pipeline/CallEngine.swift`.
