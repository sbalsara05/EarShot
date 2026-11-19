"""Harmony verification (nobody can listen): bar-by-bar table of every pitched note (music + tonal sfx) vs the chord,
asserts 100% chord tones on strong beats, no simultaneous minor seconds between any sounding notes, and ostinato leaps <= a fifth."""
import json, sys
from lib import V2
NAMES = ['C', 'C#', 'D', 'Eb', 'E', 'F', 'F#', 'G', 'G#', 'A', 'Bb', 'B']
CH = {'Dm': [2, 5, 9], 'Bb': [10, 2, 5], 'F': [5, 9, 0], 'C': [0, 4, 7], 'A': [9, 1, 4], 'D': [2, 6, 9]}
mj = json.load(open(V2 + '/src/.music_notes.json')); sj = json.load(open(V2 + '/src/.sfx_notes.json'))
BARS = mj['bars']
def chord_at(t):
    if 92.0 <= t < 92.5: return 'Bb'
    if 92.5 <= t < 93.0: return 'C'
    return BARS[min(int(t // 2.0), len(BARS) - 1)]
notes = [tuple(n) for n in mj['notes']] + [(t, m, d, 'sfx:' + l) for t, m, d, l in sj]
notes = [n for n in notes if n[0] < 97.5]
nm = lambda m: f'{NAMES[m % 12]}{m // 12 - 1}'
out = []; P = lambda s: (print(s), out.append(s))
fails = []; strong_total = strong_ok = all_ok = 0
P('| bar | time | chord | notes (onset step: note layer, * = not a chord tone) | strong-beat chord tones |'); P('|---|---|---|---|---|')
for bar in range(49):
    t0 = bar * 2.0; ns = sorted(n for n in notes if t0 <= n[0] < t0 + 2.0)
    if not ns: continue
    cells = []; s_ok = s_tot = 0
    for t, m, d, l in ns:
        c = chord_at(t); ok = (m % 12) in CH[c]; all_ok += ok
        step = (t - t0) / 0.125; strong = abs(step - round(step)) < 0.1 and round(step) % 4 == 0
        if strong: s_tot += 1; s_ok += ok
        if strong and not ok: fails.append(f'non-chord tone on strong beat: {t:.3f} {nm(m)} {l} over {c}')
        cells.append(f'{step:.0f}:{nm(m)}{"" if ok else "*"} {l[:3]}')
    strong_total += s_tot; strong_ok += s_ok
    chords = '/'.join(dict.fromkeys(chord_at(t0 + x * 0.5) for x in range(4)))
    P(f'| {bar} | {t0:.1f} | {chords} | {", ".join(cells)} | {s_ok}/{s_tot} |')
# simultaneous minor seconds (any two notes overlapping in time, from any layers)
ns = sorted(notes)
for i, a in enumerate(ns):
    for b in ns[i + 1:]:
        if b[0] >= a[0] + a[2]: break
        if (a[1] - b[1]) % 12 in (1, 11) and b[0] < a[0] + a[2] - 0.01:
            fails.append(f'minor 2nd: {nm(a[1])} {a[3]} @{a[0]:.2f}+{a[2]:.2f} vs {nm(b[1])} {b[3]} @{b[0]:.2f}')
# ostinato voice-leading: consecutive marimba notes (base layer, not octave doubles) within a fifth
mar = sorted((t, m) for t, m, d, l in mj['notes'] if l == 'marimba')
base = {}
for t, m in mar: base.setdefault(round(t, 3), m); base[round(t, 3)] = min(base[round(t, 3)], m)
seq = sorted(base.items()); big = [(a, b) for a, b in zip(seq, seq[1:]) if b[0] - a[0] < 2.1 and abs(b[1] - a[1]) > 7]
fails += [f'ostinato leap > fifth: {nm(a[1])}@{a[0]} -> {nm(b[1])}@{b[0]}' for a, b in big]
P(''); P(f'pitched notes checked: {len(notes)}; chord tones overall {all_ok}/{len(notes)}; strong-beat chord tones {strong_ok}/{strong_total}; '
      f'largest ostinato step {max((abs(b[1]-a[1]) for a, b in zip(seq, seq[1:])), default=0)} semitones; failures {len(fails)}')
for f in fails: P('FAIL ' + f)
open(V2 + '/harmony_report.txt', 'w').write('\n'.join(out) + '\n')
sys.exit(1 if fails else 0)
