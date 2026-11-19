import React from 'react';
import {AbsoluteFill, useCurrentFrame} from 'remotion';
import {C, DOTO, GEIST} from '../theme';
import {pop, ramp, track, win} from '../lib/anim';
import {Stage, view} from '../lib/Stage';
import {Big, Sub, Tag, count} from '../lib/Type';
import {LiveCall} from '../screens/LiveCall';
import {FULLV} from './IntroConnect';
/** Given per-entry [start, end] frames, how many entries are done and how far the next one is. */
export const typed = (g: number, sched: [number, number][], base = 0) => {
  let shown = base, typing = 0;
  for (let i = 0; i < sched.length; i++) {
    const [a, b] = sched[i];
    if (g >= b) shown = base + i + 1; else { if (g > a) typing = Math.max(0.02, (g - a) / (b - a)); break; }
  }
  return {shown, typing};
};
const SCHED: [number, number][] = [[20, 70], [74, 100], [104, 150], [154, 180], [184, 196], [200, 270]];
const CHIPS = ['BP 158/94', 'HR 104', 'RR 20', 'SpO2 95%'];
/** 0:20–0:40. The call is transcribed live; the numbers come out; our model against stock Whisper. */
export const Hear: React.FC = () => {
  const g = useCurrentFrame();
  const {shown, typing} = typed(g, SCHED);
  const cam = track(g, [{f: 0, r: view(156, 1131, 420)}, {f: 14, r: FULLV, hold: 26}, {f: 78, r: view(1000, 800, 1700), hold: 194}, {f: 300, r: view(1262, 1082, 1130)}]);
  const cmp = g >= 420;
  const focus = g < 272 ? {x: 727, y: 139, w: 1039, h: 1063} : {x: 752, y: 1004, w: 1000, h: 172};
  const amt = cmp ? 1 : ramp(g, 58, 76);
  const big = g >= 540;
  return (
    <AbsoluteFill style={{background: C.bg}}>
      <Stage view={cam} focus={cmp ? null : focus} amt={amt} blur={cmp ? 16 : 9} dim={cmp ? 0.82 : 0.62}>
        <LiveCall seconds={g < 270 ? (35 * g) / 270 : 35 + (g - 270) / 60} state={g < 6 ? 'idle' : 'recording'} shown={shown} typing={typing} t={g} hotLine={g >= 270 ? 5 : undefined} energy={0.9} />
      </Stage>
      <Tag f={g} at={62} out={264} x={90} y={150} text="Nobody charts mid-call" />
      <Big f={g} at={66} out={264} x={84} y={216} size={112} lines={['It hears', 'the call.']} hot="hears" />
      <Sub f={g} at={110} out={264} x={90} y={470} text={'Every word, as it is said.\nOn the iPad.'} size={36} color={C.ink} />
      {/* the vitals, lifted out of the sentence */}
      <Tag f={g} at={286} out={416} x={110} y={96} text="Numbers get lost in the noise" />
      {g >= 296 && g < 418 && (
        <div style={{position: 'absolute', left: 110, top: 170, opacity: win(g, 296, 418, 6, 8)}}>
          <div style={{fontFamily: GEIST, fontWeight: 600, fontSize: 30, color: C.dim, letterSpacing: '0.06em'}}>VITALS BY TIME <span style={{fontFamily: DOTO, fontWeight: 900, fontSize: 40, color: C.yellow, marginLeft: 14}}>02:05</span></div>
          <div style={{display: 'flex', gap: 22, marginTop: 26}}>
            {CHIPS.map((c, i) => (
              <div key={c} style={{padding: '18px 34px 22px', borderRadius: 26, background: C.paper, color: C.black, fontFamily: DOTO, fontWeight: 900, fontSize: 82, lineHeight: 1, transform: `scale(${pop(g, 300 + i * 8)}) translateY(${40 * (1 - pop(g, 300 + i * 8))}px)`, transformOrigin: '50% 100%', whiteSpace: 'nowrap'}}>{c}</div>
            ))}
          </div>
        </div>
      )}
      {/* model comparison */}
      {cmp && !big && (
        <div style={{position: 'absolute', inset: 0, opacity: 1 - ramp(g, 532, 540)}}>
          <Tag f={g} at={424} out={540} x={0} y={150} align="center" text="Stock speech AI mangles medicine" />
          {([['Medic said', 'pulse oximetry', 430, C.dim], ['Stock Whisper', 'pulse on some tree', 462, C.ink], ['Earshot', 'pulse oximetry', 500, C.green]] as [string, string, number, string][]).map(([label, text, at, col], i) => g >= at ? (
            <div key={label} style={{position: 'absolute', left: 190, top: 270 + i * 190, display: 'flex', alignItems: 'baseline', gap: 40, opacity: ramp(g, at, at + 5), transform: `translateX(${-24 * (1 - pop(g, at))}px)`}}>
              <div style={{width: 300, fontFamily: GEIST, fontWeight: 600, fontSize: 38, color: C.dim}}>{label}</div>
              <div style={{position: 'relative', fontFamily: DOTO, fontWeight: 900, fontSize: 104, color: col, whiteSpace: 'nowrap'}}>
                {text}
                {i === 1 && <div style={{position: 'absolute', left: 372, top: 68, height: 12, width: 760 * ramp(g, 478, 488), background: C.red, borderRadius: 6}} />}
              </div>
            </div>
          ) : null)}
        </div>
      )}
      {big && (
        <div style={{position: 'absolute', inset: 0, opacity: 1 - ramp(g, 650, 660)}}>
          <div style={{position: 'absolute', left: 0, width: 1920, top: 110, textAlign: 'center', fontFamily: DOTO, fontWeight: 900, fontSize: 520, lineHeight: 1, color: C.red, transform: `scale(${0.9 + 0.1 * pop(g, 540, 12)})`}}>{count(g, 540, 560, 35)}%</div>
          <Big f={g} at={556} out={660} x={960} y={650} size={82} align="center" lines={['fewer errors than stock Whisper']} speed={2.2} />
          <Sub f={g} at={580} out={660} x={0} y={790} align="center" size={34} text="Our speech model, tuned on EMS speech  ·  measured on held-out clips of real medical speech" />
        </div>
      )}
    </AbsoluteFill>
  );
};
