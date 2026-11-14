# Pipeline ready — earshot-eval

Repo/branch: `shourya0523/earshot-data` @ `overnight`. Status: **stock pipeline works end to end on Linux** (whisper.cpp `small.en` + rules-v1). Tested on Ubuntu 24.04, Swift 6.2.1.

## Build

```bash
core/scripts/setup_linux.sh          # Swift 6.2.1, whisper.cpp (pkg-config "whisper"), models/ggml-small.en.bin
cd core && swift build -c release    # binary: core/.build/release/earshot-eval
```
- whisper.cpp installed elsewhere: `export PKG_CONFIG_PATH=<prefix>/lib/pkgconfig LD_LIBRARY_PATH=<prefix>/lib`.
- macOS: `brew install whisper-cpp`, then `swift build -c release`.
- No whisper at all: `EARSHOT_NO_WHISPER=1 swift build` (transcript `.json` input only).
- Tests: `swift test`.

## Run

```bash
B=core/.build/release/earshot-eval
$B run call.wav --taps taps.json --asr-model models/ggml-small.en.bin --out out/call1          # stock
$B run call.wav --taps taps.json --asr-model models/whisper-ems-small.en-q5.bin --out out/ft     # fine-tuned slot
$B run transcript.json --taps taps.json --out out/text_only    # skip ASR: test extraction alone
$B make-replay call.wav call.replay --taps taps.json           # wav -> replay packet file
$B run call.replay --asr-model models/ggml-small.en.bin        # replay input (packets, taps inside)
$B check-stream capture.replay                                 # clip capture vs docs/FIRMWARE_CONTRACT.md (exit 1 on failure)
$B fake-clip --port 7070 --wav call.wav --taps taps.json       # reference clip over TCP (Wi-Fi framing) for app/bring-up tests
```
Demo: `$B run mocks/demo_call/transcript.truth.json --taps mocks/demo_call/taps.json --start 2026-11-15T14:00:00-05:00 --out out/demo`.
Demo replay (contract-conformant stream; arrival/handoff are tablet taps): `$B run mocks/demo_call/demo_call.replay --taps mocks/demo_call/tablet_taps.json --start 2026-11-15T14:00:00-05:00 --asr-model models/ggml-small.en.bin`.

## Inputs
| Input | Format |
|---|---|
| audio | `.wav` — 16 kHz mono 16-bit preferred; other rates/channels/float32 are converted in memory |
| replay | `.replay`/`.bin` — length-prefixed packets (`docs/WIRE_FORMAT.md`) |
| transcript | `.json` — `[{"start_ms":0,"end_ms":2000,"text":"..."}]` or a previous `transcript.raw.json` |
| taps | `[{"clip_ms":52500,"source":"button","gesture":"mark"}]`; source `button|tablet` (older tap files with `knock`/`snap` still load and are treated like any tap); gesture `mark` (default) `yes|no|arrival|handoff`. `clip_ms` = ms from audio start (wav/json) or clip-boot ms (replay) |
| config (`--config`) | `{"call_id":"c1","start_time":"2026-11-15T14:00:00-05:00","asr":{"model":"...","threads":4,"use_initial_prompt":true,"prompt":null,"beam_size":5,"temperature_fallback":true},"tagger":null,"vad":{"mode":"energy"\|"fixed","startDb":6,"hangoverMs":700,"maxSegmentMs":25000},"merge":{"windowMs":3000,"extendedMs":10000},"pii_scrub":false,"agency":{"stateId":"…","number":"…","stateCode":"25","vehicle":"…","callSign":"…"}}` — all optional |

