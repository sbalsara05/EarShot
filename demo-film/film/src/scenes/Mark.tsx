import React from 'react';
import {AbsoluteFill, useCurrentFrame} from 'remotion';
import {C, DOTO, GEIST} from '../theme';
import {lerp, pop, ramp, win} from '../lib/anim';
import {Stage, project, view} from '../lib/Stage';
import {Big, Ring, Sub, Tag} from '../lib/Type';
import {RealClip} from '../lib/RealClip';
import {LiveCall} from '../screens/LiveCall';
import {Flag} from '../screens/kit';
import {typed} from './Hear';
// entries after the vitals line: [frame it starts, frame it is complete]; marks land in one frame
const P1 = 60, P2 = 180, FLY = 10;           // the two presses (0:44 and 0:48) and the flight time of the dot
const SCHED: [number, number][] = [[P1 + FLY, P1 + FLY], [80, 100], [104, 140], [144, 172], [P2 + FLY, P2 + FLY], [198, 236], [240, 266], [268, 290]];
const TREAT = 296;
const V = view(912.5, 729, 1781);            // the transcript card fills the right two thirds, newest line at the bottom
const PANEL = 735;                            // width of the left panel that holds the clip (or the footage)
const dec = (f: number, at: number, d = 10) => (f < at ? 0 : Math.max(0, 1 - (f - at) / d));
/** 0:42–0:56. One steady picture: the clip on the left, the record on the right.
 *  A press on the clip sends a dot across, and it lands in the transcript as a mark. Then the treatments, timed. */
