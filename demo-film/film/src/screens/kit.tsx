import React from 'react';
import {C, DOTO, GEIST, SH, SW} from '../theme';

/** Absolutely positioned box in screen coordinates. */
export const Box: React.FC<{x: number; y: number; w?: number; h?: number; style?: React.CSSProperties; children?: React.ReactNode}> = ({x, y, w, h, style, children}) => (
  <div style={{position: 'absolute', left: x, top: y, width: w, height: h, ...style}}>{children}</div>
);
export const Card: React.FC<{x: number; y: number; w: number; h: number; r?: number; style?: React.CSSProperties; children?: React.ReactNode}> = ({x, y, w, h, r = 44, style, children}) => (
  <div style={{position: 'absolute', left: x, top: y, width: w, height: h, borderRadius: r, background: C.card, border: `1.5px solid ${C.line}`, boxSizing: 'border-box', overflow: 'hidden', ...style}}>{children}</div>
);
/** A line of text placed by its left edge and vertical centre. */
export const T: React.FC<{x: number; y: number; size?: number; w?: number; weight?: number; color?: string; doto?: boolean; right?: boolean; center?: boolean; style?: React.CSSProperties; children?: React.ReactNode}> = ({x, y, size = 26, w, weight = 500, color = C.ink, doto, right, center, style, children}) => (
  <div style={{position: 'absolute', left: right ? undefined : center ? x - 600 : x, right: right ? SW - x : undefined, width: center ? 1200 : w, textAlign: center ? 'center' : right ? 'right' : 'left', top: y, transform: 'translateY(-50%)', fontFamily: doto ? DOTO : GEIST, fontSize: size, fontWeight: weight, color, whiteSpace: w ? 'normal' : 'nowrap', lineHeight: 1.25, letterSpacing: doto ? '0.01em' : '-0.005em', ...style}}>{children}</div>
);
export const Dot: React.FC<{x: number; y: number; d?: number; color?: string; style?: React.CSSProperties}> = ({x, y, d = 14, color = C.ink, style}) => (
  <div style={{position: 'absolute', left: x - d / 2, top: y - d / 2, width: d, height: d, borderRadius: d, background: color, ...style}} />
);
export const Pill: React.FC<{x: number; y: number; w: number; h: number; fill?: string; outline?: boolean; color?: string; size?: number; press?: number; style?: React.CSSProperties; children?: React.ReactNode}> = ({x, y, w, h, fill = C.paper, outline, color, size = 30, press = 0, style, children}) => (
  <div style={{position: 'absolute', left: x, top: y, width: w, height: h, borderRadius: h, background: outline ? 'transparent' : fill, border: outline ? `2px solid ${C.faint}` : 'none', boxSizing: 'border-box', display: 'flex', alignItems: 'center', justifyContent: 'center', gap: 14, fontFamily: GEIST, fontWeight: 600, fontSize: size, color: color ?? (outline ? C.ink : C.black), transform: `scale(${1 - 0.05 * press})`, filter: press ? `brightness(${1 - 0.15 * press})` : undefined, ...style}}>{children}</div>
);
export const Flag: React.FC<{size?: number; color?: string}> = ({size = 30, color = C.black}) => (
  <svg width={size} height={size} viewBox="0 0 24 24" fill="none" stroke={color} strokeWidth={2.6} strokeLinecap="round" strokeLinejoin="round"><path d="M6 21V4h11l-2.5 4L17 12H6" /></svg>
);
/** The dotted-ring logo and wordmark. */
export const Logo: React.FC<{x?: number; y?: number; scale?: number; color?: string}> = ({x = 48, y = 36, scale = 1, color = C.ink}) => (
  <div style={{position: 'absolute', left: x, top: y, transform: `scale(${scale})`, transformOrigin: '0 0', display: 'flex', alignItems: 'center', gap: 18}}>
    <svg width={56} height={56} viewBox="0 0 56 56">
      <circle cx={28} cy={28} r={23} fill="none" stroke={color} strokeWidth={4.5} strokeDasharray="1 8.03" strokeLinecap="round" transform="rotate(-140 28 28)" pathLength={144.5} />
      <circle cx={28} cy={28} r={12.5} fill="none" stroke={color} strokeWidth={4} strokeDasharray="0.1 7.75" strokeLinecap="round" />
      <circle cx={28} cy={29} r={3.4} fill={C.red} />
    </svg>
    <div style={{fontFamily: DOTO, fontWeight: 800, fontSize: 46, color, letterSpacing: '0.02em', marginTop: -6}}>earshot</div>
  </div>
);
export type Tab = 'Home' | 'Live Call' | 'AI Drafts' | 'Clip';
const TABS: {name: Tab; cx: number; w: number}[] = [
  {name: 'Home', cx: 672, w: 128}, {name: 'Live Call', cx: 822, w: 158}, {name: 'AI Drafts', cx: 987, w: 164}, {name: 'Clip', cx: 1140, w: 132},
];
export const TopBar: React.FC<{tab: Tab; clip?: boolean; badge?: number; status?: React.ReactNode}> = ({tab, clip = true, badge, status}) => (
  <>
    <Logo />
    <div style={{position: 'absolute', left: 603, top: 25, width: 609, height: 76, borderRadius: 40, background: '#121214', border: `1.5px solid ${C.line}`, boxSizing: 'border-box'}} />
    {TABS.map((t) => {
      const on = t.name === tab;
      const w = t.name === 'AI Drafts' && badge ? t.w + 36 : t.w;
      return (
        <div key={t.name} style={{position: 'absolute', left: t.cx - w / 2, top: 30, width: w, height: 66, borderRadius: 34, background: on ? C.paper : 'transparent', display: 'flex', alignItems: 'center', justifyContent: 'center', gap: 10, fontFamily: GEIST, fontSize: 24, fontWeight: on ? 600 : 500, color: on ? C.black : C.dim}}>
          {t.name === 'Clip' && <span style={{width: 11, height: 11, borderRadius: 11, background: clip ? C.green : 'transparent', border: clip ? 'none' : `2px solid ${C.dim}`, boxSizing: 'border-box'}} />}
          {t.name}
          {t.name === 'AI Drafts' && badge ? <span style={{width: 26, height: 26, borderRadius: 26, background: C.yellow, color: C.black, fontSize: 17, fontWeight: 700, display: 'flex', alignItems: 'center', justifyContent: 'center'}}>{badge}</span> : null}
        </div>
      );
    })}
    {status ? <div style={{position: 'absolute', right: SW - 1766, top: 63, transform: 'translateY(-50%)', fontFamily: GEIST, fontSize: 24, fontWeight: 500, color: C.dim, display: 'flex', gap: 16, alignItems: 'center'}}>{status}</div> : null}
  </>
);
export const Screen: React.FC<{children?: React.ReactNode; style?: React.CSSProperties}> = ({children, style}) => (
  <div style={{position: 'absolute', left: 0, top: 0, width: SW, height: SH, background: C.bg, overflow: 'hidden', ...style}}>{children}</div>
);
/** The clip-button legend used on the Live Call and Clip screens. */
export const Legend: React.FC<{x: number; y: number; rows: [string, string][]; gap?: number; hot?: number; dimFirst?: boolean}> = ({x, y, rows, gap = 48, hot = -1, dimFirst}) => (
  <>
    {rows.map(([label, action], i) => {
      const o = dimFirst && i === 0 ? 0.35 : 1;
      const cy = y + i * gap;
      return (
        <React.Fragment key={i}>
          {i === 0 && <Dot x={x + 8} y={cy} d={15} style={{opacity: o}} />}
          {i === 1 && (<><Dot x={x + 8} y={cy} d={15} /><Dot x={x + 30} y={cy} d={15} /></>)}
          {i === 2 && <div style={{position: 'absolute', left: x, top: cy - 8, width: 40, height: 16, borderRadius: 8, background: C.ink}} />}
          <T x={x + 60} y={cy} size={24} color={C.dim} style={{opacity: o}}>{label}</T>
          <T x={x + 228} y={cy} size={26} weight={600} color={hot === i ? C.yellow : C.ink} style={{opacity: o}}>{action}</T>
        </React.Fragment>
      );
    })}
  </>
);
