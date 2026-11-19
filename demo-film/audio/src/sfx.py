"""Effects layer from recorded samples only. Writes sfx_only.wav (levels as used in the mix).
Edit EVENTS to move / remove / re-level any single effect. Key: D minor (tonal accents use D F G A C only)."""
import sys, numpy as np
from lib import *

# ---- sound palette (all recorded; see LICENSES.md) ----
def clip_press(variant=0):
    # Kenney UI Audio: recorded switch clicks. Keep body, high-pass rumble, 1 ms in / 25 ms out.
    f = ['switch28', 'switch7', 'switch26'][variant]
    return load(f'{KUI}/{f}.wav', hp=150, lp=12000, maxlen=0.15, fade_out=0.03, align_peak=True)

def clip_release():
    return load(f'{KUI}/click2.wav', hp=300, lp=10000, fade_out=0.015, align_peak=True)

def ui_tap():
    return load(f'{KIF}/click_003.wav', hp=400, lp=9000, fade_out=0.006, align_peak=True)

KEYS = ['click1', 'click3', 'click5', 'click4', 'rollover2', 'switch13', 'switch14']
def key_tap(k):
    return load(f'{KUI}/{KEYS[k % len(KEYS)]}.wav', hp=600, lp=9000, maxlen=0.07, fade_out=0.012, align_peak=True)

TONAL = []  # (t, midi, dur, label) for the harmony check
MIDI = {'D4': 62, 'F4': 65, 'A4': 69, 'C5': 72, 'E5': 76, 'C4': 60, 'G4': 67, 'F3': 53, 'F5': 77, 'G5': 79, 'C6': 84}

def vibe(note, semis=0, length=1.2):
    return load(VIB.format(note), hp=180, lp=9000, maxlen=length, fade_out=0.35 * length) if semis == 0 else \
        pitch(load(VIB.format(note), hp=180, lp=9000, maxlen=length * 1.2, fade_out=0.35 * length), semis)

def marimba(note, semis=0, vel='soft', length=0.6):
    return pitch(load(MAR.format(note, vel), hp=150, maxlen=length, fade_out=0.25), semis)

def glock(note, semis=0, vel='soft', length=0.9):
    return pitch(load(GLK.format(vel, note), hp=500, maxlen=length * 1.2, fade_out=0.5), semis)

def chord(parts):
    """parts: list of (array, offset_s, gain_db)."""
    n = max(int(o * SR) + len(a) for a, o, g in parts); out = np.zeros((n, 2))
    for a, o, g in parts: put(out, o, a, g)
    return out / (np.abs(out).max() + 1e-12)

def impact(big=False):
    # recorded impact + low tom + cymbal, short, for the two big hits (music carries most of the weight)
    a = load(f'{SP}/perc_impact1.flac', hp=40, fade_out=0.3)
    b = load(f'{SP}/drum_tom_lo_hard.flac' if big else f'{SP}/drum_tom_lo_soft.flac', hp=40, lp=4000, fade_out=0.3)
    c = load(f'{SP}/drum_cymbal_hard.flac', hp=2500, fade_out=0.9)
    return chord([(a, 0, 0), (b, 0, -3), (c, 0, -9 if big else -12)])

def air_swell(secs=1.5):
    # recorded open cymbal, reversed, low-passed: a soft "air" lift into a scene change (used at most 3 times)
    c = load(f'{SP}/drum_cymbal_open.flac', hp=300, lp=6000, fade_out=0.05)[::-1]
    c = c[-int(secs * SR):]; return fade(c, secs * 0.6, 0.01)

