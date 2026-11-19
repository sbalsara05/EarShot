import React from 'react';
import {C, SH, SW} from '../theme';
import {Rect} from './anim';
export const FULL: Rect = {x: 0, y: 0, w: SW, h: SH};
/** Rect with the film's 16:9 shape centred on (cx, cy) and `w` wide. */
export const view = (cx: number, cy: number, w: number): Rect => ({x: cx - w / 2, y: cy - (w * 9) / 32, w, h: (w * 9) / 16});
/** Where a screen point lands in the 1920x1080 frame for a given view. */
export const project = (v: Rect, x: number, y: number) => {
  const k = Math.min(1920 / v.w, 1080 / v.h);
  return {x: 960 + (x - (v.x + v.w / 2)) * k, y: 540 + (y - (v.y + v.h / 2)) * k, k};
};
/** A camera over a rebuilt screen. `view` is the part of the screen that fills the frame.
 *  `focus` keeps one rectangle sharp and bright while `amt` (0..1) blurs and dims the rest. */
export const Stage: React.FC<{view: Rect; focus?: Rect | null; amt?: number; blur?: number; dim?: number; opacity?: number; radius?: number; children: React.ReactNode}> = ({view: v, focus, amt = 0, blur = 9, dim = 0.62, opacity = 1, radius = 22, children}) => {
  const k = Math.min(1920 / v.w, 1080 / v.h);
  const tx = 960 - (v.x + v.w / 2) * k, ty = 540 - (v.y + v.h / 2) * k;
  const box: React.CSSProperties = {position: 'absolute', left: 0, top: 0, width: SW, height: SH, transformOrigin: '0 0', transform: `translate(${tx}px, ${ty}px) scale(${k})`};
  return (
    <div style={{position: 'absolute', inset: 0, overflow: 'hidden', background: C.bg, opacity}}>
      <div style={{...box, filter: amt > 0.001 ? `blur(${blur * amt}px) brightness(${1 - dim * amt})` : undefined}}>{children}</div>
      {focus && amt > 0.001 ? (
        <div style={{...box, clipPath: `inset(${focus.y}px ${SW - focus.x - focus.w}px ${SH - focus.y - focus.h}px ${focus.x}px round ${radius}px)`}}>{children}</div>
      ) : null}
    </div>
  );
};
