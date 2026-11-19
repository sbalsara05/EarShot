import React from 'react';
import {AbsoluteFill, useCurrentFrame} from 'remotion';
import {C} from '../theme';
import {lerp, ramp, track, win, easeIO} from '../lib/anim';
import {Stage, view} from '../lib/Stage';
import {Big, Ring, Sub, Tag} from '../lib/Type';
import {LiveCall} from '../screens/LiveCall';
import {Drafts} from '../screens/Drafts';
import {ReportSheet, reportRects} from '../screens/ReportSheet';
import {FULLV} from './IntroConnect';
const R = reportRects(), RS = reportRects({format: 'SOAP'});
/** A report rectangle as it sits on screen when the body is scrolled by `sc`. */
export const at = (r: {x: number; y: number; w: number; h: number; scroll: number}, sc: number) => ({x: r.x, y: r.y + r.scroll - sc, w: r.w, h: r.h});
const mid = (r: {x: number; y: number; w: number; h: number}) => ({cx: r.x + r.w / 2, cy: r.y + r.h / 2});
const ALLERGY = 'No known drug allergies';
/** 0:56–1:12. Complete the call; the handoff and PCR are drafted; what was not heard stays blank; formats on the iPad. */
export const Draft: React.FC = () => {
  const g = useCurrentFrame();
  const live = g < 44, drafts = g >= 44 && g < 134, report = g >= 112;
  // --- report camera
  const fmtScroll = R.format.scroll;
  const narScroll = RS.narrative.scroll;
  const scroll = lerp(lerp(0, fmtScroll, ramp(g, 350, 374, easeIO)), narScroll, ramp(g, 416, 442, easeIO));
  const rows = [at(R.patient, 0), at(R.vitals, 0), at(R.given, 0)];
  const al = at(R.allergies, 0), fm = {...at(R.format, fmtScroll), w: 1295, h: 204}, nar = at(RS.narrative, narScroll);
  const cam = track(g, [
    {f: 134, r: view(907, 520, 1640), hold: 62},
    {f: 214, r: view(mid(al).cx, mid(al).cy + 110, 1500), hold: 136},
    {f: 374, r: view(907, 520, 1640), hold: 42},
    {f: 442, r: view(907, 640, 1640)},
  ]);
  const focus = g < 150 ? at(R.handoff, 0) : g < 165 ? rows[0] : g < 180 ? rows[1] : g < 198 ? rows[2] : g < 356 ? al : g < 416 ? fm : {x: nar.x, y: nar.y, w: nar.w, h: Math.min(nar.h, 1190 - nar.y)};
  const amt = g < 150 ? 0 : ramp(g, 150, 158);
  const format = g < 384 ? 'Plain' : 'SOAP', writing = g >= 384 && g < 414;
  return (
    <AbsoluteFill style={{background: C.bg}}>
      {live && (
        <Stage view={track(g, [{f: 0, r: view(400, 330, 1000), hold: 20}, {f: 32, r: view(400, 1120, 900)}])} focus={g < 26 ? {x: 60, y: 140, w: 700, h: 290} : {x: 60, y: 1040, w: 640, h: 180}} amt={1}>
          <LiveCall seconds={81} state="paused" shown={14} t={g} completePress={win(g, 34, 44, 3, 4)} />
        </Stage>
      )}
      {live && <Ring f={g} at={35} x={1010} y={552} r0={90} r1={520} dur={14} color={C.ink} width={4} />}
      <Big f={g} at={2} out={28} x={960} y={790} size={96} align="center" lines={['81 seconds of audio.']} speed={2.4} />
      {drafts && (
        <Stage view={track(g, [{f: 44, r: FULLV, hold: 30}, {f: 108, r: view(940, 560, 1960)}])}>
          <Drafts state={g < 84 ? 'writing' : 'ready'} reveal={ramp(g, 44, 58, (t) => t)} />
        </Stage>
      )}
      <Tag f={g} at={48} out={112} x={240} y={196} text="The chart used to wait until after shift" />
      <Ring f={g} at={84} x={1560} y={150} r0={30} r1={300} dur={18} color={C.yellow} width={4} />
      {report && (
        <div style={{position: 'absolute', inset: 0, opacity: ramp(g, 112, 118)}}>
          <Stage view={cam} focus={focus} amt={amt}>
            <ReportSheet rise={ramp(g, 112, 136)} scroll={scroll} allergies={g < 300 ? 'missing' : 'filled'} allergyChars={Math.round(ALLERGY.length * ramp(g, 300, 340, (t) => t))} format={format as any} writing={writing} hideButton={g > 200} />
          </Stage>
        </div>
      )}
      {/* handoff */}
      <Tag f={g} at={142} out={198} x={250} y={886} text="The nurse gets 30 seconds" />
      <Big f={g} at={146} out={198} x={244} y={934} size={100} lines={['Handoff, drafted.']} hot="drafted." speed={2} />
      {/* not heard stays blank */}
      <Tag f={g} at={216} out={352} x={250} y={610} text="A chart is a legal record" color={C.yellow} />
      <Big f={g} at={220} out={352} x={244} y={670} size={150} lines={['Not heard?', 'Left blank.']} hot="Left blank." hotColor={C.yellow} speed={1.6} />
      <Sub f={g} at={300} out={352} x={1300} y={690} text={'The medic fills the gap.\nThe AI never guesses.'} size={40} color={C.ink} />
      {/* formats, on the device */}
      <Tag f={g} at={378} out={474} x={1010} y={690} text="No signal. No cloud." />
      <Big f={g} at={382} out={474} x={1004} y={750} size={110} lines={['Written on', 'this iPad.']} hot="this iPad." speed={1.8} />
    </AbsoluteFill>
  );
};
