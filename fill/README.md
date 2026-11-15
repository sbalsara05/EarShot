# Fill

Reads a call's transcript and fills its NEMSIS report, on the device, with a small language model.
Also writes the report as NEMSIS 3.5.1 XML.

```
transcript ──┬─ who          patient, history
             ├─ what         complaint, scene, destination, times
             ├─ vitals       every reading said
             ├─ medicines    what the crew gave
             └─ procedures   what the crew did
                    │
             check each item          was it really said, on the line it cites?
                    │
             merge and de-dupe ──► answers ──► narrative ──► XML
```

**The model only proposes. Code decides.** A wrong value in a patient record is worse than an empty one.

## Set up

Run once. It builds llama.cpp (about ten minutes) and downloads the model (2.7 GB). Needs Xcode and cmake.

```bash
./fetch.sh
```

## How an answer earns its place

| Step | What it does |
|---|---|
| Numbers first | Spoken numbers become digits by rule before the model sees them: "one fifty eight over ninety two" is "158 over 92" |
| Five short questions | Each asks for a few fields and shows one worked example. One big question was too much for a model this size |
| Grammar | The answer must be JSON of the right shape; a number field can only hold a number, a choice only one of its choices |
| A line for every item | Each item names the transcript line it came from |
| Checks | A number must be said on that line (or the one beside it) and be in range. A vital sign's line must say what was measured. A drug, a route and a unit must be said. A time's own line must say so |
| Merge | Readings become sets of vitals. The same thing said twice is one entry. Lists said in two places are joined. Two answers that disagree are both kept, and marked |
| Marked "check" | Anything from a line the recogniser doubted, any conclusion (impression, procedure name), any corrected drug name, and the narrative |

What the checks drop is left empty for the medic. `fill-transcript --dropped` lists each one and why.

## Measured

Qwen3.5 4B, 4-bit (2.7 GB), on a Mac with the GPU. `Truth/` holds each transcript and its right answers.

| Transcript | Right | Wrong | Missing | Time |
|---|---|---|---|---|
| Demo call, 14 lines | 42 of 43 | 0 | 1 | 31 s |
| Demo call, garbled the way Whisper garbles | 43 of 43 | 0 | 0 | 32 s |
| The Feather's stored voice, 3 lines | 13 of 13 | 0 | 0 | 16 s |
| A real recording from the iPad's microphone, 47 lines | 6 of 7 | 0 | 1 | 24 s |

Qwen3 4B Instruct scored lower on the same set (35 of 43 on the demo call, and it cited the wrong line more
often). MedGemma and Phi-4-mini were not tried.

Four transcripts is a small set. It shows the method works; it does not show how often a wrong value gets through
on real calls.

`Truth/full.m4a` is `Truth/full.txt` spoken aloud by two ElevenLabs voices, a medic and a patient (2 min 32 s), to play to an iPad and
try the whole path from sound to report. Its pauses are seconds long where the real call's would be minutes.

```bash
swift run -c release fill-transcript Models/Qwen3.5-4B-Q4_K_M.gguf Truth/demo.txt --score Truth/demo.json --dropped
```

```bash
swift test
```

The tests need no model: a scripted stand-in plays the model's part. One test runs the national schema
(`Tests/FillTests/nemsis_xsd`) over the XML with `xmllint`.

## The XML

`NemsisXML.write` gives an `EMSDataSet` that passes the NEMSIS 3.5.1 schema. A field with no answer is written as
"not recorded". A few elements may not be empty in NEMSIS (agency, unit, dispatch reason, two times): where the
crew has set none, a stand-in is written and listed in a comment at the top of the file.

## Where things are

| File | What is in it |
|---|---|
| `Sources/Fill/Fields.swift` | The report's shape: sections, fields, and what kind of answer each takes |
| `Sources/Fill/Fill.swift` | The five questions and their grammars, the checks, the merge, the narrative |
| `Sources/Fill/Words.swift` | Spoken numbers to digits, and whether a word was really said |
| `Sources/Fill/Llama.swift` | The model, through llama.cpp. Shourya Yadav's `LlamaEngine`, with GPU support and a kept state |
| `Sources/Fill/NemsisXML.swift` | The report as NEMSIS XML |
| `Sources/fill-transcript` | The Mac tool |

## Not built yet

- **Codes.** NEMSIS wants codes where the report holds words: impression and symptom (ICD-10), procedure (SNOMED),
  allergies and home medicines (RxNorm), city (GNIS). Only ten drugs have a code here, and those codes have not
  been checked against RxNav. The rest go out as "not recorded"; their words are in the narrative.
- **Business rules.** The XML is checked against the schema, not the national Schematron or any state's rules.
- **Long calls.** A transcript over about 14,000 characters is read in overlapping stretches; that path has not
  been measured.
- **More fields.** Date of birth, alcohol and drug use, transport disposition, acuity and the reason for the
  destination are left to the medic.
