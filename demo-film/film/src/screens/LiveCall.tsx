import React from 'react';
import {C, DOTO, GEIST} from '../theme';
import {rnd} from '../lib/anim';
import {Box, Card, Flag, Legend, Pill, Screen, T, TopBar} from './kit';

export type Line = {t: string; text: string; mark?: number};
/** The call used in the app recording, word for word. */
export const CALL: Line[] = [
  {t: '02:04', text: 'Medic 14 on scene, 68 year old male, chest pain that started about 30 minutes ago.'},
  {t: '02:05', text: 'Sir, can you point to where it hurts?'},
  {t: '02:05', text: 'Right here in the middle. It feels like pressure, and it goes down my left arm.'},
  {t: '02:05', text: 'On a scale of 1 to 10, how bad is it?'},
  {t: '02:05', text: 'About a 7.'},
  {t: '02:05', text: 'First set of vitals, BP 158 over 94, heart rate 104, respirations 20, sats 95% on room air.'},
  {t: '02:05', text: '', mark: 1},
  {t: '02:05', text: 'Any history of heart problems?'},
  {t: '02:05', text: 'I had a stent put in 2 years ago. I take metoprolol and atorvastatin.'},
  {t: '02:05', text: '12 lead shows ST elevation in 2, 3 and aVF. Giving aspirin, 324 milligrams, chewed.'},
  {t: '02:05', text: '', mark: 2},
  {t: '02:05', text: 'One nitroglycerin, 0.4 milligrams, under the tongue.'},
  {t: '02:06', text: 'Repeat vitals, BP 146 over 88, heart rate 96. Pain is down to a 4.'},
  {t: '02:06', text: 'Transporting priority 1 to County General, STEMI alert called in.'},
];
const CHARS = 52; // characters that fit one transcript row at 34px
export const wrap = (text: string, n = CHARS) => {
  const out: string[] = []; let cur = '';
  for (const w of text.split(' ')) { if ((cur + ' ' + w).trim().length > n) { out.push(cur); cur = w; } else cur = (cur + ' ' + w).trim(); }
  if (cur) out.push(cur); return out;
};
/** Dot-matrix level meter, lit from the bottom like the app's. `energy` 0..1, `t` drives the motion. */
export const Wave: React.FC<{x: number; y: number; t: number; energy: number; cols?: number; rows?: number; pitch?: number; d?: number; color?: string}> = ({x, y, t, energy, cols = 30, rows = 6, pitch = 18, d = 11, color = C.ink}) => {
  const dots: React.ReactNode[] = [];
  for (let c = 0; c < cols; c++) {
    const step = Math.floor(t / 3) - (cols - c);
    const lvl = step < 0 ? 0 : energy * (0.25 + 0.75 * rnd(step * 1.7)) * (0.5 + 0.5 * Math.abs(Math.sin(step / 5)));
    const lit = Math.max(energy > 0.02 && step >= 0 ? 1 : 0, Math.round(lvl * rows));
    for (let r = 0; r < rows; r++) dots.push(<div key={`${c}-${r}`} style={{position: 'absolute', left: c * pitch, top: (rows - 1 - r) * pitch, width: d, height: d, borderRadius: d, background: r < lit ? color : '#2B2B2E'}} />);
  }
  return <div style={{position: 'absolute', left: x, top: y}}>{dots}</div>;
};
export type LiveProps = {
  seconds: number;          // timer value
  state: 'idle' | 'recording' | 'paused';
  shown: number;            // how many transcript entries are complete
  typing?: number;          // 0..1 progress through entry number `shown`
  t: number;                // frame, for the meter
  energy?: number;
  hotLine?: number;         // entry index drawn in full ink
  markPress?: number; pausePress?: number; completePress?: number;
  scroll?: number;          // extra px to push the list up
  legendHot?: number;
};
const pad = (n: number) => String(n).padStart(2, '0');
export const LiveCall: React.FC<LiveProps> = ({seconds, state, shown, typing = 0, t, energy = 0.8, hotLine, markPress = 0, pausePress = 0, completePress = 0, scroll = 0, legendHot = -1}) => {
  // lay the entries out bottom-up, newest at the bottom of the card
  const entries = CALL.slice(0, Math.min(CALL.length, shown + (typing > 0 ? 1 : 0)));
  const rows = entries.map((e, i) => {
    const live = i === shown && typing > 0;
    const full = e.text; const n = live ? Math.max(1, Math.round(full.length * typing)) : full.length;
    // cut on a word boundary so words arrive whole, like the app
    let cut = live ? full.slice(0, n) : full; if (live && n < full.length) cut = cut.slice(0, Math.max(cut.lastIndexOf(' '), 0)) || full.split(' ')[0];
    const lines = e.mark ? [''] : wrap(cut);
    const big = live || i === hotLine;
    return {e, i, live, lines, big, h: e.mark ? 66 : lines.length * (big ? 62 : 55) + 15};
  });
  const total = rows.reduce((a, r) => a + r.h, 0);
  let y = 1063 - 44 - total - scroll; // card is 1063 tall
  const recording = state === 'recording';
  return (
    <Screen>
      <TopBar tab="Live Call" status={recording ? (<><span style={{width: 13, height: 13, borderRadius: 13, background: C.red, opacity: Math.floor(t / 15) % 2 ? 0.35 : 1}} /><span style={{color: C.red, fontWeight: 600}}>Recording</span><span>Clip audio</span></>) : state === 'paused' ? <span>Paused, Clip audio</span> : <span>Call started 02:04, Clip audio</span>} />
      <T x={84} y={172} size={26} color={C.dim}>{state === 'paused' ? 'Paused at' : 'Recording'}</T>
      <Box x={78} y={205} style={{fontFamily: DOTO, fontWeight: 900, fontSize: 208, lineHeight: 1, color: state === 'recording' ? C.ink : C.faint, letterSpacing: '0.02em', whiteSpace: 'nowrap'}}>{pad(Math.floor(seconds / 60))}:{pad(Math.floor(seconds % 60))}</Box>
      <Wave x={88} y={560} t={t} energy={recording ? energy : 0} />
      <div style={{position: 'absolute', left: 84, top: 800, width: 594, height: 222, borderRadius: 30, border: `1.5px solid ${C.line}`, boxSizing: 'border-box'}} />
      <T x={114} y={834} size={22} weight={600} color={C.dim}>Clip button</T>
      <Legend x={114} y={882} rows={state === 'idle' ? [['Click', 'Mark'], ['Double click', 'Start recording'], ['Hold', 'End call']] : state === 'paused' ? [['Click', 'Mark'], ['Double click', 'Resume'], ['Hold', 'End call']] : [['Click', 'Mark'], ['Double click', 'Pause'], ['Hold', 'End call']]} dimFirst={state !== 'recording'} hot={legendHot} />
      {/* record / pause button */}
      <div style={{position: 'absolute', left: 84, top: 1059, width: 144, height: 144, borderRadius: 144, background: recording ? C.red : 'transparent', border: recording ? 'none' : `4px solid ${C.ink}`, boxSizing: 'border-box', display: 'flex', alignItems: 'center', justifyContent: 'center', gap: 18, transform: `scale(${1 - 0.06 * pausePress})`}}>
        {recording ? (<><div style={{width: 16, height: 48, borderRadius: 5, background: C.black}} /><div style={{width: 16, height: 48, borderRadius: 5, background: C.black}} /></>) : <div style={{width: 112, height: 112, borderRadius: 112, background: C.red}} />}
      </div>
      {state === 'recording' && <Pill x={258} y={1059} w={420} h={144} fill={C.yellow} size={40} press={markPress}><Flag size={38} />Mark</Pill>}
      {state === 'paused' && <Pill x={258} y={1059} w={420} h={144} size={38} press={completePress}>Complete</Pill>}
      {state === 'idle' && <T x={266} y={1131} size={30} weight={600}>Start recording</T>}
      <Card x={727} y={139} w={1039} h={1063}>
        {rows.length === 0 && (<><T x={520} y={470} size={26} color={C.dim} center>What is said will appear here as you record.</T></>)}
        {rows.map((r) => {
          const top = y; y += r.h;
          if (top + r.h < -10) return null;
          if (r.e.mark) return (
            <React.Fragment key={r.i}>
              <T x={59} y={top + 26} size={26} color={C.faint}>{r.e.t}</T>
              <Box x={179} y={top + 10} style={{display: 'flex', alignItems: 'center', gap: 10}}><Flag size={30} color={C.yellow} /><span style={{fontFamily: DOTO, fontWeight: 800, fontSize: 30, color: C.yellow}}>Mark {r.e.mark}</span></Box>
              <div style={{position: 'absolute', left: 336, top: top + 25, width: 642, borderTop: `3px dotted ${C.yellow}`, opacity: 0.75}} />
            </React.Fragment>
          );
          const lh = r.big ? 62 : 55;
          return (
            <React.Fragment key={r.i}>
              <T x={59} y={top + lh / 2 + 2} size={26} color={C.faint}>{r.e.t}</T>
              {r.lines.map((ln, k) => {
                const last = r.live && k === r.lines.length - 1; const sp = ln.lastIndexOf(' ');
                return (
                  <div key={k} style={{position: 'absolute', left: 179, top: top + k * lh, height: lh, display: 'flex', alignItems: 'center', fontFamily: GEIST, fontSize: r.big ? 38 : 34, fontWeight: r.big ? 500 : 400, color: r.big ? C.ink : '#B4B2AD', whiteSpace: 'pre'}}>
                    {last ? (<>{ln.slice(0, sp + 1)}<span style={{color: C.red}}>{ln.slice(sp + 1)}</span><span style={{width: 12, height: 12, borderRadius: 12, background: C.red, marginLeft: 8, marginTop: 14, opacity: 0.6}} /></>) : ln}
                  </div>
                );
              })}
            </React.Fragment>
          );
        })}
      </Card>
    </Screen>
  );
};
