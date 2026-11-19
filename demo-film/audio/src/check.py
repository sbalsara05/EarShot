"""Objective checks: format, peaks, loudness, onset timing vs the hit map, sfx event levels. Writes check_report.txt + spectrogram."""
import subprocess, re, numpy as np
from scipy.io import wavfile
from lib import V2, filt
import sys; sys.argv = sys.argv[:1]

out = []
def P(*a): s = ' '.join(str(x) for x in a); print(s); out.append(s)

def info(name):
    sr, d = wavfile.read(f'{V2}/{name}'); x = d / 32768.0
    e = subprocess.run(['ffmpeg', '-nostats', '-i', f'{V2}/{name}', '-af', 'ebur128=peak=true', '-f', 'null', '-'],
                       capture_output=True, text=True).stderr
    I = re.findall(r'I:\s+(-?[\d.]+) LUFS', e)[-1]; tp = re.findall(r'Peak:\s+(-?[\d.inf]+) dBFS', e)[-1]
    P(f'| {name} | {len(x)/sr:.3f} s | {sr} Hz | {d.dtype} {x.shape[1]}ch | sample peak {20*np.log10(np.abs(x).max()):.2f} dBFS | true peak {tp} dBTP | {I} LUFS |')
    return sr, x

P('| file | duration | rate | format | sample peak | true peak | integrated |'); P('|---|---|---|---|---|---|---|')
_, mix = info('mix.wav'); _, mus = info('music.wav'); sr, fx = info('sfx_only.wav')

def onset(x, t, win=0.12):
    """First 1 ms frame after background where the envelope crosses 20% of the way from background to the local peak."""
    a = np.abs(x).max(1); i0, i1 = int((t - win) * sr), int((t + win) * sr); hop = 48
    seg = a[i0:i1]; env = seg[:len(seg)//hop*hop].reshape(-1, hop).max(1)
    bg = np.percentile(env[:int((win - 0.04) * 1000)], 90)          # background up to 40 ms before the target
    pk = env.max(); thr = bg + 0.2 * (pk - bg)
    j = int(win * 1000) - 40 + int(np.argmax(env[int(win * 1000) - 40:] > thr))
    return (i0 + j * hop) / sr

P(''); P('| hit | stem | measured onset | error |'); P('|---|---|---|---|')
for t, stem in [(38.0, 'music'), (38.0, 'sfx'), (44.0, 'sfx'), (48.0, 'sfx'), (90.0, 'music'), (90.0, 'sfx'), (92.0, 'music')]:
    for name, x in [(stem, mus if stem == 'music' else fx), ('mix', mix)]:
        xx = filt(x, 2000, 'high', 4) if (name == 'mix' and stem == 'sfx') else x   # Foley transient over the low bed
        m = onset(xx, t); P(f'| {t:.2f} | {name}{" (>2 kHz)" if xx is not x else ""} | {m:.4f} | {1000*(m-t):+.1f} ms {"OK" if abs(m-t) <= .015 else "FAIL"} |')

def rms_db(x, a, b): s = x[int(a * sr):int(b * sr)]; return 10 * np.log10((s ** 2).mean() + 1e-12)
pre, post = rms_db(mus, 18.5, 19.9), rms_db(mus, 20.4, 21.5)
r = mus[int(19.5 * sr):int(21 * sr)]; hop = 480; e = 10 * np.log10((r[:len(r)//hop*hop].reshape(-1, hop, 2) ** 2).mean((1, 2)) + 1e-12)
half = (pre + post) / 2; k = int(np.argmax(e > half)); rise = 19.5 + k * hop / sr
P(f'20.0 energy rise (music.wav, 10 ms RMS): {pre:.1f} dB before -> {post:.1f} dB after (+{post-pre:.1f} dB); half-way point reached at {rise:.3f} s ({1000*(rise-20):+.0f} ms)')

P(''); P('music.wav band energy (whole film, energy in band relative to total):'); P('| band | energy dB | share | mean density dB/Hz |'); P('|---|---|---|---|')
X = np.abs(np.fft.rfft(mus.mean(1))) ** 2; F = np.fft.rfftfreq(len(mus), 1 / sr); tot = X.sum(); bands = {}
for name, lo, hi in [('sub <120 Hz', 20, 120), ('120-300 Hz', 120, 300), ('300 Hz-4 kHz (speech)', 300, 4000), ('4-10 kHz', 4000, 10000), ('>10 kHz', 10000, 24000)]:
    m = (F >= lo) & (F < hi); e = X[m].sum(); bands[name] = e
    P(f'| {name} | {10*np.log10(e/tot):.1f} | {100*e/tot:.1f}% | {10*np.log10(e/tot/(hi-lo)):.1f} |')
lows = bands['sub <120 Hz'] + bands['120-300 Hz']
P(f'speech band vs lows (<300 Hz): {10*np.log10(bands["300 Hz-4 kHz (speech)"]/lows):.1f} dB (target <= -6)')

P(''); duck = np.load(V2 + '/src/.duck_db.npy')
P('| sfx event | max bed duck (dB) | ms to reach 90% of it | ms until back within 1 dB |'); P('|---|---|---|---|')
for te in (14.0, 44.0, 80.0, 38.0, 90.0):
    i = int(te * 1000); w = duck[i:i + 1500]; k = int(np.argmax(w <= 0.9 * w.min())); km = int(np.argmin(w)); j = km + int(np.argmax(w[km:] > -1.0))
    P(f'| {te:.2f} | {w.min():.2f} | {k} | {j} |')
P(''); P('sfx event peaks (dBFS, 250 ms window from event start):')
import importlib.util
spec = importlib.util.spec_from_file_location('sfx', f'{V2}/src/sfx.py'); s = importlib.util.module_from_spec(spec); spec.loader.exec_module(s)
times = sorted(set(round(e[0], 2) for e in s.build()))
row = []
for t in times:
    i = int(t * sr); p = 20 * np.log10(np.abs(fx[i:i + int(.25 * sr)]).max() + 1e-9); row.append(f'{t:.2f}:{p:.1f}')
P(' '.join(row)); P(f'distinct sfx moments: {len(times)}')
open(f'{V2}/check_report.txt', 'w').write('\n'.join(out) + '\n')
subprocess.run(['ffmpeg', '-y', '-v', 'error', '-i', f'{V2}/mix.wav', '-lavfi',
                'showspectrumpic=s=1600x600:legend=1:scale=log:stop=8000', f'{V2}/mix_spectrogram.png'], check=True)
