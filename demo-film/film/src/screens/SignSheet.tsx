import React from 'react';
import {C, GEIST, SH, SW} from '../theme';
import {Pill, T} from './kit';

/** The hand-drawn signature, traced from the app recording. Native box 510 x 205. */
const SIG_W = 510, SIG_H = 205;
const SIG_PATH =
  'M6 40 L24 18 L62 5 L71 130 L174 130 L162 156 ' +
  'C200 110 245 85 272 92 C292 98 292 128 276 155 ' +
  'C305 120 345 95 372 99 C395 104 394 135 388 155 ' +
  'C420 125 460 103 482 106 C503 110 506 130 502 145 ' +
  'M50 200 Q276 183 503 200';

/** The signature as an inline SVG, revealed along its length by `draw` 0..1. Height is width * 205/510. */
export const Signature: React.FC<{draw?: number; width?: number; color?: string; strokeWidth?: number}> = ({draw = 1, width = SIG_W, color = C.ink, strokeWidth}) => {
  const d = Math.max(0, Math.min(1, draw));
  const sw = strokeWidth ?? Math.max(2, 4.2 * (SIG_W / width) ** 0.5);
  return (
    <svg width={width} height={(width * SIG_H) / SIG_W} viewBox={`-4 -4 ${SIG_W + 8} ${SIG_H + 8}`} style={{display: 'block', overflow: 'visible'}}>
      {d > 0 && <path d={SIG_PATH} fill="none" stroke={color} strokeWidth={sw} strokeLinecap="round" strokeLinejoin="round" pathLength={1} strokeDasharray="1 1" strokeDashoffset={1 - d} />}
    </svg>
  );
};
export const SIGNATURE_ASPECT = SIG_H / SIG_W;

// layout, measured from ref/sign.jpg
const PANEL = {x: 473, y: 145, w: 869, h: 960};
const BOX = {x: 533, y: 478, w: 749, h: 388};
const BUTTON = {x: 533, y: 956, w: 749, h: 101};
const SIG_AT = {x: 654, y: 617, w: SIG_W};
export const SIGN_RECTS = {panel: PANEL, box: BOX, button: BUTTON};

/** The signature modal plus its dimming scrim. Caller layers the report underneath. */
export const SignSheet: React.FC<{draw?: number; rise?: number; press?: number}> = ({draw = 0, rise = 1, press = 0}) => {
  const r = Math.max(0, Math.min(1, rise));
  const ready = draw > 0;
  return (
    <div style={{position: 'absolute', left: 0, top: 0, width: SW, height: SH}}>
      <div style={{position: 'absolute', inset: 0, background: '#000', opacity: 0.55 * r}} />
      <div style={{position: 'absolute', left: 0, top: 0, width: SW, height: SH, opacity: r, transform: `translateY(${(1 - r) * 90}px) scale(${0.97 + 0.03 * r})`, transformOrigin: `${PANEL.x + PANEL.w / 2}px ${PANEL.y + PANEL.h / 2}px`}}>
        <div style={{position: 'absolute', left: PANEL.x, top: PANEL.y, width: PANEL.w, height: PANEL.h, borderRadius: 50, background: '#0C0C0E', border: '1.5px solid #18181B', boxSizing: 'border-box', boxShadow: '0 30px 80px rgba(0,0,0,0.6)'}} />
        <div style={{position: 'absolute', left: 863, top: 155, width: 89, height: 5, borderRadius: 5, background: '#52505B'}} />
        <T x={530} y={236} size={59} weight={800} doto>Sign off</T>
        <Pill x={1106} y={200} w={176} h={65} outline size={26}>Cancel</Pill>
        <T x={533} y={320} size={28} color={C.dim}>Sign with your finger, or type your name.</T>
        {/* Draw / Type */}
        <div style={{position: 'absolute', left: 533, top: 370, width: 264, height: 76, borderRadius: 38, background: '#151517', border: '1.5px solid #232326', boxSizing: 'border-box'}} />
        <Pill x={539} y={376} w={125} h={64} size={25}>Draw</Pill>
        <T x={730} y={408} size={25} weight={600} color={C.dim} center>Type</T>
        {/* signing box */}
        <div style={{position: 'absolute', left: BOX.x, top: BOX.y, width: BOX.w, height: BOX.h, borderRadius: 40, background: '#151517', border: '1.5px solid #222225', boxSizing: 'border-box'}} />
        <div style={{position: 'absolute', left: 568, top: 798, width: 678, borderTop: '2.5px dotted #4E4E52'}} />
        {ready && <T x={1257} y={516} size={24} weight={600} color={C.dim} right style={{opacity: Math.min(1, draw * 8)}}>Clear</T>}
        <div style={{position: 'absolute', left: SIG_AT.x - 4, top: SIG_AT.y - 4}}><Signature draw={draw} width={SIG_AT.w} strokeWidth={4.2} /></div>
        <Pill x={BUTTON.x} y={BUTTON.y} w={BUTTON.w} h={BUTTON.h} size={30} press={press} fill={ready ? C.paper : '#5E5E61'} color={ready ? C.black : '#3A3A3D'} style={{fontFamily: GEIST}}>Sign off</Pill>
      </div>
    </div>
  );
};
