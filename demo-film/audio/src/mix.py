"""v3 mix: bed (level-set so music.wav alone is about -20.5 LUFS) + Foley, both sent to ONE shared short soft room,
then a lookahead limiter to -1.3 dBTP. Stems include their share of the room so music.wav + sfx_only.wav = mix (pre-limiter)."""
import re, subprocess, numpy as np
from scipy.io import wavfile
from scipy.ndimage import maximum_filter1d
from scipy.signal import resample_poly, fftconvolve
from lib import SR, N, V2, write, db, filt

MUSIC_LUFS = -20.0
CEIL_DBTP = -1.3
SEND_MUSIC, SEND_SFX = db(-14), db(-17)   # Foley stays mostly dry (crisp clicks), with a little of the same room


def rd(p):
    sr, d = wavfile.read(p); assert sr == SR; d = d / 32768.0
    out = np.zeros((N, 2)); out[:min(N, len(d))] = d[:N]; return out


def room(x, secs=1.1, seed=5):
    """Short soft room: decorrelated exponentially decaying noise IR, 250 Hz-6 kHz, 15 ms pre-delay. Wet only."""
    r = np.random.default_rng(seed); n = int(secs * SR)
    ir = r.standard_normal((n, 2)) * np.exp(-6.9 * np.arange(n) / n)[:, None]
    ir = filt(filt(ir, 250, 'high'), 6000, 'low'); ir[:int(.015 * SR)] = 0; ir /= np.sqrt((ir ** 2).sum(0))
    return np.stack([fftconvolve(x[:, c], ir[:, c])[:len(x)] for c in range(2)], 1)


def lufs(x, tmp=V2 + '/src/.tmp.wav'):
    write(tmp, x)
    e = subprocess.run(['ffmpeg', '-nostats', '-i', tmp, '-af', 'ebur128=peak=true', '-f', 'null', '-'],
                       capture_output=True, text=True).stderr
    return float(re.findall(r'I:\s+(-?[\d.]+) LUFS', e)[-1]), float(re.findall(r'Peak:\s+(-?[\d.inf]+) dBFS', e)[-1])


def limiter(x, ceil_db, look=0.004, rel=0.08):
    ceil = db(ceil_db)
    pk = np.abs(resample_poly(x, 4, 1, axis=0)).max(1).reshape(-1, 4).max(1)[:len(x)]
    need = np.minimum(1, ceil / np.maximum(pk, 1e-9)); L = int(look * SR)
    g = -maximum_filter1d(-need, size=2 * L + 1)
    if g.min() >= 1: return x
    a = np.exp(-1 / (rel * SR)); out = g.copy()
    for i in np.nonzero(g < 1)[0][:1]: pass
    for i in range(1, len(out)):
        out[i] = g[i] if g[i] < out[i - 1] else a * out[i - 1] + (1 - a) * g[i]
    out = np.convolve(out, np.hanning(L) / np.hanning(L).sum(), mode='same')
    return x * np.minimum(out, 1)[:, None]


if __name__ == '__main__':
    m0 = rd(V2 + '/src/.music_dry.wav'); fx = rd(V2 + '/src/.sfx_dry.wav')
    m_room = room(m0) * SEND_MUSIC
    gm = 1.0
    for _ in range(3):
        I, _ = lufs((m0 + m_room) * gm); gm *= db(MUSIC_LUFS - I)
    music = (m0 + m_room) * gm
    sfx = fx + room(fx) * SEND_SFX
    mix = limiter(music + sfx, CEIL_DBTP)
    write(V2 + '/music.wav', music); write(V2 + '/sfx_only.wav', sfx); write(V2 + '/mix.wav', mix)
    subprocess.run(['ffmpeg', '-y', '-v', 'error', '-i', V2 + '/mix.wav', '-b:a', '256k', V2 + '/mix_preview.mp3'], check=True)
    I, tp = lufs(mix); print(f'music gain {20*np.log10(gm):.2f} dB; mix {I} LUFS, true peak {tp} dBTP')
