import React from 'react';
import {AbsoluteFill, Composition} from 'remotion';
import {SH, SW} from './theme';
import {Drafts} from './screens/Drafts';
import {ReportSheet, REPORT_RECTS} from './screens/ReportSheet';
import {SignSheet} from './screens/SignSheet';

const W: React.FC<{children: React.ReactNode}> = ({children}) => <AbsoluteFill style={{background: '#000'}}>{children}</AbsoluteFill>;
const STILLS: Record<string, () => React.ReactElement> = {
  DraftsWriting: () => <Drafts state="writing" />,
  DraftsReady: () => <Drafts state="ready" />,
  DraftsSigned: () => <Drafts state="signed" />,
  RepTop: () => <ReportSheet />,
  RepAllergy: () => <ReportSheet scroll={360} allergies="filled" allergyChars={11} />,
  RepPcr: () => <ReportSheet scroll={726} allergies="filled" />,
  RepWriting: () => <ReportSheet scroll={726} allergies="filled" format="SOAP" writing />,
  RepSoap: () => <ReportSheet scroll={726} allergies="filled" format="SOAP" />,
  RepSoap2: () => <ReportSheet scroll={1250} allergies="filled" format="SOAP" />,
  RepTranscript: () => <ReportSheet scroll={REPORT_RECTS.transcript.scroll} allergies="filled" />,
  RepTranscript2: () => <ReportSheet scroll={2050} allergies="filled" />,
  RepSigned: () => <ReportSheet signed allergies="filled" scroll={REPORT_RECTS.signature.scroll} />,
  RepRects: () => <><ReportSheet allergies="filled" scroll={0} />{(['header','patient','vitals','given','allergies','signButton','handoff'] as const).map((k) => { const r = REPORT_RECTS[k]; return <div key={k} style={{position: 'absolute', left: r.x, top: r.y, width: r.w, height: r.h, border: '2px solid red', boxSizing: 'border-box'}} />; })}</>,
  Sign0: () => <><ReportSheet scroll={1900} allergies="filled" /><SignSheet draw={0} /></>,
  Sign5: () => <><ReportSheet scroll={1900} allergies="filled" /><SignSheet draw={0.5} /></>,
  Sign1: () => <><ReportSheet scroll={1900} allergies="filled" /><SignSheet draw={1} /></>,
};
const Rect: React.FC<{k: keyof typeof REPORT_RECTS; signed?: boolean}> = ({k, signed}) => { const r = REPORT_RECTS[k]; return <><ReportSheet allergies="filled" signed={signed} scroll={r.scroll} /><div style={{position: 'absolute', left: r.x, top: r.y, width: r.w, height: r.h, border: '3px solid red', boxSizing: 'border-box'}} /><div style={{position: 'absolute', left: 20, top: 1200, color: 'red', fontSize: 30}}>{k} scroll {r.scroll}</div></>; };
const Grid: React.FC<{items: React.ReactElement[]}> = ({items}) => (
  <AbsoluteFill style={{background: '#222'}}>{items.map((el, i) => (
    <div key={i} style={{position: 'absolute', left: (i % 2) * SW / 2, top: Math.floor(i / 2) * SH / 2, width: SW, height: SH, transform: 'scale(0.5)', transformOrigin: '0 0', overflow: 'hidden'}}>{el}</div>
  ))}</AbsoluteFill>
);
STILLS.GridRects1 = () => <Grid items={[<Rect k="format" />, <Rect k="vitalsByTime" />, <Rect k="narrative" />, <Rect k="treatmentByTime" />]} />;
STILLS.GridRects2 = () => <Grid items={[<Rect k="transcript" />, <Rect k="signature" signed />, <ReportSheet allergies="filled" scroll={REPORT_RECTS.transcript.scroll + 700} />, <ReportSheet allergies="filled" format="SOAP" scroll={1400} />]} />;
STILLS.GridMisc = () => <Grid items={[<Drafts state="ready" />, <Drafts state="writing" reveal={0.5} />, <><ReportSheet scroll={1900} allergies="filled" /><SignSheet draw={0} /></>, <><ReportSheet scroll={1900} allergies="filled" /><SignSheet draw={0.5} rise={0.6} /></>]} />;
export const AgentPreview: React.FC = () => (
  <>
    {Object.entries(STILLS).map(([id, C]) => (
      <Composition key={id} id={id} component={() => <W><C /></W>} durationInFrames={1} fps={30} width={SW} height={SH} />
    ))}
  </>
);
