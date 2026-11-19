"""Shared helpers: sample loading (any rate -> 48 kHz stereo float), pitch by resampling, fades, filters, placement."""
import os, subprocess, functools, numpy as np
from scipy.io import wavfile
from scipy.signal import butter, sosfilt, resample_poly, fftconvolve

SR = 48000
DUR = 98.0
N = int(SR * DUR)
V2 = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
S = os.path.join(V2, 'samples')
SP = os.path.join(S, 'sonicpi/etc/samples')
KUI = os.path.join(S, 'kenney-ui-audio/addons/kenney_ui_audio')
KIF = os.path.join(S, 'kenney-interface-sounds/addons/kenney_interface_sounds')
VC = os.path.join(S, 'vcsl')
PIANO = VC + '/Chordophones/Zithers/Grand Piano, Steinway B/Sus/JHPiano_Sus_Close_{}_vl{}_rr1.wav'
MAR = VC + '/Idiophones/Struck Idiophones/Marimba/Marimba_hit_Outrigger_{}_{}_01.wav'
VIB = VC + '/Idiophones/Struck Idiophones/Vibraphone/Hard Mallets/Vibes_hard_{}_v2_rr1_Main.wav'
GLK = VC + '/Idiophones/Struck Idiophones/Glockenspiel/glock_{}_{}_01.wav'

USED = set()  # every source file actually loaded; written to used_files.txt for LICENSES.md


@functools.lru_cache(None)
def _load(path):
    USED.add(os.path.relpath(path, S))
    if path.endswith('.flac') or path.endswith('.ogg'):
        raw = subprocess.run(['ffmpeg', '-v', 'error', '-i', path, '-f', 'f32le', '-ac', '2', '-ar', str(SR), '-'],
                             capture_output=True, check=True).stdout
        return np.frombuffer(raw, np.float32).reshape(-1, 2).astype(np.float64)
    sr, d = wavfile.read(path)
    if d.dtype == np.int16: d = d / 32768.0
    elif d.dtype == np.int32: d = d / 2147483648.0
    elif d.dtype == np.uint8: d = (d - 128) / 128.0
    d = d.astype(np.float64)
    if d.ndim == 1: d = np.stack([d, d], 1)
    d = d[:, :2]
    if sr != SR:
        g = np.gcd(sr, SR); d = resample_poly(d, SR // g, sr // g, axis=0)
    return d


def load(path, trim_db=-60, hp=None, lp=None, fade_in=0.002, fade_out=0.02, maxlen=None, norm=True, align_peak=False):
    """Load a sample, trim leading silence to the transient, filter, fade (no clicks), peak-normalise to 1."""
    d = _load(path).copy()
    a = np.abs(d).max(1); thr = a.max() * 10 ** (trim_db / 20)
    i0 = max(0, int(np.argmax(a > thr)) - int(0.001 * SR)); d = d[i0:]
    if align_peak:  # start 3 ms before the loudest transient so the click lands exactly on the event time
        d = d[max(0, int(np.argmax(np.abs(d).max(1))) - int(0.003 * SR)):]
    if maxlen: d = d[:int(maxlen * SR)]
    if hp: d = filt(d, hp, 'high')
    if lp: d = filt(d, lp, 'low')
    d = fade(d, fade_in, fade_out)
    if norm: d /= np.abs(d).max() + 1e-12
    return d


def filt(d, f, kind, order=2):
    return sosfilt(butter(order, f, kind, fs=SR, output='sos'), d, axis=0)


def fade(d, fi, fo):
    d = d.copy(); n = len(d)
    a = min(n, max(1, int(fi * SR))); b = min(n, max(1, int(fo * SR)))
    d[:a] *= np.linspace(0, 1, a)[:, None]
    d[n - b:] *= (np.cos(np.linspace(0, np.pi, b)) * .5 + .5)[:, None]
    return d


def pitch(d, semis):
    """Pitch shift by resampling (changes length, like a sampler)."""
    if abs(semis) < 1e-6: return d
    r = 2 ** (semis / 12); n = int(len(d) / r)
    x = np.arange(n) * r
    return np.stack([np.interp(x, np.arange(len(d)), d[:, c]) for c in range(2)], 1)


def db(x): return 10 ** (x / 20)


def put(buf, t, d, gain_db=0.0, pan=0.0):
    i = int(round(t * SR))
    if i < 0: d = d[-i:]; i = 0
    n = min(len(d), len(buf) - i)
    if n <= 0: return
    g = db(gain_db); l = g * np.cos((pan + 1) * np.pi / 4) * 1.4142; r = g * np.sin((pan + 1) * np.pi / 4) * 1.4142
    buf[i:i + n, 0] += d[:n, 0] * l; buf[i:i + n, 1] += d[:n, 1] * r


def write(path, x):
    x = np.clip(x, -1, 1)
    wavfile.write(path, SR, (x * 32767).round().astype(np.int16))


def reverb(x, secs=1.6, wet_db=-18, hp=300, lp=6000, seed=1):
    """Small algorithmic room: exponentially decaying filtered noise impulse (decorrelated L/R), convolved."""
    rng = np.random.default_rng(seed); n = int(secs * SR)
    env = np.exp(-6.9 * np.arange(n) / n)
    ir = rng.standard_normal((n, 2)) * env[:, None]
    ir = filt(filt(ir, hp, 'high'), lp, 'low'); ir[:int(.012 * SR)] = 0; ir /= np.sqrt((ir ** 2).sum(0))
    wet = np.stack([fftconvolve(x[:, c], ir[:, c])[:len(x)] for c in range(2)], 1)
    return x + wet * db(wet_db) * 3
