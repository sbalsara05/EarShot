"""v3 music bed: synthetic, mostly ambient, voice-over friendly. 120 bpm grid, D minor, Dm - Bb - F - C (as v2).
Detuned saw/triangle pad lanes (voice-led, gliding) -> moving 4-pole low-pass -> breathing; sine sub drone on the root;
sub blooms at 38.0 and 90.0; high noise 'air'; faint shimmer answers to the marks. Zero-phase EQ dips the speech band.
Ducked by the Foley (keyed from src/.sfx_dry.wav). Writes src/.music_dry.wav (+ notes json for harmony.py, duck curve).
All shaping lives in the keyframe tables below: edit those to change sections."""
import json, numpy as np
from scipy.io import wavfile
from scipy.signal import butter, sosfilt
from lib import SR, N, V2, write, db, filt

t = np.arange(N) / SR
BAR = 2.0
rng = np.random.default_rng(3)

# ---------- harmony (identical to v2) ----------
CH = {'Dm': (2, [2, 5, 9]), 'Bb': (10, [10, 2, 5]), 'F': (5, [5, 9, 0]), 'C': (0, [0, 4, 7]),
      'A': (9, [9, 1, 4]), 'D': (2, [2, 6, 9])}
BARS = (['Dm'] * 8 + ['Bb', 'A'] + ['Dm', 'Dm', 'Bb', 'Bb', 'F', 'F', 'C'] + ['C', 'A'] + ['Dm', 'Dm'] +
        ['Dm', 'Dm', 'Bb', 'Bb', 'F', 'F', 'C'] + ['Dm', 'Dm', 'Dm', 'Bb', 'Bb', 'Bb'] +
        ['C', 'C', 'Dm', 'Dm', 'Bb', 'Bb', 'F'] + ['Dm', 'Dm', 'Bb', 'A'] + ['Dm', 'D', 'D', 'D', 'D'])
assert len(BARS) == 50
# chord segments (start, chord): bar lines, plus the sting Bb 92.0, C 92.5, D 93.0
SEG = []
for b, c in enumerate(BARS[:46]):
    if not SEG or SEG[-1][1] != c: SEG.append((b * BAR, c))
SEG += [(92.0, 'Bb'), (92.5, 'C'), (93.0, 'D')]
NOTES = []


def voicings(c, lo=50, hi=66):
    pcs = CH[c][1]; out = []
    for base in range(lo, hi):
        if base % 12 in pcs:
            v = [base]
            for _ in range(2):
                n = v[-1] + 1
                while n % 12 not in pcs: n += 1
                v.append(n)
            if v[-1] <= hi: out.append(v)
    return out


def lane_plan():
    prev = [50, 53, 57]          # Dm: D3 F3 A3
    plan = []
    for s, c in SEG:
        v = min(voicings(c), key=lambda v: sum(abs(a - b) for a, b in zip(v, prev)))   # shared tones stay put
        plan.append((s, c, v)); prev = v
    return plan
PLAN = lane_plan()
LANE_MAX_STEP = max(abs(a - b) for (_, _, v1), (_, _, v2) in zip(PLAN, PLAN[1:]) for a, b in zip(v1, v2))
assert LANE_MAX_STEP <= 7, LANE_MAX_STEP
mtof = lambda m: 440 * 2 ** ((m - 69) / 12)


def freq_track(values, glide=0.18):
    """values: list of (start_time, freq). Piecewise constant with an equal-power-ish exponential glide at each change."""
    f = np.zeros(N)
    for i, (s, v) in enumerate(values):
        e = values[i + 1][0] if i + 1 < len(values) else 98.0
        f[int(s * SR):int(e * SR)] = v
    # glide: smooth log-frequency with a one-pole (time constant glide/3), applied forward
    lf = np.log(f); a = np.exp(-1 / (glide / 3 * SR))
    out = sosfilt(np.array([[1 - a, 0, 0, 1, -a, 0]]), lf - lf[0], zi=np.zeros((1, 2)))[0] + lf[0]
    return np.exp(out)