Flags: `--asr-model <path>`, `--beam <n>` (default 5, with temperature fallback), `--greedy` (beam 1, no fallback: fastest), `--prompt-file <f>` (override the initial prompt; default is the sentence-style prompt in `shared/ems_terms.json` → `initial_prompt`), `--tagger <path|none>` (Core ML, macOS only; on Linux it's ignored with a note in timing.json), `--threads`, `--call-id`, `--start`, `--dict <dir>` (default: finds `shared/`), `--no-prompt`, `--pii-scrub` (off by default: PII is kept).

## Outputs (in `--out`)
| File | Contents |
|---|---|
| `transcript.raw.json` | `{call_id, asr_model, initial_prompt, segments:[{id:"s1",start_ms,end_ms,text,avg_logprob,word_times:[[char_offset, ms], …]}]}` — never edited. `start_ms`/`end_ms` come from whisper token timestamps (first/last token), not the VAD chunk; finding times use `word_times`. |
| `transcript.clean.json` | `{segments:[{raw_span,text}], corrections:[{id,raw_span,raw_range:[a,b],original,replacement,rule}]}` |
| `events.json` | event list (format below) |
| `soap.md`, `chart.md`, `imist_ambo.md` | rendered by code; every line cites `[eN]`; missing = "not heard" |
| `nemsis.xml` | NEMSIS v3.5.1 EMSDataSet, **passes the XSD** (xmllint); eTimes.11/12, eVitals, eMedications (RxNorm + route/unit codes), eProcedures (no SNOMED yet); schema-required unknowns listed in a `REQUIRES CREW ENTRY` comment |
| `timing.json` | seconds per stage (vad, asr_total, cleanup, extract_rules, merge, pii, render), stats, model names |

Event: `{"id","call_id","time"(ISO),"t_ms","type","fields","source","quote","raw_span","confidence","models":{"asr","extract"},"receipts":{field:{"raw_span","quote","raw_range","inferred"?}},"flags":["confirm"|"inferred"|"unlabeled"],"tap_source","tap_clip_ms"}`.
Types: vitals, medication, procedure, status, dispatch, transport, tap, consent, arrival, handoff, audio_gap.
- `status.fields.kind` ∈ `finding` (crew observation, value in `term`: "facial droop", "pale, cool and diaphoretic", "last known well 16:15", "tourniquet time 02:34"), `condition` (value in `condition`: "compensating", "stable"), `symptom` (`symptom`), `patient` (`age`, `sex`, `weight_kg`), `allergy`, `history`, `home_med`, `prior_to_arrival_med`, `med_not_given`, `drug_mention`, `not_done`. **For the status scorer, map only `finding` → term, `condition` → term, and vitals `mental_status`; the other kinds are not "status terms".**
- Heard times: `transport` events with `fields.kind` = `on_scene` (eTimes.06), `departed` (eTimes.09), `back_in_service` (eTimes.13), each with `fields.etime`; arrival/transfer of care become `arrival` / `handoff` events (`method`: tap, tap + heard, heard, nurse accept). Time = start of the utterance. Plain `transport` events (destination/mode/alert/eta) have no `kind`.
- Dispatch: `fields.dispatch_reason`, `fields.found`, `fields.chief_complaint` (not `text`).
Vitals field names: `bp_systolic bp_diastolic bp_method heart_rate resp_rate spo2 etco2 glucose gcs temp pain mental_status pupils o2_on` (`mental_status` = "A&O×4"; rhythm names are not extracted: they are interpretations, and "afib" is a diagnosis trap). Medication: routes include device routes for oxygen (`NRB`, `NC`, `BVM`, `CPAP`, `BLOWBY`). `drug`(generic) `dose unit route drug_as_heard unit_suggested` — `unit` only when spoken; `unit_suggested` is the protocol unit when unspoken (not a heard value, don't score it as one).

**Prompt is format-only and frozen** (see `docs/PROMPT_PRIMING.md`): vocabulary and style, no realistic values. The Kaggle fine-tune trains with it, so it must not change without retraining (pinned by `PromptFreezeTests`). Check outputs for copied prompt values with `core/tools/prompt_copy_check.py`; compare models with `--no-prompt` as well.

Determinism: same input + config + threads ⇒ same files, except `timing.json`.

Clock: `--start` wins; else a replay's clock-sync packet; else an assumed start of 2026-11-15T14:00:00-05:00 that is flagged at the top of every output and as `clock: assumed` in `timing.json` notes. **Pass `--start` for scoring times.**

Consent: if the tap file has `yes`/`no`/`stop` gestures, only audio from a `yes` to the next `stop` is transcribed and a `no` captures nothing. With no consent gestures, everything counts.

Changes since first hand-off (review fixes): unit never filled when unspoken (`unit_suggested` instead); `route_as_heard` when the route came from a word like "chewed"; diagnosis terms never become field values; NEMSIS validates against the v3.5.1 XSD; VAD is noise-adaptive (`vad.mode: "fixed"` to skip VAD); PII kept by default (`--pii-scrub` to tokenize).

## Known gaps
- Word times inside a segment are proportional estimates (no token timestamps yet).
- Free-text fields (dispatch, chief complaint, destination, allergy, history) are raw quotes ≤5 words.
- Procedures have no SNOMED codes (eProcedures.03 = Not Recorded). NEMSIS passes the XSD, not Schematron/state rules.
- `mocks/demo_call/demo_call.replay` is committed; to regenerate: `python3 core/tools/make_demo_call.py /tmp/demo.wav mocks/demo_call && $B make-replay /tmp/demo.wav mocks/demo_call/demo_call.replay --taps mocks/demo_call/taps.json` (needs espeak-ng, ffmpeg).
- Performance: 166 s demo audio → 51 s ASR on 4 x86 threads (small.en, CPU).

Report bugs in `docs/REVIEW.md`.
