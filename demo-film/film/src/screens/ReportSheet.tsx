import React from 'react';
import {C, DOTO, GEIST, SH, SW} from '../theme';
import {Box, Flag, Pill, T} from './kit';
import {CALL, Line, wrap} from './LiveCall';
import {Drafts} from './Drafts';
import {Signature, SIGNATURE_ASPECT} from './SignSheet';

export type ReportFormat = 'Plain' | 'SOAP';
export type ReportProps = {
  scroll?: number; rise?: number; signed?: boolean; allergies?: 'missing' | 'filled'; allergyChars?: number;
  format?: ReportFormat; writing?: boolean; signPress?: number; hideButton?: boolean;
};

// ---------------------------------------------------------------- fixed geometry (screen space, from ref/report.jpg + ref/pcr.jpg)
export const SHEET = {x: 212, y: 48, w: 1391, h: 1153};
const X0 = 272, X1 = 1543, XR = 944;          // content left / right edge, right column
const COLW = 620, RCOLW = X1 - XR;            // column widths
export const CLIP = {top: 228, bottom: 1022};  // the scrolling body is visible between these
const BTN = {x: 272, y: 1053, w: 1271, h: 102};
const LP = 56.5;                               // line pitch of the column text
const ROW = 137;                               // nurse handoff row pitch
const TL = 54;                                 // transcript wrapped-line pitch
const SIG_W = 240, SIG_H = SIG_W * SIGNATURE_ASPECT;
const GREY_T = '#93918C';                      // grey timestamps

// ---------------------------------------------------------------- text, line-broken as in the app
const DISPATCH = ['Medic 14 on scene, patient has chest', 'pain in middle, pain goes down left arm,', 'priority 1 to County General, STEMI alert', 'called in'];
const VITALS: [string, string[]][] = [['02:05', ['BP 158/94, HR 104, RR 20,', 'SPO2 95%']], ['02:06', ['BP 146/88, HR 96, RR 20,', 'SPO2 95%']]];
const PLAIN = ['Patient had stent 2 years ago, takes', 'metoprolol and atorvastatin, 12 lead', 'shows ST elevation in 2, 3 and aVF'];
const TREAT: [string, string[]][] = [['02:05', ['Aspirin 324 mg chewed']], ['02:05', ['nitroglycerin 0.4 mg', 'under tongue']]];
const SOAP: [string, string[]][] = [
  ['S - SUBJECTIVE:', ['68-year-old male, chest pain that', 'started about 30 minutes ago, feels like', 'pressure, goes down left arm, rated 7 on', 'a 1 to 10 scale, history of stent 2 years', 'ago, takes metoprolol and atorvastatin.']],
  ['O - OBJECTIVE:', ['BP 158 over 94, heart rate 104,', 'respirations 20, sats 95% on room air,', '12 lead shows ST elevation in 2, 3 and', 'aVF, BP 146 over 88, heart rate 96, pain', 'rated 4.']],
  ['A - ASSESSMENT:', ['STEMI alert called in.']],
  ['P - PLAN:', ['Giving aspirin, 324 milligrams, chewed,', 'one nitroglycerin, 0.4 milligrams, under', 'the tongue, transporting priority 1 to', 'County General.']],
];
const HANDOFF: [string, string][] = [
  ['Patient', '68 year old male, chest pain started 30 minutes ago'],
  ['Latest vitals', 'BP 146/88, HR 96'],
  ['Given', 'Aspirin 324 mg chewed, nitroglycerin 0.4 mg under tongue'],
];
const ALLERGY_TEXT = 'No known drug allergies';
const FORMATS: {name: string; cx: number; w: number}[] = [{name: 'Plain', cx: 342, w: 129}, {name: 'SOAP', cx: 482, w: 132}, {name: 'CHART', cx: 634, w: 146}, {name: 'DRAATT', cx: 799, w: 162}];
/** transcript lines broken like the app's wider report column */
const tLines = (l: Line) => {
  if (l.text.startsWith('First set of vitals')) return ['First set of vitals, BP 158 over 94, heart rate 104, respirations 20, sats 95%', 'on room air.'];
  return wrap(l.text, 73);
};

