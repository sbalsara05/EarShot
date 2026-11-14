# Earshot

EMS edge scribe (working name). A clip on the medic records the call; the iPad writes the chart.

| Folder | What is in it |
|---|---|
| `firmware/` | The clip: button, consent, Opus audio over Bluetooth or Wi-Fi, plus a laptop simulator |
| `app/` | The iPhone and iPad app |
| `core/` | The transcription pipeline (Swift package EarshotCore): Whisper, rules, chart/SOAP/NEMSIS, and its tests. Used by the app and by `earshot-eval` |
| `shared/` | The EMS dictionary and formulary the pipeline reads |
| `docs/HYBRID.md` | How the two recognisers and the optional language model fit together |
| `docs/pipeline/` | Pipeline design notes, carried over from earshot-data |

Quick checks on a laptop:

```bash
cd firmware && make test
```

```bash
cd core && swift test
```

```bash
core/scripts/e2e_firmware.sh
```
