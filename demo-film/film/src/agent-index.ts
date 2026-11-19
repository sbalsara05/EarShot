import {registerRoot} from 'remotion';
import {AgentPreview} from './AgentPreview';
import {loadFonts} from './lib/fonts';
loadFonts();
registerRoot(AgentPreview);
