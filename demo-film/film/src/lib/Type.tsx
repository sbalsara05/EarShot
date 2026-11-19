import React from 'react';
import {C, DOTO, GEIST} from '../theme';
import {clamp, ramp, win} from './anim';
import {interpolate} from 'remotion';
/** Big dot-matrix words that type themselves in. `f` is the local frame; shows from `at` to `out`. */
export const Big: React.FC<{f: number; at: number; out: number; x: number; y: number; size?: number; lines: string[]; hot?: string; hotColor?: string; color?: string; speed?: number; align?: 'left' | 'center' | 'right'; weight?: number; width?: number}> = ({f, at, out, x, y, size = 150, lines, hot, hotColor = C.red, color = C.ink, speed = 1.4, align = 'left', weight = 900, width}) => {
  if (f < at || f > out) return null;
  const n = Math.floor((f - at) * speed);
  const fade = 1 - ramp(f, out - 6, out);
  let used = 0;
  return (
    <div style={{position: 'absolute', left: align === 'left' ? x : align === 'center' ? x - 960 : undefined, right: align === 'right' ? 1920 - x : undefined, width: align === 'center' ? 1920 : width, top: y, textAlign: align, fontFamily: DOTO, fontWeight: weight, fontSize: size, lineHeight: 0.98, color, opacity: fade, transform: `translateY(${-10 * (1 - fade)}px)`, letterSpacing: '0.005em', whiteSpace: 'pre'}}>
      {lines.map((ln, i) => {
        const start = used; used += ln.length;
        const h0 = hot ? ln.indexOf(hot) : -1;
        return (
          <div key={i}>
            {[...ln].map((ch, k) => (
              <span key={k} style={{visibility: start + k < n ? 'visible' : 'hidden', color: h0 >= 0 && k >= h0 && k < h0 + hot!.length ? hotColor : undefined}}>{ch}</span>
            ))}
          </div>
        );
      })}
    </div>
  );
};
/** The pain this beat answers: a small spaced label with a red dot. */
export const Tag: React.FC<{f: number; at: number; out: number; x: number; y: number; text: string; color?: string; align?: 'left' | 'center'}> = ({f, at, out, x, y, text, color = C.red, align = 'left'}) => {
  if (f < at || f > out) return null;
  const o = win(f, at, out, 8, 6);
  return (
    <div style={{position: 'absolute', left: align === 'left' ? x : 0, width: align === 'center' ? 1920 : undefined, top: y, display: 'flex', justifyContent: align === 'center' ? 'center' : 'flex-start', alignItems: 'center', gap: 16, opacity: o, transform: `translateX(${-14 * (1 - ramp(f, at, at + 8))}px)`}}>
      <span style={{width: 16, height: 16, borderRadius: 16, background: color, opacity: Math.floor(f / 15) % 2 ? 0.45 : 1}} />
      <span style={{fontFamily: GEIST, fontWeight: 600, fontSize: 30, letterSpacing: '0.16em', color: C.ink, textTransform: text.includes('ePCR') ? 'none' : 'uppercase'}}>{text}</span>
    </div>
  );
};
/** Plain supporting line. */
export const Sub: React.FC<{f: number; at: number; out: number; x: number; y: number; text: string; size?: number; color?: string; align?: 'left' | 'center'; weight?: number}> = ({f, at, out, x, y, text, size = 38, color = C.dim, align = 'left', weight = 500}) => {
  if (f < at || f > out) return null;
  return <div style={{position: 'absolute', left: align === 'left' ? x : 0, width: align === 'center' ? 1920 : undefined, textAlign: align, top: y, fontFamily: GEIST, fontWeight: weight, fontSize: size, color, opacity: win(f, at, out, 8, 6), whiteSpace: 'pre'}}>{text}</div>;
};
/** An expanding ring, for presses and hits. */
export const Ring: React.FC<{f: number; at: number; x: number; y: number; r0?: number; r1?: number; dur?: number; color?: string; width?: number}> = ({f, at, x, y, r0 = 20, r1 = 220, dur = 22, color = C.red, width = 5}) => {
  if (f < at || f > at + dur) return null;
  const t = ramp(f, at, at + dur); const r = r0 + (r1 - r0) * t;
  return <div style={{position: 'absolute', left: x - r, top: y - r, width: r * 2, height: r * 2, borderRadius: r * 2, border: `${width}px solid ${color}`, boxSizing: 'border-box', opacity: 1 - t}} />;
};
/** Count from 0 to `to` between frames. */
export const count = (f: number, a: number, b: number, to: number) => Math.round(interpolate(f, [a, b], [0, to], {...clamp, easing: (t) => 1 - Math.pow(1 - t, 3)}));
/** The slot where real footage of the EMT goes (footage cut only): solid blue so it cannot be missed. */
export const Slot: React.FC<{f: number; n: number; secs: number; shot: string; notes: string[]; tc: string; left?: boolean}> = ({f, n, secs, shot, notes, tc, left}) => (
  <div style={{position: 'absolute', inset: 0, background: '#1838F0', overflow: 'hidden'}}>
    <div style={{position: 'absolute', inset: 0, background: 'repeating-linear-gradient(135deg, #2448ff 0 28px, #1838F0 28px 56px)', backgroundPosition: `${f * 1.2}px 0`}} />
    <div style={{position: 'absolute', inset: 36, border: '4px dashed #ffffff', borderRadius: 30, opacity: 0.8}} />
    <div style={{position: 'absolute', left: 90, top: 70, display: 'flex', alignItems: 'center', gap: 18}}>
      <span style={{width: 22, height: 22, borderRadius: 22, background: '#fff', opacity: Math.floor(f / 15) % 2 ? 0.3 : 1}} />
      <span style={{fontFamily: DOTO, fontWeight: 900, fontSize: 58, color: '#fff'}}>YOUR FOOTAGE {String(n).padStart(2, '0')}</span>
      <span style={{fontFamily: GEIST, fontWeight: 600, fontSize: 30, color: '#fff', marginLeft: 16}}>{tc} to {tc.split(':')[0]}:{String(Math.round(Number(tc.split(':')[1]) + secs)).padStart(2, '0')} · {secs.toFixed(1)} s</span>
    </div>
    <div style={{position: 'absolute', right: 90, top: 74, fontFamily: DOTO, fontWeight: 900, fontSize: 46, color: '#fff'}}>{Math.max(0, secs - f / 30).toFixed(1)}s left</div>
    <div style={{position: 'absolute', right: left ? undefined : 90, left: left ? 90 : undefined, top: 190, width: 760, textAlign: left ? 'left' : 'right'}}>
      <div style={{fontFamily: GEIST, fontWeight: 600, fontSize: 44, color: '#fff', lineHeight: 1.2}}>{shot}</div>
      {notes.map((t, i) => <div key={i} style={{fontFamily: GEIST, fontWeight: 500, fontSize: 28, color: '#dfe5ff', marginTop: 14, lineHeight: 1.3}}>{t}</div>)}
    </div>
  </div>
);
