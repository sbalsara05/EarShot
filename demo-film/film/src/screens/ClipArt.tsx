import React from 'react';
import {C, DOTO} from '../theme';
/** The app's own drawing of the clip: a white slab with mic holes, a red button and a status light.
 *  Drawn in a 250 x 400 box; `turn` (-1..1) swings it like the app does when the iPad tilts. */
export const ClipArt: React.FC<{cx: number; cy: number; scale?: number; turn?: number; press?: number; ghost?: boolean; led?: string; glow?: number; opacity?: number}> = ({cx, cy, scale = 1, turn = 0.35, press = 0, ghost, led = C.green, glow = 0, opacity = 1}) => {
  const W = 222, H = 392, side = 34 * turn;
  const body = '#F1EFEA', edge = '#8E8C86';
  return (
    <div style={{position: 'absolute', left: cx, top: cy, width: 0, height: 0, opacity, transform: `scale(${scale})`}}>
      <div style={{position: 'absolute', left: -W / 2, top: -H / 2, width: W, height: H, transform: `perspective(1400px) rotateY(${-turn * 22}deg) rotateX(${4}deg)`, transformStyle: 'preserve-3d'}}>
        {!ghost && <div style={{position: 'absolute', left: side, top: -6, width: W, height: H, borderRadius: 46, background: edge}} />}
        <div style={{position: 'absolute', inset: 0, borderRadius: 46, background: ghost ? 'transparent' : body, border: ghost ? `3px dashed ${C.faint}` : 'none', boxSizing: 'border-box', boxShadow: glow ? `0 0 ${80 * glow}px ${C.red}${Math.round(120 * glow).toString(16).padStart(2, '0')}` : undefined}}>
          {[0, 1, 2].map((r) => [0, 1, 2, 3].map((c) => (
            <div key={`${r}${c}`} style={{position: 'absolute', left: 62 + c * 27, top: 72 + r * 31, width: 15, height: 15, borderRadius: 15, background: ghost ? C.faint : '#0C0C0D', opacity: ghost ? 0.6 : 1}} />
          )))}
          <div style={{position: 'absolute', left: W / 2 - 42, top: 203, width: 84, height: 96, borderRadius: 60, background: ghost ? 'transparent' : C.red, border: `6px solid ${ghost ? C.faint : '#0C0C0D'}`, boxSizing: 'border-box', transform: `scale(${1 - 0.12 * press})`, filter: press ? `brightness(${1 - 0.25 * press})` : undefined}} />
          <div style={{position: 'absolute', left: 58, top: 338, display: 'flex', alignItems: 'center', gap: 9}}>
            <div style={{width: 12, height: 12, borderRadius: 12, background: ghost ? C.faint : led}} />
            <div style={{fontFamily: DOTO, fontWeight: 900, fontSize: 23, color: ghost ? C.faint : '#0C0C0D'}}>earshot</div>
          </div>
        </div>
      </div>
    </div>
  );
};
