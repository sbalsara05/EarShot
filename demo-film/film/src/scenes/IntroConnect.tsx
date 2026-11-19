import React from 'react';
import {AbsoluteFill, useCurrentFrame} from 'remotion';
import {C, DOTO, GEIST, SH, SW} from '../theme';
import {easeIO, lerp, pop, ramp, track, win} from '../lib/anim';
import {Stage, project, view} from '../lib/Stage';
import {Big, Ring, Slot, Sub, Tag} from '../lib/Type';
import {RealClip} from '../lib/RealClip';
import {ClipScreen} from '../screens/ClipScreen';
import {Home} from '../screens/Home';
export const FULLV = view(SW / 2, SH / 2, 2224);
const decay = (f: number, at: number, d = 12) => (f < at ? 0 : Math.max(0, 1 - (f - at) / d));
const GEST: [string, string, number][] = [['Click', 'Mark the moment', 210], ['Double click', 'Pause', 225], ['Hold', 'Start or end the call', 240]];
/** 0:00–0:20. The clip, its one button, then pairing with the iPad. */
export const IntroConnect: React.FC<{emt?: boolean}> = ({emt}) => {
  const f = useCurrentFrame();
  // ---- the printed clip, one continuous object from 2 s until it docks into the app at 14 s
  const ghost = project(FULLV, 48 + 520, 139 + 500);
  const dock = ramp(f, 300, 346, easeIO);
  const cx = lerp(1450, ghost.x, dock), cy = lerp(560, ghost.y, dock);
  const size = lerp(lerp(1500, 560, ramp(f, 60, 100)), 300, dock);
  const presses = decay(f, 210) + decay(f, 225, 6) + decay(f, 232, 6) + (f >= 240 && f < 264 ? 1 : 0);
  const clipO = ramp(f, 60, 80) * (1 - ramp(f, 418, 426));
  const ry = lerp(0.5 + Math.sin(f / 38) * 0.28, 0.3, dock), rx = lerp(-0.42, -0.1, dock);
  const glow = f < 300 ? 0.55 + 0.45 * decay(f % 15, 0, 15) + presses : 0.5 + 0.5 * Math.abs(Math.sin(f / 6));
  // ---- the app
  const g = f - 300;
  const state = g < 40 ? 'looking' : g < 80 ? 'found' : g < 120 ? 'connecting' : 'connected';
  const rows = f < 435 ? 0 : f < 450 ? 1 : f < 465 ? 2 : f < 480 ? 3 : 4;
  const cam = track(f, [{f: 425, r: FULLV}, {f: 452, r: view(1030, 520, 1640), hold: 40}, {f: 520, r: view(1120, 700, 1420)}]);
  const fh = [190, 300, 410, 525, 760][rows];
  const legend = f >= 496;
  const focus = legend ? {x: 1150, y: 690, w: 604, h: 232} : {x: 1150, y: 150, w: 604, h: fh};
  const amt = ramp(f, 428, 442);
  const home = f >= 540;
  const hcam = track(f, [{f: 540, r: FULLV}, {f: 584, r: view(760, 600, 1900), hold: 2}, {f: 600, r: view(233, 764, 520)}]);
  return (
    <AbsoluteFill style={{background: '#050506'}}>
      {/* opening: one red light on black */}
      {f < 96 && (() => {
        const beat = decay(f % 15, 0, 15); const t = ramp(f, 60, 90, easeIO); const r = lerp(26 + 12 * beat, 10, t);
        return (
          <div style={{position: 'absolute', left: lerp(960, cx, t) - r, top: lerp(540, cy - 150, t) - r, width: r * 2, height: r * 2, borderRadius: r * 2, background: C.red, opacity: ramp(f, 0, 4) * (1 - ramp(f, 84, 96)), boxShadow: `0 0 ${60 + 80 * beat}px ${20 + 30 * beat}px rgba(239,59,74,${0.35 + 0.3 * beat})`}} />
        );
      })()}
      {[0, 15, 30, 45].map((b) => <Ring key={b} f={f} at={b} x={960} y={540} r0={30} r1={260} dur={26} width={3} />)}
      {/* the app screens */}
      {f >= 300 && !home && (
        <div style={{position: 'absolute', inset: 0, opacity: ramp(f, 300, 318), transform: `translateY(${40 * (1 - ramp(f, 300, 322))}px)`}}>
          <Stage view={cam} focus={focus} amt={amt}>
            <ClipScreen state={state as any} scan={Math.abs(((f % 44) / 22) - 1)} appear={ramp(f, 420, 432)} rows={rows} tapRow={win(f, 362, 378, 5, 5)} legendHot={legend ? 0 : -1} turn={0.35 + 0.12 * Math.sin(f / 20)} />
          </Stage>
        </div>
      )}
      {home && (
        <Stage view={hcam}><Home reveal={ramp(f, 542, 560, (t) => t)} press={win(f, 580, 594, 4, 6)} turn={0.35 + 0.1 * Math.sin(f / 18)} /></Stage>
      )}
      {/* the clip itself */}
      {f >= 60 && f < 426 && !(emt && f < 300) && <RealClip x={cx} y={cy} size={size} rx={rx} ry={ry} glow={Math.min(1.6, glow)} opacity={clipO} press={Math.min(1, presses)} />}
      {/* call-outs on the clip (own-media cut) */}
      {!emt && [['microphone', 135, -250, -150], ['status light', 150, 250, -205], ['collar clip', 165, 240, 215]].map(([label, at, dx, dy]: any) => (
        f >= at && f < 208 ? (
          <div key={label} style={{position: 'absolute', left: cx + dx - (dx < 0 ? 230 : 0), top: cy + dy - 24, width: 230, textAlign: dx < 0 ? 'right' : 'left', opacity: win(f, at, 208, 6, 6), fontFamily: GEIST, fontWeight: 600, fontSize: 30, color: C.ink, letterSpacing: '0.08em', textTransform: 'uppercase'}}>
            <span style={{display: 'inline-block', width: 12, height: 12, borderRadius: 12, background: C.red, marginRight: 12, verticalAlign: 'middle'}} />{label}
          </div>
        ) : null
      ))}
      {emt && f >= 60 && f < 300 && <Slot f={f - 60} n={1} secs={8} tc="0:02" shot="The clip on a collar or radio strap. The EMT presses it: once, twice, then holds." notes={['Tight on chest and hands, no face needed.', 'Presses land at 0:07, 0:07.5 and 0:08 if you want them on the beat.']} />}
      <Big f={f} at={64} out={118} x={120} y={emt ? 760 : 400} size={170} lines={['One clip.']} />
      <Big f={f} at={120} out={208} x={120} y={emt ? 620 : 330} size={190} lines={['One', 'button.']} hot="button." />
      {/* the three gestures, in the app's own words */}
      <Tag f={f} at={212} out={296} x={120} y={190} text="Hands stay on the patient" />
      {GEST.map(([label, action, at], i) => f >= at && f < 298 ? (
        <div key={i} style={{position: 'absolute', left: 120, top: 300 + i * 170, opacity: win(f, at, 298, 5, 8), transform: `translateX(${-30 * (1 - pop(f, at))}px)`}}>
          <div style={{display: 'flex', alignItems: 'center', gap: 22, height: 44}}>
            {i === 0 && <span style={{width: 26, height: 26, borderRadius: 26, background: C.ink}} />}
            {i === 1 && (<><span style={{width: 26, height: 26, borderRadius: 26, background: C.ink}} /><span style={{width: 26, height: 26, borderRadius: 26, background: C.ink, marginLeft: -8}} /></>)}
            {i === 2 && <span style={{width: 70, height: 26, borderRadius: 26, background: C.ink}} />}
            <span style={{fontFamily: GEIST, fontWeight: 500, fontSize: 36, color: C.dim}}>{label}</span>
          </div>
          <div style={{fontFamily: DOTO, fontWeight: 900, fontSize: 72, color: C.ink, lineHeight: 1.05, whiteSpace: 'nowrap'}}>{action}</div>
        </div>
      ) : null)}
      {!emt && [210, 225, 232].map((a) => <Ring key={a} f={f} at={a} x={cx} y={cy} r0={120} r1={420} dur={18} width={4} />)}
      {/* connect */}
      <Ring f={f} at={420} x={ghost.x} y={ghost.y} r0={80} r1={520} dur={24} color={C.green} width={5} />
      <Tag f={f} at={430} out={536} x={96} y={128} text="No setup on scene" color={C.green} />
      <Big f={f} at={434} out={536} x={90} y={196} size={170} lines={['Paired.']} />
      <Sub f={f} at={470} out={536} x={96} y={392} text={'Bluetooth to the iPad\nthe crew already carries.'} size={40} color={C.ink} />
    </AbsoluteFill>
  );
};