// ---------------------------------------------------------------- layout: every y below is the screen y at scroll 0
export const reportLayout = (o: {signed?: boolean; format?: ReportFormat; writing?: boolean} = {}) => {
  // while the narrative is being rewritten the old (Plain) text stays on screen
  const signed = !!o.signed, soap = o.format === 'SOAP' && !o.writing;
  const handoffHead = 268;
  const rows = [0, 1, 2, 3].map((i) => ({label: 334 + ROW * i, value: 389 + ROW * i, div: 428 + ROW * i}));
  const allergyDiv = rows[3].div;
  const sigHead = allergyDiv + 62, sigTop = sigHead + 48, sigText = sigTop + SIG_H + 34;
  const off = signed ? sigText + 90 - 918 : 0;
  const pcrHead = 918 + off, fmtLabel = 985 + off, segTop = 1016 + off, caption = 1122 + off;
  const colLabel = 1178 + off, colLine0 = colLabel + 48;
  const colEnd = colLine0 + 3 * LP; // dispatch and vitals both run 4 lines
  const nLabel = colEnd + 90, nLine0 = nLabel + 48;
  // narrative blocks
  const soapBlocks: {label: number; line0: number; lines: string[]; cap: string}[] = [];
  let nEnd = nLine0 + 2 * LP; // plain: 3 lines; treatment also 3 lines
  if (soap) {
    let cap = nLabel + 40;
    for (const [c, lines] of SOAP) {
      const line0 = cap + 50;
      soapBlocks.push({cap: c, label: cap, line0, lines});
      const last = line0 + (lines.length - 1) * LP;
      nEnd = Math.max(nEnd, last); cap = last + 105;
    }
  }
  const trHead = nEnd + 94;
  const dropped = trHead + 65;
  const rec = signed ? trHead + 65 : trHead + 123;
  let top = rec + 35;
  const tRows = CALL.map((l, i) => {
    const lines = l.mark ? [] : tLines(l);
    const h = l.mark ? 88 : lines.length * TL + 16;
    const r = {i, l, lines, top, h}; top += h; return r;
  });
  const end = top + 50;
  return {signed, soap, handoffHead, rows, allergyDiv, sigHead, sigTop, sigText, pcrHead, fmtLabel, segTop, caption, colLabel, colLine0, colEnd, nLabel, nLine0, nEnd, soapBlocks, trHead, dropped, rec, tRows, end, maxScroll: Math.max(0, end - CLIP.bottom)};
};

