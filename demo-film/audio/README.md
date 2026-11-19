# Earshot demo film: v3 soundtrack (synthetic ambient bed + Foley)

v2 is left untouched in `../v2` for comparison. v3 has the same 98.0 s length, the same HITMAP timing, the same harmony and the same output names.

## Build
    ./build.sh     # sfx -> music (ducked by the sfx) -> mix -> harmony check -> checks (about 1 minute)

Outputs:
- `music.wav`: the bed plus its share of the shared room, about -20 LUFS.
- `sfx_only.wav`: the Foley, dry plus its share of the same room.
- `mix.wav`, `mix_preview.mp3`.
- `check_report.txt`, `harmony_report.txt`, `mix_spectrogram.png` (linear frequency axis, 0–8 kHz).

## What the bed is
Everything is synthesised in numpy. There are no drums, piano or marimba.
- **Pad:** three voice-led lanes (detuned saws plus a triangle) with glides of about 180 ms on chord changes; shared tones are held.
- **Filter:** a moving 4-pole low-pass.
- **Breathing:** a soft level pulse in quarters or 8ths on the 120 bpm grid.
- **Movement:** slow stereo drift.
- **Low end:** a sine sub drone on the chord root, plus sub "blooms" at 38.0 and 90.0.
- **Air and shimmer:** high noise air above 5.5 kHz, and faint shimmer above 5 kHz after the marks.
- **Speech band:** a zero-phase EQ dips 330 Hz–3.8 kHz by 10 dB.

Harmony is the v2 progression: Dm – Bb – F – C, two bars per chord. Cadences go through A into Dm at 20.0, 38.0 and 90.0, and the sting is Bb – C – D major from 92.0. Bar → chord is `BARS` in `src/music.py`.

Sections are keyframe tables in `src/music.py`: `PAD_DB`, `CUT` (filter cutoff), `SUB_DB`, `AIR_DB`, `BREATH`.

## How the bed works with the Foley
- **Sidechain:** the bed ducks 3.5 dB (15 ms attack, 300 ms release), keyed from the dry Foley. It ducks 6 dB for the first 150 ms of the 38.0 and 90.0 hits. See `duck_curve()`.
- **Answers to the Foley:**
  - The filter blooms after the connect tones (14.0, 84.8).
  - A faint shimmer follows each mark (44.33, 48.33).
  - The pad brightens and rises 0.8 dB with each of the four document locks (86–89).
  - The bed lifts, then settles onto F as the 80.0 confirm lands.
- **Shared room:** the bed and the Foley go to one short, soft room (`room()` in `src/mix.py`). The Foley send is low so clicks stay crisp.
- **Foley levels:** clicks and taps about -15 dBFS peak, tonal accents about -16, typing about -24, hits -9 and -7. The tonal accents are still chord tones of the chord under them (checked by `harmony.py`).

Sample sources and licences for the Foley: `LICENSES.md`. `samples` is a symlink to `../v2/samples`.
