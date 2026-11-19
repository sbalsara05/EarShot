import React from 'react';
import {C, DOTO} from '../theme';
import {Card, Dot, Legend, Pill, Screen, T, TopBar} from './kit';
import {ClipArt} from './ClipArt';
export type ClipProps = {
  state: 'looking' | 'found' | 'connecting' | 'connected';
  scan?: number;      // 0..1 position of the scanning line
  appear?: number;    // 0..1 the drawn clip filling in on connect
  rows?: number;      // how many detail rows have landed (0..4)
  turn?: number; press?: number; hideClip?: boolean; legendHot?: number; tapRow?: number;
};
export const ClipScreen: React.FC<ClipProps> = ({state, scan = 0, appear = 1, rows = 4, turn = 0.35, press = 0, hideClip, legendHot = -1, tapRow = 0}) => {
  const connected = state === 'connected';
  return (
    <Screen>
      <TopBar tab="Clip" clip={connected} />
      <Card x={48} y={139} w={1040} h={1063}>
        {!hideClip && !connected && <ClipArt cx={520} cy={500} ghost turn={0.35} />}
        {!hideClip && connected && <ClipArt cx={520} cy={500} turn={turn} press={press} opacity={appear} scale={0.9 + 0.1 * appear} />}
        {!connected && (
          <div style={{position: 'absolute', left: 520 - 150, top: 330 + scan * 340, width: 300, borderTop: `7px dotted ${C.ink}`}} />
        )}
        <T x={520} y={822} size={26} color={C.dim} center>{connected ? 'Tilt the iPad to look around the clip' : state === 'connecting' ? 'Connecting' : 'Looking for clips nearby'}</T>
      </Card>
      <Card x={1138} y={139} w={628} h={1063}>
        {connected ? (
          <>
            <T x={47} y={80} size={50} weight={700} doto>Earshot-A3F2</T>
            <Dot x={55} y={144} d={15} color={C.green} /><T x={77} y={144} size={28} color={C.green}>Connected</T>
            {[200, 311, 422, 533].map((yy, i) => <div key={i} style={{position: 'absolute', left: 47, top: yy, width: 533, borderTop: `1.5px solid ${C.line}`}} />)}
            {rows >= 1 && (<><T x={47} y={251} size={26} color={C.dim}>Signal</T>{[0, 1, 2, 3].map((i) => <Dot key={i} x={266 + i * 22} y={251} d={15} />)}<T x={360} y={251} size={30} weight={700} doto>Strong</T><T x={580 - 628 + 1815} y={251} size={22} color={C.faint} right>-49 dBm</T></>)}
            {rows >= 2 && (<><T x={47} y={362} size={26} color={C.dim}>Link</T><T x={580 - 628 + 1815} y={362} size={30} weight={700} doto right>Bluetooth</T></>)}
            {rows >= 3 && (<><T x={47} y={473} size={26} color={C.dim}>Audio from</T><T x={580 - 628 + 1815} y={473} size={30} weight={700} doto right style={{textDecoration: 'underline', textUnderlineOffset: 6}}>Clip</T></>)}
            {rows >= 4 && (<><T x={47} y={581} size={22} weight={600} color={C.dim}>Clip button</T><Legend x={47} y={629} rows={[['Click', 'Mark the moment'], ['Double click', 'Pause or resume'], ['Hold', 'End the call, or start one']]} hot={legendHot} /></>)}
            <Pill x={47} y={792} w={533} h={100}>Find clip</Pill>
            <Pill x={47} y={915} w={533} h={100} outline>Disconnect</Pill>
          </>
        ) : (
          <>
            <T x={47} y={118} size={62} weight={700} doto w={500} style={{lineHeight: 1.12}}>{state === 'connecting' ? 'Connecting' : (<>Looking<br />for clips</>)}</T>
            <T x={47} y={236} size={24} color={C.dim} w={520} style={{lineHeight: 1.5}}>{state === 'connecting' ? 'Waiting for Earshot clip to answer. It reconnects by itself when it is on and in range.' : 'Power the clip on and keep it close. Until it connects, calls record on the iPad mic.'}</T>
            {state !== 'connecting' && <T x={47} y={318} size={20} weight={600} color={C.dim}>{state === 'found' ? 'Nearby: tap a clip to connect' : 'Nearby: none yet'}</T>}
            {state !== 'connecting' && <div style={{position: 'absolute', left: 47, top: 342, width: 533, borderTop: `1.5px solid ${C.line}`}} />}
            {state === 'found' && (
              <div style={{position: 'absolute', left: 30, top: 356, width: 568, height: 92, borderRadius: 22, background: tapRow ? `rgba(241,239,234,${0.12 * tapRow})` : 'transparent'}}>
                <div style={{position: 'absolute', left: 22, top: 20, width: 34, height: 52, borderRadius: 10, border: `2.5px solid ${C.ink}`, boxSizing: 'border-box'}}><div style={{position: 'absolute', left: 9, top: 22, width: 11, height: 11, borderRadius: 11, border: `2px solid ${C.ink}`, boxSizing: 'border-box'}} /></div>
                <T x={84} y={46} size={34} weight={700} doto>Earshot-A3F2</T>
                {[0, 1, 2, 3].map((i) => <Dot key={i} x={478 + i * 22} y={46} d={13} />)}
              </div>
            )}
            <Pill x={47} y={915} w={533} h={100} outline>{state === 'connecting' ? 'Forget this clip' : 'Stop looking'}</Pill>
          </>
        )}
      </Card>
    </Screen>
  );
};
