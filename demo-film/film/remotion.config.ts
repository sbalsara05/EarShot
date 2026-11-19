import {Config} from '@remotion/cli/config';
import {existsSync} from 'fs';
// On the Linux box this was built on, Chrome lives here and has no GPU. Anywhere else Remotion uses its own browser.
if (existsSync('/usr/bin/google-chrome')) {
  Config.setBrowserExecutable('/usr/bin/google-chrome');
  Config.setChromeMode('chrome-for-testing');
  Config.setChromiumOpenGlRenderer('swangle');
}
Config.setVideoImageFormat('jpeg');
Config.setJpegQuality(92);
Config.setConcurrency(2);