type RectKey = 'sheet' | 'header' | 'handoff' | 'patient' | 'vitals' | 'given' | 'allergies' | 'format' | 'vitalsByTime' | 'treatmentByTime' | 'narrative' | 'transcript' | 'signButton' | 'signature';
export type ScreenRect = {x: number; y: number; w: number; h: number; scroll: number};
/** Rectangles of the parts of the report, in screen space, as drawn with the body scrolled by `scroll`. */
export const reportRects = (o: {signed?: boolean; format?: ReportFormat; writing?: boolean} = {}): Record<RectKey, ScreenRect> => {
  const L = reportLayout(o);
  const VIEW = CLIP.top + 50; // where a scrolled-to block's top lands
  const body = (x: number, y0: number, y1: number, w = X1 - X0 + 24, scroll?: number): ScreenRect => {
    const s = scroll ?? (y1 <= CLIP.bottom - 20 ? 0 : Math.min(L.maxScroll, Math.max(0, Math.round(y0 - VIEW))));
    return {x, y: y0 - s, w, h: y1 - y0, scroll: s};
  };
  const row = (i: number) => body(X0 - 12, L.rows[i].label - 22, L.rows[i].div + 4);
  const sigRect = reportLayout({...o, signed: true});
  const sTop = sigRect.sigHead - 26, sBot = sigRect.sigText + 18;
  const sScroll = Math.round(Math.min(sigRect.maxScroll, Math.max(0, sBot - (CLIP.bottom - 60))));
  return {
    sheet: {...SHEET, scroll: 0},
    header: {x: SHEET.x, y: SHEET.y, w: SHEET.w, h: CLIP.top - SHEET.y, scroll: 0},
    handoff: body(X0 - 12, L.handoffHead - 28, L.allergyDiv + 6),
    patient: row(0), vitals: row(1), given: row(2), allergies: row(3),
    format: body(X0 - 12, L.fmtLabel - 22, L.caption + 20, 640),
    vitalsByTime: body(XR - 12, L.colLabel - 22, L.colEnd + 30, RCOLW + 24),
    treatmentByTime: body(XR - 12, L.nLabel - 22, L.nLine0 + 2 * LP + 30, RCOLW + 24),
    narrative: body(X0 - 12, L.nLabel - 22, L.nEnd + 30, COLW + 24),
    // the transcript is taller than the view: the rect is the part visible at that scroll
    transcript: (() => { const s = Math.min(L.maxScroll, Math.round(L.trHead - 28 - (CLIP.top + 30))); const y0 = L.trHead - 28; const y1 = Math.min(L.end - 30, CLIP.bottom + s); return {x: X0 - 12, y: y0 - s, w: X1 - X0 + 24, h: y1 - y0, scroll: s}; })(),
    signButton: {...BTN, scroll: 0},
    signature: {x: X0 - 12, y: sTop - sScroll, w: 420, h: sBot - sTop, scroll: sScroll},
  };
};
/** Rects for the default (unsigned, Plain) report; `signature` is taken from the signed layout. */
export const REPORT_RECTS = reportRects();

// ---------------------------------------------------------------- pieces
const Head: React.FC<{y: number; children: React.ReactNode}> = ({y, children}) => <T x={X0 - 2} y={y} size={39} weight={700} doto>{children}</T>;
const Label: React.FC<{x?: number; y: number; color?: string; children: React.ReactNode}> = ({x = X0, y, color = C.dim, children}) => <T x={x} y={y} size={22.5} weight={600} color={color}>{children}</T>;
const Lines: React.FC<{x: number; y0: number; lines: string[]; size?: number; color?: string}> = ({x, y0, lines, size = 33.5, color = C.ink}) => (
  <>{lines.map((ln, k) => <T key={k} x={x} y={y0 + k * LP} size={size} weight={400} color={color}>{ln}</T>)}</>
);
const Timed: React.FC<{x: number; y0: number; items: [string, string[]][]}> = ({x, y0, items}) => {
  let k = 0;
  return (
    <>{items.map(([t, lines], i) => lines.map((ln, j) => {
      const y = y0 + (k++) * LP;
      return j === 0
        ? <T key={`${i}-${j}`} x={x} y={y} size={33.5} weight={400}><span style={{color: GREY_T}}>{t}</span> {ln}</T>
        : <T key={`${i}-${j}`} x={x} y={y} size={33.5} weight={400}>{ln}</T>;
    }))}</>
  );
};
const Divider: React.FC<{y: number}> = ({y}) => <div style={{position: 'absolute', left: X0, top: y, width: X1 - X0, height: 1.5, background: '#313134'}} />;

