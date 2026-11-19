import React from 'react';
import {AbsoluteFill, useCurrentFrame} from 'remotion';
import {C, DOTO, GEIST} from '../theme';
import {easeIO, lerp, pop, ramp, rnd, track, win} from '../lib/anim';
import {Stage, project, view} from '../lib/Stage';
import {Big, Ring, Tag} from '../lib/Type';
import {ReportSheet, reportRects} from '../screens/ReportSheet';
const RG = reportRects({signed: true});
const TILES = ['Nurse handoff', 'PCR narrative', 'SOAP · CHART · DRAATT', 'NEMSIS 3.5.1'];
const LOCK = [120, 150, 180, 210];
const TX = 1070, TW = 730, TH = 132, TY = (i: number) => 196 + i * 172;
const N = 300;
/** 1:22–1:38. Copy PCR; the chart breaks into dots and lands as every document; end card. */
export const Send: React.FC = () => {
  const g = useCurrentFrame();
  const far = view(1900, 620, 4200);
  const cam = track(g, [{f: 0, r: view(907, 700, 1640), hold: 44}, {f: 84, r: far}]);
  const b = RG.signButton, bp = project(view(907, 700, 1640), b.x + b.w / 2, b.y + b.h / 2);
  const merge = ramp(g, 222, 240, easeIO);
  const paper = g >= 238;
  const pr = 1500 * ramp(g, 238, 250);
  const end = g >= 300;
  return (
    <AbsoluteFill style={{background: '#050506'}}>
      {g < 240 && (
        <Stage view={cam} opacity={1 - 0.8 * ramp(g, 96, 200)} focus={null} amt={0.75 * ramp(g, 4, 12) * (1 - ramp(g, 50, 62))} radius={50}>
          <ReportSheet signed scroll={0} allergies="filled" format="SOAP" hideButton />
        </Stage>
      )}
      <Tag f={g} at={6} out={56} x={250} y={170} text="No retyping. No copy and paste." />
      <Big f={g} at={10} out={56} x={244} y={230} size={150} lines={['Straight to', 'the ePCR.']} hot="the ePCR." hotColor={C.green} speed={2} />
      {/* the ePCR the clip's iPad is connected to */}
      {g >= 60 && g < 240 && (() => {
        const sc = 1 - 0.75 * merge, cx = lerp(1435, 960, merge);
        return (
          <div style={{position: 'absolute', left: cx - 400, top: 96, width: 800, height: 790, borderRadius: 44, border: `3px solid ${g >= 84 ? C.green : C.faint}`, boxSizing: 'border-box', background: '#0E0E10', opacity: ramp(g, 60, 72), transform: `scale(${sc})`, transformOrigin: '50% 56%'}}>
            <div style={{position: 'absolute', left: 36, top: 24, fontFamily: DOTO, fontWeight: 900, fontSize: 50, color: C.ink}}>Your ePCR</div>
            <div style={{position: 'absolute', right: 36, top: 36, display: 'flex', alignItems: 'center', gap: 12, fontFamily: GEIST, fontWeight: 600, fontSize: 30, color: g >= 84 ? C.green : C.dim}}>
              <span style={{width: 16, height: 16, borderRadius: 16, background: g >= 84 ? C.green : 'transparent', border: g >= 84 ? 'none' : `2px solid ${C.dim}`, boxSizing: 'border-box'}} />{g >= 84 ? 'Connected' : 'Connecting'}
            </div>
          </div>
        );
      })()}
      {g >= 62 && g < 226 && <div style={{position: 'absolute', left: 830, top: 536, width: 200 * ramp(g, 62, 84), borderTop: `8px dotted ${C.green}`, opacity: 1 - ramp(g, 214, 226)}} />}
      <Ring f={g} at={84} x={1435} y={500} r0={200} r1={620} dur={22} color={C.green} width={5} />
      {/* the stream */}
      {g >= 60 && g < 240 && Array.from({length: N}).map((_, k) => {
        const i = k % 4, L = LOCK[i];
        const dep = L - 78 + rnd(k) * 52, t = ramp(g, dep, dep + 26, easeIO);
        if (t <= 0 || t >= 1) return null;
        const x0 = 215 + rnd(k + 0.3) * 590, y0 = 300 + rnd(k + 0.7) * 500;
        const x1 = TX + 30 + rnd(k + 1.3) * (TW - 60), y1 = TY(i) + 24 + rnd(k + 1.9) * (TH - 48);
        const bow = Math.sin(t * Math.PI) * (rnd(k + 2.2) - 0.5) * 260;
        const d = 7 + rnd(k + 3.1) * 9;
        return <div key={k} style={{position: 'absolute', left: lerp(x0, x1, t) - d / 2, top: lerp(y0, y1, t) + bow - d / 2, width: d, height: d, borderRadius: d, background: k % 11 === 0 ? C.red : k % 7 === 0 ? C.yellow : C.ink, opacity: Math.min(1, t * 6)}} />;
      })}
      {g >= 70 && g < 240 && TILES.map((label, i) => {
        const on = g >= LOCK[i], p = pop(g, LOCK[i], 9);
        const cx = lerp(TX + TW / 2, 960, merge), cy = lerp(TY(i) + TH / 2, 540, merge), sc = (on ? 0.94 + 0.06 * p : 1) * (1 - 0.75 * merge);
        return (
          <div key={label} style={{position: 'absolute', left: cx - TW / 2, top: cy - TH / 2, width: TW, height: TH, borderRadius: 30, boxSizing: 'border-box', border: on ? 'none' : `3px dashed ${C.faint}`, background: on ? C.paper : 'transparent', opacity: ramp(g, 70 + i * 6, 84 + i * 6), transform: `scale(${sc})`, display: 'flex', alignItems: 'center', padding: '0 36px', gap: 22}}>
            {on && <svg width={46} height={46} viewBox="0 0 24 24" fill="none" stroke={C.black} strokeWidth={3.2} strokeLinecap="round" strokeLinejoin="round"><path d="M4 12.5l5 5L20 6.5" /></svg>}
            <span style={{fontFamily: DOTO, fontWeight: 900, fontSize: 46, color: on ? C.black : C.faint, whiteSpace: 'nowrap'}}>{label}</span>
          </div>
        );
      })}
      {LOCK.map((L, i) => <Ring key={L} f={g} at={L} x={TX + TW / 2} y={TY(i) + TH / 2} r0={80} r1={420} dur={14} color={C.ink} width={3} />)}
      <Tag f={g} at={96} out={228} x={150} y={900} text="SIGNED CHART, SENT STRAIGHT TO THE ePCR" color={C.green} />
      {/* impact: paper floods the frame */}
      {paper && (
        <div style={{position: 'absolute', inset: 0, background: C.paper, clipPath: `circle(${pr}px at 960px 540px)`}}>
          <div style={{position: 'absolute', left: 0, width: 1920, top: 250, textAlign: 'center', fontFamily: GEIST, fontWeight: 600, fontSize: 32, letterSpacing: '0.18em', color: C.black, opacity: ramp(g, 252, 260) * (1 - ramp(g, 290, 298))}}><span style={{display: 'inline-block', width: 18, height: 18, borderRadius: 18, background: C.red, marginRight: 18}} />SIGNED. SENT STRAIGHT TO YOUR ePCR</div>
          <Big f={g} at={244} out={298} x={960} y={330} size={210} align="center" lines={['One call.', 'Every chart.']} hot="Every chart." color={C.black} speed={2.4} />
          {/* end card: the deck's own cover, so the film hands straight back to the slides */}
          <Big f={g} at={304} out={481} x={300} y={300} size={320} lines={['Earshot']} color={C.black} speed={0.7} />
          {g >= 332 && (
            <div style={{position: 'absolute', left: 308, top: 690, fontFamily: DOTO, fontWeight: 900, fontSize: 74, color: C.black, opacity: ramp(g, 332, 344), whiteSpace: 'nowrap'}}>The EMS partner who <span style={{color: C.red}}>never forgets</span>.</div>
          )}
        </div>
      )}
    </AbsoluteFill>
  );
};
