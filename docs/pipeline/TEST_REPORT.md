# Earshot pipeline: test report

*Stock speech model (Whisper small.en). No fine-tuned model is included in these results.*

## The short version

- **When Earshot hears a value, it gets it right.** Almost everything it writes down is correct (precision 86–100%), and it invents nothing: no field without a matching quote, no diagnosis words in any output.
- **When the transcript is correct, extraction is near-perfect.** Fed the true words of each call, it scores 92–100% on drugs, doses, routes and vitals.
- **On noisy audio, it misses things.** Half or more of the vitals are found (43–75%, depending on the vital), because the speech model mishears them. That's the problem the fine-tuned model is meant to fix.
- **The records are valid.** Every NEMSIS export passes the official v3.5.1 schema.
- **Not tested yet:** real human voices on the real clip, the iPad app on a device, and the Bluetooth link.

## What was tested

| Test | What it shows | Who ran it |
|---|---|---|
| 1. Full pipeline on noisy audio | Real-world accuracy, speech model included | Data agent |
| 2. Extraction on correct transcripts | How good the rules are when the hearing is perfect | Pipeline agent, using the data agent's scorer |
| 3. End-to-end demo and fake clip | That every part connects and runs | Pipeline agent |
| 4. Automated tests | That nothing breaks when code changes | Run on every change |

The test calls are 10 scripted EMS calls (about 24 minutes in total): synthetic voices with ambulance cab, road, siren and monitor noise mixed in, and taps on the clip. Each call has an answer key listing every value that was said.

## 1. Full pipeline on noisy audio

"10 dB" is typical ambulance noise; "5 dB" is very loud.

### How well it hears

| Noise | Words wrong | Drug names wrong |
|---|---|---|
| Light (15 dB) | 12.5% | 30.8% |
| Typical (10 dB) | 14.7% | 30.8% |
| Loud (5 dB) | 20.8% | 38.5% |

The goal is under 15% of drug names wrong. Stock Whisper is at about 31–38% on these calls (and 41% on real clinician speech), which is why a fine-tuned model is being trained.

### How much of what was said it captured (typical noise, 10 dB)

| What | Captured (recall) | Of what it wrote, correct (precision) |
|---|---|---|
| Drug given | 77% | 94% |
| Dose | 73% | 100% |
| Unit | 64% | 100% |
| Route | 68% | 100% |
| Blood pressure | 75% | 86% |
| Heart rate | 75% | 100% |
| Breathing rate | 43% | 100% |
| Oxygen saturation | 50% | 100% |
| Blood glucose | 57% | 100% |
| GCS | 100% | 100% |
| Pain score | 100% | 100% |
| Procedures | 79% | 73% |

### Other checks (all three noise levels)

| Check | Result |
|---|---|
| Fields without a matching quote (made-up values) | **0** |
| Diagnosis words in any output | **0** |
| NEMSIS exports valid against the schema | **10 / 10** |
| Taps labelled correctly | 70–72% |
| Event time error (90% of events within) | 4.2–4.9 s |
| Key facts found in SOAP / CHART / IMIST / NEMSIS | 76% / 76% / 75% / 71% |
| Speed (laptop CPU, not an iPad) | ~0.7× real time |

### Progress across review rounds (typical noise)

| Version | Words wrong | Made-up values | Taps labelled |
|---|---|---|---|
| Earlier (greedy decoding) | 23.3% | 3.7% | 64% |
| Latest scored (beam search, better prompt, word timing) | **14.7%** | **0** | **70%** |

Oxygen-saturation recall fell in the latest scored version: Whisper started hearing "sat 95" as "set 95". That is fixed in the newest code, which hasn't been re-scored on audio yet.

## 2. Extraction on correct transcripts

Here the true transcript is fed in instead of the speech model, so this measures only Earshot's own rules. Two sets were used: the 10 test calls, plus 10 separate practice calls the rules were not tuned on.

| What | Test calls | Practice calls |
|---|---|---|
| Drug | 93% | 98% |
| Dose | 93% | 100% |
| Unit | 95% | 94% |
| Route | 92% | 98% |
| Procedures | 97% | 87% |
| Patient status (findings, condition) | 89% | not scored |
| Vitals (BP, breathing, SpO₂, glucose, GCS, pain) | 100% | 100% |
| Heart rate | 100% | 92% |
| Taps labelled correctly | 98% | 100% |
| Made-up values | 0.5% | 0 |
| Key facts found in all four outputs | 100% | 100% |
| Diagnosis words in outputs | 0 | 0 |

Scores are F1 (a balance of "found it" and "got it right").

**What this means:** the rules meet every target the data agent set. The audio gap in section 1 comes from the speech model, not from the rules.

## 3. End-to-end checks

| Check | Result |
|---|---|
| Demo call (166 s), clean audio | All 14 sentences transcribed; correct outputs; valid NEMSIS |
| Demo call with ambulance-level noise | All 14 sentences still picked up |
| Beam search vs fastest setting | ~16% fewer word errors, ~28% more time (65 s vs 50 s for the call) |
| Sentence start times | Within 0.7 s of the real start (median), 2.1 s worst |
| Simulated clip over Wi-Fi → recorded → checked → processed | Passes all 9 clip-contract checks; all 8 taps acknowledged; 0% audio loss at 68.4 kbps; valid NEMSIS |

## 4. Automated tests

| Suite | Result |
|---|---|
| Pipeline (`swift test`) | **77 / 77 pass**: wire format, audio, noise detection, extraction, tap merging, outputs, NEMSIS schema, live session, and one test per issue found in review |
| Clip shared code (`make -C firmware/common/test`) | **231 / 231 pass**: consent rules and button gestures, tap resend until acknowledged, audio compression matching the iPad byte for byte |

## Product rules: are they kept?

| Rule | Status |
|---|---|
| Consent first: nothing captured before "yes"; a "no" captures nothing | Enforced in the clip contract and the pipeline; tested |
| Audio stays in memory | Audio is never written to disk by the pipeline; the app's ledger shows 0 bytes sent |
| Every field has a receipt | 0 made-up values on audio; units not spoken are left blank |
| A human signs | Outputs are drafts; medic entries are labelled as the medic's |
| Documentation only, no diagnosis | 0 diagnosis words in any output across all runs |

## Not tested yet

1. **The newest fixes on audio:** "set 95" read as oxygen saturation, music-note dropouts, "Now we're breather" read as non-rebreather.
2. **Real human voices** through the full pipeline. Real speech has only been used to compare speech models; there is no answer key for it.
3. **Calls recorded on the actual clip** (Atom VoiceS3R).
4. **The iPad app:** it has never been built (there was no Xcode in this environment).
5. **The Bluetooth link** between clip and iPad.

## Next steps

1. Re-score the newest code on the noisy test calls.
2. Plug in the fine-tuned speech model once it beats stock on these same calls. No code change is needed.
3. Record the 10 test calls on the real clip and score them.
4. Build the iPad app and run the Bluetooth throughput test.

*Sources: `eval/REPORT.md` and `docs/REVIEW.md` (data agent), `core/Tests`, `firmware/common/test`.*