/** The scrolling body content (screen coordinates at scroll 0). */
const Body: React.FC<{L: ReturnType<typeof reportLayout>; allergies: 'missing' | 'filled'; allergyChars?: number; format: ReportFormat; writing: boolean}> = ({L, allergies, allergyChars, format, writing}) => {
  const filled = allergies === 'filled';
  const aN = allergyChars === undefined ? ALLERGY_TEXT.length : Math.max(0, Math.min(ALLERGY_TEXT.length, Math.floor(allergyChars)));
  const typing = filled && aN < ALLERGY_TEXT.length;
  const soap = L.soap;
  return (
    <>
      <Head y={L.handoffHead}>Nurse handoff</Head>
      {HANDOFF.map(([label, value], i) => (
        <React.Fragment key={label}>
          <Label y={L.rows[i].label}>{label}</Label>
          <T x={X0} y={L.rows[i].value} size={35} weight={500}>{value}</T>
          <Divider y={L.rows[i].div} />
        </React.Fragment>
      ))}
      {filled ? (
        <>
          <Label y={L.rows[3].label}>Allergies</Label>
          <Box x={X0} y={L.rows[3].value - 22} h={44} style={{display: 'flex', alignItems: 'center', fontFamily: GEIST, fontSize: 35, fontWeight: 500, color: C.ink, whiteSpace: 'pre'}}>
            {ALLERGY_TEXT.slice(0, aN)}
            {typing && <span style={{display: 'inline-block', width: 3, height: 44, marginLeft: 2, borderRadius: 2, background: C.ink}} />}
          </Box>
          <Divider y={L.allergyDiv} />
        </>
      ) : (
        <>
          <Label y={L.rows[3].label} color={C.yellow}>Allergies: not heard</Label>
          <T x={X0} y={L.rows[3].value} size={36.2} weight={400} color="#8C8A86">Add it, or leave blank and ask</T>
          <div style={{position: 'absolute', left: X0, top: L.allergyDiv + 1, width: X1 - X0, borderTop: `2.5px dotted ${C.yellow}`, opacity: 0.8}} />
        </>
      )}
      {L.signed && (
        <>
          <Head y={L.sigHead}>Signature</Head>
          <div style={{position: 'absolute', left: X0, top: L.sigTop}}><Signature width={SIG_W} strokeWidth={6.5} /></div>
          <T x={X0} y={L.sigText} size={21} weight={600} color={C.green}>Signed 02:11</T>
        </>
      )}
      {/* PCR */}
      <Head y={L.pcrHead}>PCR</Head>
      <Label y={L.fmtLabel}>Narrative format</Label>
      <div style={{position: 'absolute', left: X0, top: L.segTop, width: 616, height: 76, borderRadius: 38, background: '#151517', border: '1.5px solid #232326', boxSizing: 'border-box'}} />
      {FORMATS.map((f) => {
        const on = f.name === format;
        if (on) return <Pill key={f.name} x={f.cx - f.w / 2} y={L.segTop + 6} w={f.w} h={64} size={25} fill={writing ? '#57575A' : C.paper} color={writing ? '#9A9894' : C.black}>{f.name}</Pill>;
        return <T key={f.name} x={f.cx} y={L.segTop + 38} size={25} weight={600} color={writing ? '#5E5D5A' : C.dim} center>{f.name}</T>;
      })}
      {writing
        ? <T x={X0} y={L.caption} size={22.5} weight={500} color={C.yellow}>Writing the narrative as {format} on this iPad. The rest of the report is unchanged.</T>
        : <T x={X0} y={L.caption} size={23.5} color={C.dim}>{format === 'SOAP' ? 'Subjective, Objective, Assessment, Plan' : 'A short account in plain sentences'}</T>}
      <Label y={L.colLabel}>Dispatch and scene</Label>
      <Lines x={X0} y0={L.colLine0} lines={DISPATCH} />
      <Label x={XR} y={L.colLabel}>Vitals by time</Label>
      <Timed x={XR} y0={L.colLine0} items={VITALS} />
      <Label y={L.nLabel}>{soap ? 'Narrative, SOAP' : 'Narrative'}</Label>
      {soap
        ? L.soapBlocks.map((b) => (
          <React.Fragment key={b.cap}>
            <T x={X0} y={b.label} size={17} weight={600} color={C.dim} style={{letterSpacing: '0.04em'}}>{b.cap}</T>
            <Lines x={X0} y0={b.line0} lines={b.lines} />
          </React.Fragment>
        ))
        : <Lines x={X0} y0={L.nLine0} lines={PLAIN} />}
      <Label x={XR} y={L.nLabel}>Treatment by time</Label>
      <Timed x={XR} y0={L.nLine0} items={TREAT} />
      {/* Transcript */}
      <Head y={L.trHead}>Transcript</Head>
      {!L.signed && <T x={X0} y={L.dropped} size={22.5} color={C.dim}>Dropped a mark by accident? Swipe it left to delete it.</T>}
      <T x={X0} y={L.rec} size={22.5} weight={600} color={C.ink}>Recording 1, 1 min, 2 marks</T>
      <div style={{position: 'absolute', left: 578, top: L.rec, width: X1 - 578, height: 1.5, background: '#2A2A2D'}} />
      {L.tRows.map((r) => r.l.mark ? (
        <React.Fragment key={r.i}>
          <T x={X0} y={r.top + 34} size={24.5} color={GREY_T}>{r.l.t}</T>
          <Box x={392} y={r.top + 34 - 16} h={32} style={{display: 'flex', alignItems: 'center', gap: 10}}>
            <Flag size={28} color={C.yellow} />
            <span style={{fontFamily: DOTO, fontWeight: 800, fontSize: 28, color: C.yellow, letterSpacing: '0.01em'}}>Mark {r.l.mark}</span>
          </Box>
          <div style={{position: 'absolute', left: 548, top: r.top + 33, width: X1 - 548, borderTop: `2.5px dotted ${C.yellow}`, opacity: 0.6}} />
        </React.Fragment>
      ) : (
        <React.Fragment key={r.i}>
          <T x={X0} y={r.top + 27} size={24.5} color={GREY_T}>{r.l.t}</T>
          {r.lines.map((ln, k) => <T key={k} x={392} y={r.top + 27 + k * TL} size={33} weight={500}>{ln}</T>)}
        </React.Fragment>
      ))}
    </>
  );
};

