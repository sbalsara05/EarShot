import {Easing, interpolate} from 'remotion';
export const clamp = {extrapolateLeft: 'clamp', extrapolateRight: 'clamp'} as const;
export const ease = Easing.bezier(0.2, 0.8, 0.2, 1);
export const easeIO = Easing.bezier(0.65, 0, 0.35, 1);
/** 0..1 between frames a and b */
export const ramp = (f: number, a: number, b: number, e: (n: number) => number = ease) =>
  interpolate(f, [a, b], [0, 1], {...clamp, easing: e});
/** 0..1..0 window: in over [a,a+i], out over [b-o,b] */
export const win = (f: number, a: number, b: number, i = 8, o = 8) => Math.min(ramp(f, a, a + i), 1 - ramp(f, b - o, b));
export const lerp = (a: number, b: number, t: number) => a + (b - a) * t;
/** overshoot pop 0..1 */
export const pop = (f: number, a: number, d = 10) =>
  interpolate(f, [a, a + d], [0, 1], {...clamp, easing: Easing.bezier(0.2, 1.6, 0.35, 1)});
/** deterministic pseudo-random */
export const rnd = (n: number) => { const x = Math.sin(n * 127.1 + 311.7) * 43758.5453; return x - Math.floor(x); };
export type Rect = {x: number; y: number; w: number; h: number};
export const lerpRect = (a: Rect, b: Rect, t: number): Rect => ({x: lerp(a.x, b.x, t), y: lerp(a.y, b.y, t), w: lerp(a.w, b.w, t), h: lerp(a.h, b.h, t)});
/** piecewise rect track: keys [{f, r, e?}] eased between keys */
export const track = (f: number, keys: {f: number; r: Rect; hold?: number}[]): Rect => {
  if (f <= keys[0].f) return keys[0].r;
  for (let i = 1; i < keys.length; i++) {
    const k = keys[i], p = keys[i - 1];
    if (f <= k.f) { const start = p.f + (p.hold ?? 0); return lerpRect(p.r, k.r, ramp(f, start, k.f, easeIO)); }
  }
  return keys[keys.length - 1].r;
};