# ---- events: (time_s, sound, gain_db relative to a normalised sample, pan) ----
def build():
    E = []
    add = lambda t, s, g, p=0.0: E.append((t, s, g, p))
    TONAL.clear()
    tone = lambda t, midi, d, l: TONAL.append((t, midi, d, l))
    # clip presses (physical button)
    add(7.00, clip_press(0), -14.5)
    add(7.50, clip_press(1), -15); add(7.73, clip_press(1), -15.5)
    add(8.00, clip_press(2), -14.5); add(8.85, clip_release(), -22)          # hold, then release
    # pairing: connected = vibes D4 + A4
    connected = chord([(vibe('D4', 0, 1.1), 0, 0), (vibe('A4', 0, 1.1), 0.07, -3)])   # Dm chord tones; 14.0 and 84.8 sit on Dm
    add(14.0, connected, -16); tone(14.0, 62, 1.1, 'connected'); tone(14.07, 69, 1.1, 'connected')
    add(19.4, ui_tap(), -15.5, 0.15)                                           # "New call"
    # vitals chips (bar 15 = F chord): marimba F4 A4 C5 F5 rising
    for t, (n, s) in zip([30.0, 30.27, 30.53, 30.8], [('C4', 5), ('G4', 2), ('G4', 5), ('F5', 0)]):
        add(t, marimba(n, s), -16.5, 0.2); tone(t, MIDI[n] + s, 0.6, 'vitals')
    add(38.0, impact(False), -9)                                              # "35%"
    add(44.0, clip_press(0), -14.5); add(44.33, glock('C6', -3), -16, 0.1); tone(44.33, 81, 0.9, 'mark1')   # A5 over Dm          # press + Mark 1
    add(48.0, clip_press(0), -14.5); add(48.33, glock('C6', 2), -16.5, 0.1); tone(48.33, 86, 0.9, 'mark2')   # D6 over Bb        # press + Mark 2
    add(52.2, marimba('G4', 2, length=0.4), -19.5, -0.2); add(52.7, marimba('G4', 2, length=0.4), -20.5, -0.2)  # treatment rows: A4 over F
    tone(52.2, 69, 0.4, 'treat'); tone(52.7, 69, 0.4, 'treat')
    add(57.17, ui_tap(), -15.5, 0.15)                                           # "Complete"
    # literal typing 66.0-67.3: 7 quiet, irregular key taps
    for k, t in enumerate([66.02, 66.19, 66.31, 66.55, 66.71, 66.98, 67.22]):
        add(t, key_tap(k), -24 - (k % 3) * 1.0, 0.05 * ((k % 3) - 1))
    add(72.2, ui_tap(), -15.5, 0.15); add(78.1, ui_tap(), -15.5, 0.15)            # "Sign off" x2
    add(80.0, chord([(vibe('F4'), 0, 0), (vibe('A4'), 0.03, -2), (vibe('C5'), 0.06, -3)]), -15.5)  # All signed: F A C over F (bar 40)
    for o, m in [(0, 65), (.03, 69), (.06, 72)]: tone(80.0 + o, m, 1.2, 'signed')
    add(84.8, connected, -16); tone(84.8, 62, 1.1, 'connected'); tone(84.87, 69, 1.1, 'connected')  # ePCR, Dm
    # four documents lock: soft switch + rising vibes D F (over Bb, bar 43) A C# (over A, bar 44)
    for t, (n, s) in zip([86.0, 87.0, 88.0, 89.0], [('D4', 0), ('F4', 0), ('A4', 0), ('C5', 1)]):
        add(t, clip_press(1), -21); add(t + 0.01, vibe(n, s, 0.8), -16 + 0.5 * (n == 'C5'), 0.1); tone(t + 0.01, MIDI[n] + s, 0.8, 'lock')
    add(90.0, impact(True), -7)                                               # biggest hit
    return E

def render():
    buf = np.zeros((N, 2))
    E = build()
    for t, s, g, p in E: put(buf, t, s, g, p)
    return buf, E

if __name__ == '__main__':
    buf, E = render()
    write(V2 + '/src/.sfx_dry.wav', buf)   # mix.py writes sfx_only.wav (dry + shared-room return)
    print('sfx events:', len(E), 'peak dBFS', round(20 * np.log10(np.abs(buf).max()), 2))
    open(V2 + '/src/.used_sfx.txt', 'w').write('\n'.join(sorted(USED)))
    import json; json.dump(TONAL, open(V2 + '/src/.sfx_notes.json', 'w'))
