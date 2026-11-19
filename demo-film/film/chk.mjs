// usage: node chk.mjs COMP name f1 f2 ...  → renders frames at half size with one browser, then tiles them into out/chk/name.jpg
import {bundle} from '@remotion/bundler';
import {renderStill, selectComposition, openBrowser} from '@remotion/renderer';
import {execFileSync} from 'node:child_process';
import fs from 'node:fs';
const [comp, name, ...frames] = process.argv.slice(2);
const serveUrl = await bundle({entryPoint: 'src/index.ts', outDir: '/tmp/earshot-bundle'});
const bopts = fs.existsSync('/usr/bin/google-chrome') ? {browserExecutable: '/usr/bin/google-chrome', chromeMode: 'chrome-for-testing', chromiumOptions: {gl: 'swangle'}} : {};
const browser = await openBrowser('chrome', bopts);
const composition = await selectComposition({serveUrl, id: comp, puppeteerInstance: browser, ...(bopts.chromeMode ? {chromeMode: bopts.chromeMode} : {})});
const files = [];
for (const fr of frames) {
  const out = `out/chk/${name}_${String(fr).padStart(4, '0')}.jpg`;
  await renderStill({composition, serveUrl, output: out, frame: Number(fr), scale: 0.5, imageFormat: 'jpeg', jpegQuality: 85, puppeteerInstance: browser, ...(bopts.chromeMode ? {chromeMode: bopts.chromeMode} : {})});
  files.push(out);
}
await browser.close({silent: true});
const args = ['-v', 'error', '-y']; for (const f of files) args.push('-i', f);
const rows = Math.ceil(files.length / 3);
args.push('-filter_complex', `concat=n=${files.length}:v=1:a=0,tile=3x${rows}`, '-frames:v', '1', '-q:v', '3', `out/chk/${name}.jpg`);
execFileSync('ffmpeg', args);
console.log('ok', name, files.length);
