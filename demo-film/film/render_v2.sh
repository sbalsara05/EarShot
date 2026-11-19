#!/bin/bash
cd "$(dirname "$0")"; mkdir -p out/seg2
set -e
r(){ node render.mjs $1 $2 $3 out/seg2/$4.mp4; }
r FilmB 0 59 S0
export REUSE=1
r FilmB 1260 1679 S4B
r FilmA 1260 1679 S4A
r FilmB 60 299 S1B
r FilmA 60 299 S1A
r FilmB 2210 2369 S6B
r FilmA 2210 2369 S6A
r FilmB 1020 1259 S3
r FilmB 2370 2939 S7
r FilmB 300 1019 S2
r FilmB 1680 2209 S5
echo ALLDONE
