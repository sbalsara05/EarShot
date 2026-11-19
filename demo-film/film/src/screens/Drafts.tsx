import React from 'react';
import {C, DOTO} from '../theme';
import {Box, Card, Dot, Screen, T, TopBar} from './kit';

export type DraftsState = 'writing' | 'ready' | 'signed';

/** Dot-matrix size of the big "To sign" / "All signed" title. */
const TITLE = 164;

/** The AI Drafts tab: big title on the left, the list card on the right. */
export const Drafts: React.FC<{state: DraftsState; reveal?: number}> = ({state, reveal = 1}) => {
  const signed = state === 'signed';
  const full = signed ? 'All\nsigned' : 'To sign';
  const n = Math.max(0, Math.min(full.length, Math.floor(full.length * reveal + 1e-6)));
  const shown = full.slice(0, n);
  return (
    <Screen>
      <TopBar tab="AI Drafts" badge={signed ? undefined : 1} />
      {signed ? (
        <Box x={82} y={433} style={{fontFamily: DOTO, fontWeight: 900, fontSize: TITLE, lineHeight: '202px', color: C.ink, letterSpacing: '0.01em', whiteSpace: 'pre'}}>{shown}</Box>
      ) : (
        <Box x={82} y={509} style={{fontFamily: DOTO, fontWeight: 900, fontSize: TITLE, lineHeight: '202px', color: C.ink, letterSpacing: '0.01em', whiteSpace: 'pre'}}>{shown}</Box>
      )}
      {signed ? (
        <T x={84} y={893} size={32.5} color={C.dim}>1 signed call. Tap one to read its reports.</T>
      ) : (
        <T x={84} y={792} size={30} w={700} color={C.dim} style={{lineHeight: '53px'}}>1 call waiting for you to check and sign.<br />Nothing is final until you do.</T>
      )}
      <Card x={1138} y={139} w={628} h={1062} r={48} style={{background: '#161618', border: `1.5px solid #222225`}} />
      <T x={1197} y={231} size={23} weight={600} color={signed ? C.dim : C.yellow}>{signed ? 'Signed' : 'Needs sign-off'}</T>
      {!signed && <Dot x={1192} y={315} d={14} color={C.yellow} />}
      <T x={signed ? 1185 : 1217} y={297} size={29.5} weight={500}>{state === 'writing' ? 'Call at 02:04' : state === 'ready' ? '68 year old male, ch…' : '68 year old male, chest…'}</T>
      <T x={signed ? 1185 : 1217} y={336} size={22.5} color={C.dim}>18 Nov, 02:04, 1 min</T>
      <T x={1718} y={315} size={23} weight={600} right color={signed ? C.green : C.yellow}>{state === 'writing' ? 'Writing reports' : state === 'ready' ? 'Check and sign' : 'Signed 02:11'}</T>
    </Screen>
  );
};
