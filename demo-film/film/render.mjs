// usage: node render.mjs COMP start end outfile   (inclusive frame range) – one bundle reused across calls via /tmp/earshot-bundle
import {bundle} from '@remotion/bundler';
import {renderMedia, selectComposition} from '@remotion/renderer';
import fs from 'node:fs';
const [comp, a, b, out] = process.argv.slice(2);
const dir = (process.env.TMPDIR || '/tmp') + '/earshot-bundle-r';
const serveUrl = process.env.REUSE && fs.existsSync(dir + '/index.html') ? dir : await bundle({entryPoint: 'src/index.ts', outDir: dir});
const opts = fs.existsSync('/usr/bin/google-chrome') ? {browserExecutable: '/usr/bin/google-chrome', chromeMode: 'chrome-for-testing', chromiumOptions: {gl: 'swangle'}} : {};
const composition = await selectComposition({serveUrl, id: comp, ...opts});
const t0 = Date.now();
const tmp = out.replace(/\.mp4$/, '.part.mp4');
await renderMedia({composition, serveUrl, codec: 'h264', outputLocation: tmp, frameRange: [Number(a), Number(b)], crf: 17, pixelFormat: 'yuv420p', imageFormat: 'jpeg', jpegQuality: 92, concurrency: Number(process.env.CONC || 2), muted: true, x264Preset: 'veryfast', ...opts});
fs.renameSync(tmp, out);
console.log(out, 'frames', b - a + 1, 'secs', ((Date.now() - t0) / 1000).toFixed(1));
