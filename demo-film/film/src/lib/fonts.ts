import {continueRender, delayRender, staticFile} from 'remotion';
let started = false;
export const loadFonts = () => {
  if (started || typeof document === 'undefined') return;
  started = true;
  const h = delayRender('fonts');
  const defs: [string, string, string][] = [];
  for (const w of [400, 500, 600, 700, 800, 900]) defs.push(['Doto', String(w), `fonts/doto-latin-${w}-normal.woff2`]);
  for (const w of [400, 500, 600, 700]) defs.push(['Geist', String(w), `fonts/geist-latin-${w}-normal.woff2`]);
  Promise.all(defs.map(([fam, weight, file]) => {
    const f = new FontFace(fam, `url(${staticFile(file)}) format('woff2')`, {weight});
    return f.load().then((l) => { (document.fonts as any).add(l); });
  })).then(() => continueRender(h)).catch((e) => { console.error(e); continueRender(h); });
};
