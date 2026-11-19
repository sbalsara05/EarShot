# Soundtrack brief (version 3, the one in `mix.wav`)

This is the brief the soundtrack was built from, written up after the fact from the direction given during the edit. The exact wording of the original prompt was not kept.

## Direction from the team
- Earlier versions were rejected: the first sounded like "elevator music" with stock swishes and typing; the second had a piano line that was "chaotic" and did not follow a real harmonic cadence.
- For this version: "make sure it interacts with the Foley well", and "go synthetic, mostly ambient, something that's easy to voice over."
- The film is narrated live, so the voice is the lead instrument.

## What to build
1. **A fully synthetic ambient bed.** No drums, no piano, no melodic line. A slow pad on one progression (Dm, Bb, F, C) with proper voice leading: shared notes held, small moves between chords, cadences at section ends.
2. **Room for a voice.** Cut the bed in the speech range (about 300 Hz to 4 kHz) by roughly 10 dB. Keep level changes slow. Bed loudness around -20 to -22 LUFS.
3. **Interaction with the sound effects (Foley).**
   - Duck the bed under each effect (a few dB, fast attack, about 300 ms release), deeper under the two big hits.
   - Answer the effects musically: a filter bloom after the connect tones, a faint shimmer after each mark, a small lift with each of the four document locks.
   - Send bed and effects to one shared short room so they sit in the same space; keep the effects send low so clicks stay crisp.
4. **Shape by intensity, following the film.** Near silence for the first 10 s; the pad fades in to 0:20; a swell into the 35% hit at 0:38; steady through the marks; thinner for the report section from 0:56; warmth back for the signature; the largest swell into 1:30, a breath of silence, then the deepest bloom; a short resolving figure on the end card at 1:32.
5. **Keep the sound effects real.** Use the CC0 samples (see `LICENSES.md`) for clicks, taps and typing; only the music is synthesised.

## Fixed timings (see `HITMAP.md` for the full list)
- 0:38.0 the 35% hit
- 0:44.0 and 0:48.0 clip presses; 0:44.33 and 0:48.33 the marks landing
- 1:26 to 1:29 the four document locks
- 1:30.0 the impact; 1:32.0 the end-card figure

## Deliverables and checks
- `music.wav`, `sfx_only.wav`, `mix.wav` (98.000 s, 48 kHz stereo) and an MP3 preview.
- Every listed hit within 15 ms of its time; true peak under -1 dBTP; every pitched note a chord tone, with no clashing semitones.
- Measured result for this version: mix -19.7 LUFS, -1.8 dBTP; speech band 19 dB below the low end of the bed.