def kf(points, log=False):
    """Linear (or log-domain) interpolation of keyframes [(time, value), ...] over the whole timeline."""
    x, y = zip(*points); y = np.log(y) if log else np.array(y, float)
    v = np.interp(t, x, y); return np.exp(v) if log else v


# ---------- section keyframes ----------
PAD_DB = kf([(0, -80), (8, -60), (12, -32), (16, -20), (19.9, -14), (20.0, -14), (20.3, -8), (34, -8), (37.5, -4),
             (37.7, -22), (37.98, -24), (38.02, -10), (39, -10), (42, -9), (56, -9), (57.5, -11), (68, -11), (72, -9),
             (82, -9), (89.5, -2), (89.62, -48), (89.97, -48), (90.02, -5), (90.5, -14), (91.2, -55), (91.985, -70),
             (92.003, -9), (93.6, -9), (94.2, -10), (97.5, -90), (98, -90)])
CUT = kf([(0, 250), (10, 300), (19.9, 450), (20.0, 450), (20.35, 1100), (34, 1000), (37.5, 2600), (37.7, 600),
          (38.0, 600), (38.05, 1300), (39, 800), (42, 1200), (56, 1200), (57, 700), (68, 600), (72, 900), (82, 900),
          (89.5, 3200), (89.6, 3200), (90.0, 2600), (91.0, 450), (92.0, 450), (92.05, 1200), (97.5, 600), (98, 600)], log=True)
SUB_DB = kf([(0, -90), (14, -90), (18, -40), (20, -32), (20.2, -12), (34, -12), (37.5, -10), (37.65, -40), (38, -40),
             (38.6, -15), (42, -12), (56, -12), (57.5, -26), (68, -26), (70, -14), (82, -12), (89.5, -9), (89.62, -50),
             (91.97, -90), (91.985, -90), (92.01, -14), (97.5, -90), (98, -90)])
AIR_DB = kf([(0, -75), (2, -56), (20, -48), (20.2, -42), (56, -42), (57, -37), (68, -38), (82, -41), (89.5, -35),
             (89.62, -75), (90.0, -75), (90.3, -52), (92, -65), (93, -50), (97.5, -95), (98, -95)])
# breathing (soft-edged level pulse): (start, end, depth, rate Hz: 2 = quarters, 4 = 8ths)
BREATH = [(20, 34, 0.12, 2), (38, 42, 0.06, 2), (42, 56, 0.15, 4), (56, 68, 0.05, 2), (68, 82, 0.12, 2), (82, 89.5, 0.2, 4)]

# ---------- Foley answers (gestures in the pad) ----------
def bump(t0, dur, amt):        # smooth raised-cosine bump starting at t0
    x = np.clip((t - t0) / dur, 0, 1); return amt * (0.5 - 0.5 * np.cos(2 * np.pi * x)) * (x > 0) * (x < 1)
cut_mul = np.ones(N)
cut_mul *= 1 + bump(14.08, 1.0, 0.9) + bump(84.88, 1.0, 0.9)                      # bloom after the connect tones
lock_steps = sum(0.5 + 0.5 * np.tanh((t - (x + 0.05)) / 0.03) for x in (86.0, 87.0, 88.0, 89.0))   # 0..4 steps
cut_mul *= 1.13 ** (lock_steps * (t < 89.6))                                         # pad brightens with each lock
pad_gain_extra = 0.8 * lock_steps * (t < 89.6)                                       # and steps up 0.8 dB each
cut_mul *= 1 + bump(79.4, 0.6, 0.25) - 0.15 * np.clip((t - 80.0) / 1.0, 0, 1) * (t < 82)   # lift, then settle at 80.0


# ---------- synthesis ----------
def saw(phase): return 2 * (phase % 1.0) - 1
def tri(phase): return 2 * np.abs(2 * (phase % 1.0) - 1) - 1


