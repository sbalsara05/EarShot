import React from 'react';
import {AbsoluteFill, Composition} from 'remotion';
import {StlTest} from './StlTest';
import {loadFonts} from './lib/fonts';
import {LiveCall} from './screens/LiveCall';
import {ClipScreen} from './screens/ClipScreen';
import {Home} from './screens/Home';
import {SH, SW} from './theme';
import {Film, TOTAL} from './Film';
loadFonts();
const Wrap: React.FC<{children: React.ReactNode}> = ({children}) => <AbsoluteFill style={{background: '#000'}}>{children}</AbsoluteFill>;
export const Root: React.FC = () => (
  <>
    <Composition id="FilmB" component={Film} defaultProps={{emt: false}} durationInFrames={TOTAL} fps={30} width={1920} height={1080} />
    <Composition id="FilmA" component={Film} defaultProps={{emt: true}} durationInFrames={TOTAL} fps={30} width={1920} height={1080} />
    <Composition id="StlTest" component={StlTest} durationInFrames={60} fps={30} width={1920} height={1080} />
    <Composition id="ScrLive" component={() => <Wrap><LiveCall seconds={55} state="recording" shown={9} typing={0.9} t={200} /></Wrap>} durationInFrames={1} fps={30} width={SW} height={SH} />
    <Composition id="ScrClip" component={() => <Wrap><ClipScreen state="connected" /></Wrap>} durationInFrames={1} fps={30} width={SW} height={SH} />
    <Composition id="ScrLook" component={() => <Wrap><ClipScreen state="found" scan={0.4} /></Wrap>} durationInFrames={1} fps={30} width={SW} height={SH} />
    <Composition id="ScrHome" component={() => <Wrap><Home /></Wrap>} durationInFrames={1} fps={30} width={SW} height={SH} />
  </>
);