export const Mark: React.FC<{emt?: boolean}> = ({emt}) => {
  const g = useCurrentFrame();
  const {shown, typing} = typed(g, SCHED, 6);
  const treat = g >= TREAT;
  const press = Math.min(1, dec(g, P1, 9) + dec(g, P2, 9));
  const clip = {x: 368, y: 400};
  const row = project(V, 800, 1118);          // where a new mark row lands (bottom row of the card)
  const k = project(V, 0, 0).k;
  const state = g < P1 ? 'idle' : g < P1 + FLY ? 'click' : g < P2 ? 'mark1' : g < P2 + FLY ? 'click' : 'mark2';
  const out = 1 - ramp(g, TREAT - 8, TREAT);
  return (
    <AbsoluteFill style={{background: '#050506'}}>
      <Stage view={V} focus={null} amt={ramp(g, TREAT - 6, TREAT + 2)} blur={16} dim={0.82} opacity={ramp(g, 0, 12)}>
        <LiveCall seconds={40 + g / 8} state="recording" shown={shown} typing={typing} t={g + 700} energy={0.85} />
      </Stage>
      {/* a mark landing: the row flashes once */}
      {[P1 + FLY, P2 + FLY].map((a) => g >= a && g < a + 14 ? (
        <div key={a} style={{position: 'absolute', left: row.x - 50 * k, top: row.y - 40 * k, width: 1000 * k, height: 80 * k, borderRadius: 20, background: C.yellow, opacity: 0.32 * (1 - ramp(g, a, a + 14))}} />
      ) : null)}
      {/* left panel */}
      {!treat || g < TREAT + 2 ? (
        <div style={{position: 'absolute', left: 0, top: 0, width: PANEL, height: 1080, background: emt ? '#1838F0' : '#050506', opacity: ramp(g, 0, 12) * out, overflow: 'hidden'}}>
          {emt && (
            <>
              <div style={{position: 'absolute', inset: 0, background: 'repeating-linear-gradient(135deg, #2448ff 0 28px, #1838F0 28px 56px)', backgroundPosition: `${g * 1.2}px 0`}} />
              <div style={{position: 'absolute', inset: 28, border: '4px dashed #fff', borderRadius: 28, opacity: 0.8}} />
              <div style={{position: 'absolute', left: 64, top: 150, width: 600}}>
                <div style={{fontFamily: DOTO, fontWeight: 900, fontSize: 54, color: '#fff'}}>YOUR FOOTAGE 02</div>
                <div style={{fontFamily: GEIST, fontWeight: 600, fontSize: 28, color: '#fff', marginTop: 6}}>0:42 to 0:52 · 9.9 s · upright crop, 735 x 1080 · {Math.max(0, (TREAT - g) / 30).toFixed(1)}s left</div>
                <div style={{fontFamily: GEIST, fontWeight: 600, fontSize: 38, color: '#fff', marginTop: 34, lineHeight: 1.2}}>Mid-treatment, the EMT taps the clip without looking down.</div>
                <div style={{fontFamily: GEIST, fontWeight: 500, fontSize: 28, color: '#dfe5ff', marginTop: 14, lineHeight: 1.3}}>Taps at 0:44 and 0:48 line up with the marks landing on the right.</div>
              </div>
            </>
          )}
        </div>
      ) : null}
      {!emt && g < TREAT && <RealClip x={clip.x} y={clip.y} size={470} rx={-0.4} ry={0.42 + Math.sin(g / 34) * 0.1} glow={0.55 + 1.3 * press} press={press} opacity={ramp(g, 0, 12) * out} />}
      {!emt && [P1, P2].map((a) => <Ring key={a} f={g} at={a} x={clip.x} y={clip.y} r0={150} r1={380} dur={16} color={C.yellow} width={5} />)}
      {/* the dot that carries the press across to the record */}
      {[P1, P2].map((a) => g >= a && g <= a + FLY + 2 ? Array.from({length: 7}).map((_, i) => {
        const t = Math.min(1, Math.max(0, (g - a) / FLY - i * 0.07)); if (t <= 0) return null;
        const sx = emt ? PANEL - 40 : clip.x + 120, sy = emt ? 560 : clip.y;
        const x = lerp(sx, row.x, t), y = lerp(sy, row.y, t * t) - Math.sin(t * Math.PI) * 120, d = 26 - i * 3;
        return <div key={`${a}-${i}`} style={{position: 'absolute', left: x - d / 2, top: y - d / 2, width: d, height: d, borderRadius: d, background: C.yellow, opacity: (1 - i / 8) * (g > a + FLY ? 0.4 : 1)}} />;
      }) : null)}
      {[P1 + FLY, P2 + FLY].map((a) => <Ring key={a} f={g} at={a} x={row.x} y={row.y} r0={20} r1={170} dur={14} color={C.yellow} width={4} />)}
      {/* words, under the clip */}
      <div style={{opacity: out}}>
        <Tag f={g} at={6} out={TREAT} x={76} y={emt ? 620 : 70} text="Times get charted from memory" color={emt ? '#fff' : C.red} />
        {g >= 14 && g < TREAT && (
          <div style={{position: 'absolute', left: 76, top: 690, opacity: ramp(g, 14, 24)}}>
            <div style={{display: 'flex', alignItems: 'center', gap: 18}}>
              <span style={{width: 24, height: 24, borderRadius: 24, background: C.ink, transform: `scale(${1 + 0.5 * press})`}} />
              <span style={{fontFamily: GEIST, fontWeight: 500, fontSize: 36, color: emt ? '#fff' : C.dim}}>Click</span>
            </div>
            <div style={{fontFamily: DOTO, fontWeight: 900, fontSize: 70, color: C.ink, lineHeight: 1.1, whiteSpace: 'nowrap'}}>Mark the moment</div>
          </div>
        )}
        {state === 'click' && <div style={{position: 'absolute', left: 76, top: 850, fontFamily: DOTO, fontWeight: 900, fontSize: 130, lineHeight: 1, color: C.ink}}>Click.</div>}
        {(state === 'mark1' || state === 'mark2') && g < TREAT && (
          <div style={{position: 'absolute', left: 70, top: 850, display: 'flex', alignItems: 'center', gap: 18, transform: `scale(${0.9 + 0.1 * pop(g, state === 'mark1' ? P1 + FLY : P2 + FLY, 8)})`, transformOrigin: '0 50%'}}>
            <Flag size={112} color={C.yellow} />
            <span style={{fontFamily: DOTO, fontWeight: 900, fontSize: 130, lineHeight: 1, color: C.yellow, whiteSpace: 'nowrap'}}>{state === 'mark1' ? 'Mark 1' : 'Mark 2'}</span>
          </div>
        )}
        <Sub f={g} at={96} out={TREAT} x={80} y={990} text="It tells the AI what matters." size={36} color={C.ink} />
      </div>
      {/* 0:52 treatment by time */}
      {treat && (
        <div style={{position: 'absolute', inset: 0, opacity: 1 - ramp(g, 412, 420)}}>
          <Tag f={g} at={300} out={420} x={250} y={150} text="Treatment times get audited" />
          <div style={{position: 'absolute', left: 250, top: 236, fontFamily: GEIST, fontWeight: 600, fontSize: 34, color: C.dim, letterSpacing: '0.06em', opacity: ramp(g, 302, 310)}}>TREATMENT BY TIME</div>
          {([['02:05', 'Aspirin 324 mg', 'chewed', 306], ['02:05', 'Nitroglycerin 0.4 mg', 'under tongue', 321]] as [string, string, string, number][]).map(([t, a, b, at], i) => g >= at ? (
            <div key={i} style={{position: 'absolute', left: 250, top: 300 + i * 200, display: 'flex', alignItems: 'center', gap: 60, opacity: ramp(g, at, at + 5), transform: `translateX(${-40 * (1 - pop(g, at))}px)`}}>
              <div style={{fontFamily: DOTO, fontWeight: 900, fontSize: 170, color: C.yellow, lineHeight: 1}}>{t}</div>
              <div><div style={{fontFamily: GEIST, fontWeight: 600, fontSize: 70, color: C.ink, lineHeight: 1.1}}>{a}</div><div style={{fontFamily: GEIST, fontWeight: 500, fontSize: 44, color: C.dim}}>{b}</div></div>
            </div>
          ) : null)}
          <Big f={g} at={342} out={420} x={250} y={770} size={112} lines={['Every treatment, timed.']} hot="timed." hotColor={C.yellow} speed={2} />
        </div>
      )}
    </AbsoluteFill>
  );
};