def render_pad():
    out = np.zeros((N, 2))
    lane_gain = []
    # breakdown: keep only the lane that holds D (shared by Dm and Bb), fade the others 56-58, back 68-71
    def lane_at(time):
        return next(v for s, c, v in reversed(PLAN) if s <= time)
    dl = [i for i in range(3) if lane_at(57)[i] % 12 == 2 and lane_at(63)[i] % 12 == 2]
    assert dl, 'no lane holds D through the breakdown'
    for i in range(3):
        g = np.ones(N) if i == dl[0] else kf([(0, 1), (56, 1), (58, 0.0), (68, 0.0), (71, 1), (98, 1)])
        lane_gain.append(g)
        f = freq_track([(s, mtof(v[i])) for s, c, v in PLAN])
        for ch, dets in enumerate([(-7, 3), (7, -3)]):
            sig = np.zeros(N)
            for d in dets:
                ph = np.cumsum(f * 2 ** (d / 1200) / SR) + rng.random()
                sig += saw(ph)
            ph = np.cumsum(f / SR) + rng.random(); sig += 0.8 * tri(ph)
            out[:, ch] += sig * g * 0.18
    for s, c, v in PLAN:                     # log lane notes for the harmony check
        e = next((s2 for s2, _, _ in PLAN if s2 > s), 97.5)
        for i in range(3):
            if dl[0] != i and 58 <= s < 68: continue
            NOTES.append((s, v[i], e - s, 'pad'))
    return out


def moving_lowpass(x, cutoff, block=256):
    y = np.zeros_like(x); zi = np.zeros((2, 2, 2))
    for i in range(0, N, block):
        fc = float(np.clip(cutoff[i], 60, 16000))
        sos = butter(4, fc, 'low', fs=SR, output='sos')
        y[i:i + block], zi = sosfilt(sos, x[i:i + block], axis=0, zi=zi)
    return y


def render_sub():
    roots = []
    for s, c, v in PLAN:
        f = mtof(CH[c][0] + 24)
        while f >= 80: f /= 2
        while f < 40: f *= 2
        roots.append((s, f))
    f = freq_track(roots, glide=0.25); ph = np.cumsum(f / SR)
    x = np.sin(2 * np.pi * ph) + db(-12) * np.sin(4 * np.pi * ph)
    for s, fr in roots:
        e = next((s2 for s2, _ in roots if s2 > s), 97.5)
        if SUB_DB[int(min(s + 0.1, 97) * SR)] > -60: NOTES.append((s, int(round(69 + 12 * np.log2(fr / 440))), e - s, 'sub'))
    return np.stack([x, x], 1) * db(SUB_DB - 5)[:, None]      # sub kept 5 dB under the pad body


def bloom(t0, depth_db, tau, att=0.025):
    x = t - t0; env = np.where(x < 0, 0, np.where(x < att, 0.5 - 0.5 * np.cos(np.pi * x / att), np.exp(-(x - att) / tau)))
    s = np.sin(2 * np.pi * 36.71 * np.maximum(x, 0)) + 0.6 * np.sin(2 * np.pi * 73.42 * np.maximum(x, 0))
    NOTES.append((t0, 26, min(3 * tau, 2.0), 'bloom')); NOTES.append((t0, 38, min(3 * tau, 2.0), 'bloom'))
    return np.stack([s, s], 1) * (env * db(depth_db))[:, None]


def shimmer(t0, midi, g_db=-40, tau=0.45):
    x = t - t0; env = np.where(x < 0, 0, (1 - np.exp(-np.maximum(x, 0) / 0.04)) * np.exp(-np.maximum(x, 0) / tau))
    env *= np.clip((3 * tau - x) / 0.1, 0, 1)            # gone before the next chord
    f = mtof(midi); L = np.sin(2 * np.pi * f * x) ; R = np.sin(2 * np.pi * f * 1.003 * x)
    NOTES.append((t0, midi, 3 * tau, 'shimmer'))
    return np.stack([L, R], 1) * (env * db(g_db))[:, None]


