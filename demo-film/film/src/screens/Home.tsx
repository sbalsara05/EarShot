import React from 'react';
import {C, DOTO} from '../theme';
import {Box, Card, Dot, Pill, Screen, T, TopBar} from './kit';
import {ClipArt} from './ClipArt';
export const Home: React.FC<{press?: number; reveal?: number; turn?: number}> = ({press = 0, reveal = 1, turn = 0.35}) => {
  const word = 'Ready'.slice(0, Math.max(0, Math.round(5 * reveal)));
  return (
    <Screen>
      <TopBar tab="Home" />
      <Box x={62} y={340} style={{fontFamily: DOTO, fontWeight: 900, fontSize: 262, lineHeight: 1, color: C.ink, letterSpacing: '0.01em'}}>{word}</Box>
      <T x={70} y={642} size={28} color={C.dim} w={560} style={{lineHeight: 1.5}}>Your clip is connected. Start a call when you're on scene.</T>
      <Pill x={70} y={716} w={326} h={96} press={press}><span style={{width: 15, height: 15, borderRadius: 15, background: C.red}} />New call</Pill>
      <Card x={946} y={115} w={528} h={890}>
        <ClipArt cx={264} cy={380} scale={0.92} turn={turn} />
        <T x={264} y={642} size={40} weight={700} doto center>Earshot-A3F2</T>
        <Box x={264 - 80} y={676} w={160} style={{display: 'flex', justifyContent: 'center', alignItems: 'center', gap: 10}}><span style={{width: 12, height: 12, borderRadius: 12, background: C.green}} /><span style={{fontFamily: 'Geist', fontSize: 24, color: C.green, fontWeight: 500}}>Connected</span></Box>
      </Card>
    </Screen>
  );
};
