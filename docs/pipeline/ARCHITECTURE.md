# Earshot architecture

```
 clip (ESP32-S3)                         iPad (EarshotCore + thin SwiftUI)
 ───────────────                         ──────────────────────────────────────────────────────────
 mic ────────────────► state machine    PacketSource (BLE | Wi-Fi | Replay)
   │                     (consent)            │
   └► ADPCM ─► [LISTENING only] ─────────►  AudioAssembler: reorder by seq, dedupe, gaps → audio_gap
 button ─► gestures ─► tap packets ──────►    │ taps → PlacedTap (clip time → call time)
                       resent until ack ◄─ ack │
 clock offset ◄──────────────────────────  clock
                                              ▼
                                         PCMRingBuffer (RAM only)  ──►  EnergyVAD (adaptive floor)
                                              ▼                             ▼ speech chunk
                                         whisper.cpp small.en (initial prompt from EMS dictionary)
                                              ▼ chunk freed right after transcription
                                         RawSegment s1..sN  (never edited: source of truth)
                                              ▼
                                         Cleanup (numbers, spelled abbreviations, ASR drug variants,
                                                  units, non-speech tags) → Corrections linked to raw ranges
                                              ▼
                                         RulesExtractor (vitals, meds + dose/unit/route, procedures,
                                                  status/symptoms/history/allergies, patient, dispatch vs found,
                                                  transport/arrival) + optional EMSTagger (formulary decides)
                                              ▼ Findings with per-field receipts (raw span + exact quote)
                                  ┌──────── Phi: RECOVERY (optional) ─────┐
           raw + rules findings ─►│ proposes values the rules missed,      │─► VERIFIER ─► accepted → findings (flag llm)
            (windows of 8 segs)   │ each with span + verbatim quote        │             rejected → "please confirm" / logged
                                  └────────────────────────────────────────┘
                                              ▼
                                         TapMerger (tap time wins; ±3 s, +10 s forward; global assignment)
                                              ▼
                                         Events  ──► ChartModel ──► SOAP · CHART · IMIST-AMBO · NEMSIS XML
                                              │                      (code-rendered; "not heard"; [eN] receipts)
                                              ├► Phi: NARRATIVE (optional): cited sentences ─► CHECKER ─► passes → CHART narrative + eNarrative.01
                                              │                                                        fails  → template narrative (as before)
                                              └► encrypted CallStore (wiped at sign) · Ledger (audio sent: 0)
```

## Packages
- `core/` — `EarshotCore` (Foundation only; builds on Linux and Apple; `LLM/` holds the `LLMEngine` slot, the recovery verifier and the narrative checker), `EarshotWhisper` (whisper.cpp C API), `EarshotLLM` (llama.cpp C API, Phi-3.5-mini; `EARSHOT_NO_LLAMA=1` builds without), `earshot-eval` (CLI: run, make-replay, check-stream, fake-clip).
- `app/` — XcodeGen project; barebones pipeline test screen + transports (CoreBluetooth, Network.framework), CallStore (CryptoKit), Geofence (CoreLocation), Foundation Models tap suggestions.
- `firmware/common/` — portable C for the clip contract; board code is owned elsewhere.
- `shared/` — `formulary.json`, `ems_terms.json` (built by `core/tools/build_dictionary.py`).

## Product rules in code
| Rule | Where |
|---|---|
| Consent first | firmware state machine gates audio; `Consent.windows/gate` (batch) and `LiveSession` (live) ignore audio outside yes→stop; a `no` captures nothing |
| Audio stays in memory | `PCMRingBuffer`, chunk freed after ASR; `ReplayFile.write` compiled out of iOS; `Ledger.audioBytesSent == 0` |
| Every field has a receipt | `FieldReceipt` per field (raw span, exact raw quote, char range); unspoken units are never filled (`unit_suggested`) |
| A human signs | outputs are drafts; medic entries are `source: tablet`, `entered_by: medic`; sign wipes the store |
| Documentation only | `Diagnosis` deny-list keeps diagnostic words out of fields; condition words are the medic's own; no advice anywhere |
| The model only proposes | Phi (optional, off by default) never writes a field or XML: `RecoveryVerifier` accepts a value only if its span is real, its quote is verbatim in that span, the value is in the quote after cleanup, any drug is in the formulary and the value is in range; `NarrativeChecker` passes prose only if every sentence cites real events and every number, drug, unit and route in it is in those events. Both pass `Diagnosis.contains()` |

## Determinism
Greedy whisper decoding (temperature 0, no fallback), greedy grammar-constrained Phi decoding on CPU (fixed seed, context 4096), fixed threads, sorted dictionary iteration, stable event ordering → same input + config ⇒ same files (except `timing.json`). Golden files per renderer in `core/Tests/EarshotCoreTests/Fixtures/golden`.
