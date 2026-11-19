export const C = {
  bg: '#0B0B0D', card: '#151517', card2: '#101012', line: '#29292C', ink: '#F1EFEA', dim: '#A5A39E',
  faint: '#6C6B67', red: '#EF3B4A', yellow: '#F6C33A', green: '#3EDC85', paper: '#F1EFEA', black: '#0C0C0D',
};
export const DOTO = 'Doto, ui-monospace, monospace';
export const GEIST = 'Geist, system-ui, sans-serif';
export const FPS = 30;
export const BEAT = 15; // frames at 120 bpm
export const s = (sec: number) => Math.round(sec * FPS);
// native size of the rebuilt iPad screens (matches the reference frames)
export const SW = 1815, SH = 1251;
