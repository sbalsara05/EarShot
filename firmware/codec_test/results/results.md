# Compression vs transcript accuracy

Speech: 96 utterances: macOS voices Samantha, Daniel, Karen, Moira reading a 24-line EMS script.
Recognizer: Whisper `base.en`. Budget: 8,000 bytes per second.

Word error rate (WER) is the share of words the recognizer got wrong: lower is better.
"Change" is the difference from raw audio in the same pass, in percentage points.
Noise is simulated ambulance noise (engine rumble, hiss and a siren); the dB figure is how
much louder the speech is than the noise, so 5 dB is the harsher case.

| Audio sent | Bytes/s | Fits budget | WER, clean | Change | WER, noise at 10 dB | Change | WER, noise at 5 dB | Change |
|---|---|---|---|---|---|---|---|---|
| Raw audio (today) | 32,000 | no | 1.5% | baseline | 3.0% | baseline | 3.2% | baseline |
| Opus 48 kbit/s | 6,005 | yes | 1.2% | -0.2 | 3.4% | +0.4 | 3.3% | +0.1 |
| Opus 32 kbit/s | 4,003 | yes | 3.7% | +2.2 | 3.0% | +0.0 | 3.8% | +0.5 |
| Opus 24 kbit/s | 3,003 | yes | 2.2% | +0.7 | 2.8% | -0.2 | 4.2% | +1.0 |
| Opus 16 kbit/s | 2,002 | yes | 2.0% | +0.5 | 3.6% | +0.6 | 5.0% | +1.8 |
| Opus 12 kbit/s | 1,501 | yes | 2.2% | +0.8 | 4.8% | +1.8 | 7.9% | +4.7 |
| Opus 8 kbit/s | 1,001 | yes | 2.8% | +1.2 | 7.6% | +4.6 | 15.1% | +11.8 |
| ADPCM 4:1 | 8,053 | no | 1.9% | +0.4 | 2.9% | -0.1 | 3.1% | -0.2 |
| 8 kHz sampling, uncompressed | 16,000 | no | 1.7% | +0.2 | 4.2% | +1.3 | 5.2% | +2.0 |
| 8 kHz sampling + ADPCM | 4,040 | yes | 2.3% | +0.8 | 4.2% | +1.2 | 6.1% | +2.8 |
| Opus 32 kbit/s, 5% of chunks lost | 4,003 | yes | 1.4% | -0.1 | 3.0% | +0.0 | 4.6% | +1.3 |

Each cell is 1,200 words. One example of every condition is in `samples/` to listen to.

## Note on one figure

The 3.7% for Opus 32 kbit/s on clean audio is a one-off recognizer glitch, not an effect of the
compression. Re-running that cell clip by clip gave 17 errors in 1,200 words (1.4%) against 18 for
raw audio, and the "5% of chunks lost" row, which uses the same Opus 32 audio, scored 1.4% too.
Whisper's fallback decoding is not perfectly repeatable; the script now disables it. Treat
differences of under about one point between any two cells as a tie.