def air():
    n = rng.standard_normal((N, 2)); n = filt(filt(n, 5500, 'high', 4), 14000, 'low', 2)
    pan = 0.5 + 0.35 * np.sin(2 * np.pi * t / 11.0)                      # slow stereo drift
    n[:, 0] *= np.sqrt(1 - pan) * 1.41; n[:, 1] *= np.sqrt(pan) * 1.41
    return n * db(AIR_DB + 3)[:, None]


def speech_dip(x, depth_db=-10):
    """Zero-phase FFT EQ: flat below 200 Hz, ramps to depth by 330 Hz, held to 3.8 kHz, back to flat by 5.2 kHz; 25 Hz low cut."""
    F = np.fft.rfftfreq(len(x), 1 / SR); lf = np.log10(np.maximum(F, 1))
    g = np.interp(lf, np.log10([1, 20, 30, 200, 330, 3800, 5200, 24000]), [-60, -60, 0, 0, depth_db, depth_db, 0, 0])
    X = np.fft.rfft(x, axis=0) * db(g)[:, None]
    return np.fft.irfft(X, n=len(x), axis=0)


def duck_curve(key):
    """Sidechain from the Foley: ~3.5 dB duck, 15 ms attack, 300 ms release; ~6 dB for the first 150 ms of the 38/90 hits."""
    a = np.abs(key).max(1); hop = 48
    env = a[:len(a) // hop * hop].reshape(-1, hop).max(1)                       # 1 ms control rate
    lvl = 20 * np.log10(env + 1e-9)
    target = -3.5 * np.clip((lvl + 50) / 15, 0, 1)                              # full 3.5 dB once Foley > -35 dBFS
    tc = np.arange(len(target)) / 1000.0
    for h in (38.0, 90.0): target = np.where((tc >= h) & (tc < h + 0.15), -6.0, target)
    g = np.zeros_like(target); at, rl = np.exp(-1 / 15), np.exp(-1 / 300)
    for i in range(1, len(g)):
        c = at if target[i] < g[i - 1] else rl
        g[i] = c * g[i - 1] + (1 - c) * target[i]
    return np.interp(np.arange(N) / hop, np.arange(len(g)), g)


if __name__ == '__main__':
    pad = render_pad()
    for a, b, d, r in BREATH:                                                   # soft breathing, beat-aligned
        m = (t >= a) & (t < b); pad[m] *= (1 - d * (0.5 - 0.5 * np.cos(2 * np.pi * r * t[m])))[:, None]
    pad = moving_lowpass(pad, CUT * cut_mul)
    pad *= db(PAD_DB + pad_gain_extra)[:, None]
    # slow stereo movement on the pad
    w = 0.5 + 0.2 * np.sin(2 * np.pi * t / 17.0)
    pad[:, 0] *= np.sqrt(1 - w) * 1.41; pad[:, 1] *= np.sqrt(w) * 1.41
    bed = pad + render_sub() + air()
    bed += bloom(38.0, -6, 0.9) + bloom(90.0, -3, 0.35)
    bed += shimmer(44.41, 117) + shimmer(48.41, 122, -42)                      # A8 over Dm, D9 over Bb (> 5 kHz)
    bed = speech_dip(bed)
    bed[int(97.5 * SR):] = 0
    sr, k = wavfile.read(V2 + '/src/.sfx_dry.wav'); duck = duck_curve(k / 32768.0)
    bed *= db(duck)[:, None]
    np.save(V2 + '/src/.duck_db.npy', duck[::48])
    write(V2 + '/src/.music_dry.wav', bed / (np.abs(bed).max() + 1e-9) * 0.5)
    json.dump({'notes': NOTES, 'bars': BARS}, open(V2 + '/src/.music_notes.json', 'w'))
    print('music bed rendered; segments', len(PLAN), 'notes', len(NOTES), 'largest pad voice-leading step', LANE_MAX_STEP, 'semitones')