/** The report sheet over a dimmed AI Drafts screen. */
export const ReportSheet: React.FC<ReportProps> = ({scroll = 0, rise = 1, signed = false, allergies = 'missing', allergyChars, format = 'Plain', writing = false, signPress = 0, hideButton = false}) => {
  const L = reportLayout({signed, format, writing});
  const r = Math.max(0, Math.min(1, rise));
  const button = writing ? 'Writing the narrative' : signed ? 'Copy PCR' : 'Sign off';
  return (
    <div style={{position: 'absolute', left: 0, top: 0, width: SW, height: SH, overflow: 'hidden', background: '#000'}}>
      <div style={{position: 'absolute', inset: 0, opacity: 1 - 0.6 * r}}><Drafts state={signed ? 'signed' : 'ready'} /></div>
      <div style={{position: 'absolute', left: 0, top: 0, width: SW, height: SH, transform: `translateY(${(1 - r) * SH}px)`}}>
        <div style={{position: 'absolute', left: SHEET.x, top: SHEET.y, width: SHEET.w, height: SHEET.h, borderRadius: 48, background: '#0C0C0E', border: '1.5px solid #151518', boxSizing: 'border-box', boxShadow: '0 -10px 60px rgba(0,0,0,0.5)'}} />
        <div style={{position: 'absolute', left: 863, top: 57, width: 89, height: 5, borderRadius: 5, background: '#52505B'}} />
        {/* header */}
        <T x={X0 - 3} y={138} size={59} weight={800} doto>18 Nov, 02:04</T>
        {signed ? (
          <>
            <Pill x={1223} y={102} w={138} h={65} outline size={26}>Edit</Pill>
            <Pill x={1387} y={102} w={156} h={65} outline size={26}>Done</Pill>
          </>
        ) : <Pill x={1382} y={102} w={161} h={65} outline size={26}>Close</Pill>}
        <T x={X0} y={200} size={23} color={C.dim}>{signed ? '1 recording, 1 min' : 'AI draft, not signed. Tap any line to correct it. Yellow lines need you.'}</T>
        {/* scrolling body */}
        <div style={{position: 'absolute', left: 0, top: CLIP.top, width: SW, height: CLIP.bottom - CLIP.top, overflow: 'hidden'}}>
          <div style={{position: 'absolute', left: 0, top: -CLIP.top - scroll, width: SW, height: L.end + 200}}>
            <Body L={L} allergies={allergies} allergyChars={allergyChars} format={format} writing={writing} />
          </div>
        </div>
        {!hideButton && <Pill x={BTN.x} y={BTN.y} w={BTN.w} h={BTN.h} size={30} press={signPress}>{button}</Pill>}
      </div>
    </div>
  );
};
