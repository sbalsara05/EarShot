import React from 'react';
import {AbsoluteFill, useCurrentFrame} from 'remotion';
import {C, DOTO, GEIST} from '../theme';
import {pop, ramp, track, win} from '../lib/anim';
import {Stage, project, view} from '../lib/Stage';
import {Big, Ring, Slot, Tag} from '../lib/Type';
import {Drafts} from '../screens/Drafts';
import {ReportSheet, reportRects} from '../screens/ReportSheet';
import {SIGN_RECTS, SignSheet} from '../screens/SignSheet';
import {FULLV} from './IntroConnect';
const RS = reportRects({format: 'SOAP'});
const mid = (r: {x: number; y: number; w: number; h: number}) => ({cx: r.x + r.w / 2, cy: r.y + r.h / 2});
/** 1:12–1:22. The medic signs; only then is it final. */
export const Sign: React.FC<{emt?: boolean}> = ({emt}) => {
  const g = useCurrentFrame();
  const signed = g >= 208;
  const b = mid(RS.signButton), sb = mid(SIGN_RECTS.button), box = SIGN_RECTS.box;
  const cam = track(g, [{f: 0, r: view(907, 700, 1640), hold: 16}, {f: 40, r: view(1150, 625, 1900)}]);
  const pressAt = project(view(907, 700, 1640), b.cx, b.cy), press2 = project(view(1150, 625, 1900), sb.cx, sb.cy);
  const slot = emt && g >= 56 && g < 204;
  return (
    <AbsoluteFill style={{background: C.bg}}>
      {!signed && (
        <Stage view={cam} focus={g >= 22 ? SIGN_RECTS.panel : RS.signButton} amt={g < 22 ? ramp(g, 0, 6) : 1} radius={40}>
          <ReportSheet scroll={RS.format.scroll} allergies="filled" format="SOAP" signPress={win(g, 6, 18, 3, 5)} />
          {g >= 16 && <SignSheet rise={ramp(g, 16, 34)} draw={ramp(g, 66, 150, (t) => t)} press={win(g, 182, 196, 3, 5)} />}
        </Stage>
      )}
      <Ring f={g} at={8} x={pressAt.x} y={pressAt.y} r0={60} r1={420} dur={14} color={C.ink} width={4} />
      <Ring f={g} at={184} x={press2.x} y={press2.y} r0={60} r1={420} dur={14} color={C.ink} width={4} />
      {slot && (
        <div style={{position: 'absolute', inset: 0, opacity: win(g, 56, 204, 3, 3)}}>
          <Slot f={g - 56} n={3} secs={4.9} tc="1:14" left shot="The medic signs on the iPad, or turns it to the nurse at the bedside." notes={['Finger on glass, then the hand-over.', 'Screen can stay soft; the film shows it.']} />
        </div>
      )}
      <Tag f={g} at={38} out={204} x={1216} y={emt && slot ? 560 : 250} text="The medic stays accountable" />
      <Big f={g} at={42} out={204} x={1210} y={emt && slot ? 620 : 312} size={96} lines={['Nothing', 'is final', 'until they', 'sign.']} hot="sign." speed={1.2} />
      {signed && (
        <Stage view={track(g, [{f: 208, r: FULLV, hold: 30}, {f: 262, r: view(1000, 520, 1900)}])} focus={null} amt={ramp(g, 242, 254)} blur={12} dim={0.7}>
          <Drafts state="signed" reveal={ramp(g, 210, 236, (t) => t)} />
        </Stage>
      )}
      <Ring f={g} at={240} x={project(FULLV, 1400, 240).x} y={project(FULLV, 1400, 240).y} r0={40} r1={380} dur={22} color={C.green} width={5} />
      {g >= 244 && (
        <div style={{position: 'absolute', left: 0, width: 1920, top: 560, display: 'flex', justifyContent: 'center', alignItems: 'center', gap: 44, opacity: win(g, 244, 300, 6, 6)}}>
          <div style={{textAlign: 'right'}}><div style={{fontFamily: GEIST, fontWeight: 600, fontSize: 26, color: C.dim, letterSpacing: '0.14em'}}>CALL STARTED</div><div style={{fontFamily: DOTO, fontWeight: 900, fontSize: 190, color: C.ink, lineHeight: 1}}>02:04</div></div>
          <div style={{width: 300 * ramp(g, 250, 270), height: 0, borderTop: `8px dotted ${C.green}`, marginTop: 34}} />
          <div style={{transform: `scale(${pop(g, 268)})`, transformOrigin: '0 60%'}}><div style={{fontFamily: GEIST, fontWeight: 600, fontSize: 26, color: C.green, letterSpacing: '0.14em'}}>SIGNED</div><div style={{fontFamily: DOTO, fontWeight: 900, fontSize: 190, color: C.green, lineHeight: 1}}>02:11</div></div>
        </div>
      )}
    </AbsoluteFill>
  );
};
