import React from 'react';
import {AbsoluteFill, Sequence} from 'remotion';
import {loadFonts} from './lib/fonts';
import {IntroConnect} from './scenes/IntroConnect';
import {Hear} from './scenes/Hear';
import {Mark} from './scenes/Mark';
import {Draft} from './scenes/Draft';
import {Sign} from './scenes/Sign';
import {Send} from './scenes/Send';
loadFonts();
export const TOTAL = 2940;
export const Film: React.FC<{emt?: boolean}> = ({emt}) => (
  <AbsoluteFill style={{background: '#050506'}}>
    <Sequence from={0} durationInFrames={600}><IntroConnect emt={emt} /></Sequence>
    <Sequence from={600} durationInFrames={660}><Hear /></Sequence>
    <Sequence from={1260} durationInFrames={420}><Mark emt={emt} /></Sequence>
    <Sequence from={1680} durationInFrames={480}><Draft /></Sequence>
    <Sequence from={2160} durationInFrames={300}><Sign emt={emt} /></Sequence>
    <Sequence from={2460} durationInFrames={480}><Send /></Sequence>
  </AbsoluteFill>
);
