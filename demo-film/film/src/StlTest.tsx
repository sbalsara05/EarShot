import React, {useEffect, useState} from 'react';
import {AbsoluteFill, continueRender, delayRender, staticFile, useCurrentFrame} from 'remotion';
import {ThreeCanvas} from '@remotion/three';
import * as THREE from 'three';
import {STLLoader} from 'three/examples/jsm/loaders/STLLoader.js';
import {loadFonts} from './lib/fonts';
import {C, DOTO, GEIST} from './theme';
loadFonts();
const parts = ['frame_1led', 'light_cap_1led', 'clip', 'module_atom_voices3r_reference', 'frame_3led', 'light_cap_3led'];
const cols = ['#e8e6e0', '#ff5050', '#888', '#3a7', '#e8e6e0', '#ff5050'];
export const StlTest: React.FC = () => {
  const f = useCurrentFrame();
  const [geo, setGeo] = useState<THREE.BufferGeometry[] | null>(null);
  const [h] = useState(() => delayRender('stl'));
  useEffect(() => {
    const l = new STLLoader();
    Promise.all(parts.map((p) => fetch(staticFile(`stl/${p}.stl`)).then((r) => r.arrayBuffer()).then((b) => { const g = l.parse(b); g.computeVertexNormals(); return g; })))
      .then((g) => { setGeo(g); continueRender(h); });
  }, []);
  return (
    <AbsoluteFill style={{background: C.bg}}>
      <ThreeCanvas width={1920} height={1080} orthographic={false} camera={{fov: 30, position: [0, 0, 160]}}>
        <ambientLight intensity={0.6} />
        <directionalLight position={[50, 80, 100]} intensity={2} />
        {geo && [0, 1].map((v) => (
          <group key={v} position={[v ? 30 : -30, 0, 0]} rotation={[-1.1 + (v ? 0.4 : 0), 0, f * 0.05 + v * 3.14]}>
            {(v ? [4, 5, 2, 3] : [0, 1, 2, 3]).map((i) => (
              <mesh key={i} geometry={geo[i]}><meshStandardMaterial color={cols[i]} roughness={0.6} /></mesh>
            ))}
          </group>
        ))}
      </ThreeCanvas>
      <div style={{position: 'absolute', left: 60, top: 40, color: C.ink, fontFamily: DOTO, fontWeight: 900, fontSize: 120}}>Ready 00:55</div>
      <div style={{position: 'absolute', left: 60, top: 200, color: C.ink, fontFamily: DOTO, fontWeight: 600, fontSize: 60}}>Earshot-A3F2 Nurse handoff</div>
      <div style={{position: 'absolute', left: 60, top: 300, color: C.dim, fontFamily: GEIST, fontWeight: 500, fontSize: 40}}>Medic 14 on scene, 68 year old male</div>
    </AbsoluteFill>
  );
};
