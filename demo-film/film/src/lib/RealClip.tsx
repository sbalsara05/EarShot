import React, {useEffect, useState} from 'react';
import {continueRender, delayRender, staticFile} from 'remotion';
import {ThreeCanvas} from '@remotion/three';
import * as THREE from 'three';
import {STLLoader} from 'three/examples/jsm/loaders/STLLoader.js';
const PARTS = ['frame_1led', 'light_cap_1led', 'clip', 'module_atom_voices3r_reference'] as const;
let cache: Promise<THREE.BufferGeometry[]> | null = null;
const load = () => (cache ??= Promise.all(PARTS.map((p) => fetch(staticFile(`stl/${p}.stl`)).then((r) => r.arrayBuffer()).then((b) => { const g = new STLLoader().parse(b); g.computeVertexNormals(); return g; }))));
/** The printed clip, drawn from the team's STL files. x/y are the centre in frame pixels, `size` its height in pixels. */
export const RealClip: React.FC<{x: number; y: number; size: number; rx?: number; ry?: number; rz?: number; glow?: number; opacity?: number; press?: number}> = ({x, y, size, rx = 0, ry = 0, rz = 0, glow = 1, opacity = 1, press = 0}) => {
  const [geo, setGeo] = useState<THREE.BufferGeometry[] | null>(null);
  const [h] = useState(() => delayRender('stl'));
  useEffect(() => { load().then((g) => { setGeo(g); continueRender(h); }); }, [h]);
  const k = (size / 34) * (1 - 0.04 * press);
  return (
    <div style={{position: 'absolute', inset: 0, opacity}}>
      <ThreeCanvas width={1920} height={1080} orthographic camera={{position: [0, 0, 1000], near: 1, far: 4000, zoom: 1}} gl={{alpha: true, antialias: true}} style={{background: 'transparent'}}>
        <ambientLight intensity={0.55} />
        <directionalLight position={[-300, 500, 800]} intensity={2.3} />
        <directionalLight position={[600, -200, 300]} intensity={0.7} color="#ffd9d0" />
        <directionalLight position={[0, 300, -600]} intensity={1.6} />
        <directionalLight position={[100, 100, 900]} intensity={1.1} />
        {geo && (
          <group position={[x - 960, 540 - y, 0]} rotation={[rx, ry, rz]} scale={[k, k, k]}>
            <group position={[0, -1.7, -5]}>
              <mesh geometry={geo[0]}><meshStandardMaterial color="#ECE9E2" roughness={0.75} metalness={0} /></mesh>
              <mesh geometry={geo[2]}><meshStandardMaterial color="#D9D6CE" roughness={0.8} /></mesh>
              <mesh geometry={geo[3]}><meshStandardMaterial color="#3A3A40" roughness={0.5} metalness={0.1} /></mesh>
              <mesh geometry={geo[1]}><meshStandardMaterial color="#EF3B4A" emissive="#EF3B4A" emissiveIntensity={0.25 + 2.2 * glow} roughness={0.4} /></mesh>
              <pointLight position={[0, 20, 12]} color="#EF3B4A" intensity={900 * glow} distance={60} />
            </group>
          </group>
        )}
      </ThreeCanvas>
    </div>
  );
};
