# Earshot demo film

The 1:38 demo film from the pitch, as source. It is a Remotion project (React, drawn frame by frame), 1920x1080 at 30 fps, 2,940 frames. The app screens are rebuilt in React from the screen recordings; nothing in it is a screen capture.

Two cuts come from the same code:

- `FilmB` (own media): self-contained.
- `FilmA` (EMT slots): the same film with three bright blue areas where real footage goes (0:02 to 0:10 full frame, 0:42 to 0:52 left panel, 1:14 to 1:19 full frame).

## Run it

```bash
cd demo-film/film
npm install
npm run studio            # live preview in the browser; scrub and edit
npm run render:own        # out/film_own-media.mp4 (silent)
npm run render:slots      # out/film_EMT-slots.mp4 (silent)
```

Add the soundtrack to a silent render:

```bash
ffmpeg -i out/film_own-media.mp4 -i ../audio/mix.wav -map 0:v -map 1:a -c:v copy -c:a aac -b:a 192k -shortest -movflags +faststart out/film_own-media_sound.mp4
```

`render.mjs` renders a frame range (`node render.mjs FilmB 0 599 out/intro.mp4`) and `chk.mjs` makes a contact sheet of chosen frames (`node chk.mjs FilmB look 60 1140 2700`, needs ffmpeg). `render_v2.sh` renders the film in segments for joining with ffmpeg's concat demuxer.

## Where things are

| Path | What |
|---|---|
| `film/src/Film.tsx` | Scene order and start frames |
| `film/src/scenes/` | One file per scene: `IntroConnect` 0:00, `Hear` 0:20, `Mark` 0:42, `Draft` 0:56, `Sign` 1:12, `Send` 1:22 |
| `film/src/screens/` | The rebuilt app screens (live call, report sheet, sign sheet, home, clip pairing) |
| `film/src/lib/Type.tsx` | On-screen words: `Big` (headline), `Tag` (pain label), `Sub`, `Slot` (footage placeholder) |
| `film/src/lib/Stage.tsx` | The camera: zoom to a region of a screen, blur the rest |
| `film/src/lib/RealClip.tsx` | The 3D clip, from the STL parts in `film/public/stl/` |
| `film/src/theme.ts` | Colours and fonts |
| `audio/` | Soundtrack: `mix.wav` is the finished mix; `src/` builds it; `HITMAP.md` lists every sound and its time; `PROMPT.md` is the brief it was made from |
| `SPEAKER_NOTES.md` | What to say over each beat, plus the footage slot table |

Timing is on a 120 bpm grid: one beat is 15 frames. If you move a visual hit, move its sound in `audio/HITMAP.md` and `audio/src/` too.

## Things to know

- Text on screen that makes a claim: "35% fewer errors than stock Whisper" (0:38, medical speech the model had not seen), "Straight to the ePCR" (1:22), and the NEMSIS 3.5.1 tile. Change the film if the claims change.
- The clip's colours in the 3D model are a guess from the STL; set the real ones in `RealClip.tsx`.
- The soundtrack's sound-effect samples (CC0, listed in `audio/LICENSES.md`) are not in the repo, so `audio/build.sh` needs them downloaded first. `mix.wav` is included so the film can be finished without rebuilding the audio.
- Rendered video is not kept in the repo (`out/` is ignored).
