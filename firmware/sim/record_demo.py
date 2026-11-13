#!/usr/bin/env python3
"""Record the simulator running a scripted scenario, as evidence.

Starts the mock tablet and the simulated clip, opens the simulator page in headless Chrome,
presses the clip's button with real press/hold timings through Chrome's own mouse input, and
captures the screen several times a second.

Writes to evidence/<date>-sim-run/ (or --out DIR):
  recording.mp4    the run in real time, with a caption bar naming each step
                   (a GIF instead where macOS's encoder is not available)
  step-NN.png      one still per step
  messages.jsonl   every message between clip and tablet, plus the tablet's ledger each second

  python3 sim/record_demo.py            (after `make sim`)

Needs Google Chrome, plus `pip install websockets pillow`. The MP4 is encoded with Swift (macOS).
"""
import argparse
import asyncio
import base64
import datetime
import io
import json
import pathlib
import shutil
import subprocess
import sys
import tempfile
import time
import urllib.request

import websockets
from PIL import Image, ImageDraw, ImageFont

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
from tablet import DEFAULT_SIM_BIN, MockTablet  # noqa: E402

CHROME_CANDIDATES = [
    "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
    "/Applications/Chromium.app/Contents/MacOS/Chromium",
    "google-chrome", "chromium", "chromium-browser",
]
PORT = 8791          # mock tablet + UI for this run
DEBUG_PORT = 9333    # Chrome remote debugging
VIEW_W, VIEW_H = 1100, 760
FPS = 6
BAR_H = 64


class Cdp:
    """Just enough of the Chrome DevTools Protocol: send a command, await its result."""

    def __init__(self, ws):
        self.ws = ws
        self.next_id = 0
        self.waiting = {}
        self.reader = asyncio.create_task(self._read())

    async def _read(self):
        try:
            async for raw in self.ws:
                msg = json.loads(raw)
                fut = self.waiting.pop(msg.get("id"), None)
                if fut and not fut.done():
                    fut.set_result(msg)
        except websockets.ConnectionClosed:
            pass

    async def call(self, method, **params):
        self.next_id += 1
        fut = asyncio.get_running_loop().create_future()
        self.waiting[self.next_id] = fut
        await self.ws.send(json.dumps({"id": self.next_id, "method": method, "params": params}))
        msg = await asyncio.wait_for(fut, 15)
        if "error" in msg:
            raise RuntimeError(f"{method}: {msg['error']}")
        return msg.get("result", {})

    async def evaluate(self, expression):
        r = await self.call("Runtime.evaluate", expression=expression, returnByValue=True)
        return r["result"].get("value")

    async def center_of(self, selector):
        rect = await self.evaluate(
            f"(() => {{ const r = document.querySelector({json.dumps(selector)}).getBoundingClientRect();"
            f" return [r.left + r.width / 2, r.top + r.height / 2]; }})()")
        return rect[0], rect[1]

    async def mouse(self, kind, x, y):
        await self.call("Input.dispatchMouseEvent", type=kind, x=x, y=y, button="left",
                        buttons=1 if kind == "mousePressed" else 0, clickCount=1)

    async def press(self, selector, hold_s):
        """A real mouse press on an element, held for hold_s seconds."""
        x, y = await self.center_of(selector)
        await self.mouse("mouseMoved", x, y)
        await self.mouse("mousePressed", x, y)
        await asyncio.sleep(hold_s)
        await self.mouse("mouseReleased", x, y)


class Recorder:
    def __init__(self, cdp):
        self.cdp = cdp
        self.frames = []      # (elapsed seconds, wall clock, step number, caption, png bytes)
        self.step = 0
        self.caption = ""
        self.t0 = time.monotonic()
        self.running = True

    def say(self, caption):
        self.step += 1
        self.caption = caption
        print(f"  [{time.monotonic() - self.t0:5.1f}s] step {self.step}: {caption}", flush=True)

    async def run(self):
        period = 1.0 / FPS
        while self.running:
            started = time.monotonic()
            shot = await self.cdp.call("Page.captureScreenshot", format="png")
            self.frames.append((started - self.t0, datetime.datetime.now().strftime("%H:%M:%S"),
                                self.step, self.caption, base64.b64decode(shot["data"])))
            await asyncio.sleep(max(0.0, period - (time.monotonic() - started)))


async def scenario(cdp, rec):
    btn = "#btn"
    rec.say("Power on. Ring dark: not listening. Microphone off, tablet has received 0 bytes.")
    await asyncio.sleep(3.5)

    rec.say("One press: the patient has agreed. Consent is logged, ring green, audio reaches the tablet.")
    await cdp.press(btn, 0.12)
    await asyncio.sleep(4.0)

    rec.say("Double tap: timestamp marker. It appears in the tablet's marker list.")
    await cdp.press(btn, 0.09)
    await asyncio.sleep(0.13)
    await cdp.press(btn, 0.09)
    await asyncio.sleep(3.0)

    rec.say("A stray press while listening is ignored, so a bump cannot cut the capture.")
    await cdp.press(btn, 0.12)
    await asyncio.sleep(2.5)

    rec.say("Hold 1.5 s: stop. Ring dark; the byte count stops.")
    await cdp.press(btn, 1.8)
    await asyncio.sleep(3.5)

    rec.say("Next patient. One press starts a new capture; consent is logged again.")
    await cdp.press(btn, 0.12)
    await asyncio.sleep(3.5)

    rec.say("Hold: stop.")
    await cdp.press(btn, 1.8)
    await asyncio.sleep(3.0)

    rec.say("The tablet can start a capture too (the PCR app sends 'start').")
    await cdp.press('[data-cmd="start"]', 0.08)
    await asyncio.sleep(3.5)

    rec.say("The tablet stops it. No audio ever arrived while the clip was not listening.")
    await cdp.press('[data-cmd="stop"]', 0.08)
    await asyncio.sleep(3.0)


def find_chrome():
    for c in CHROME_CANDIDATES:
        if pathlib.Path(c).exists() or shutil.which(c):
            return c
    sys.exit("Google Chrome not found.")


def load_font(size):
    for path in ("/System/Library/Fonts/Helvetica.ttc", "/System/Library/Fonts/Supplemental/Arial.ttf",
                 "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf"):
        try:
            return ImageFont.truetype(path, size)
        except OSError:
            continue
    return ImageFont.load_default()


def compose(png, elapsed, wall, step, caption, font, small):
    """The captured page with a caption bar underneath."""
    shot = Image.open(io.BytesIO(png)).convert("RGB")
    frame = Image.new("RGB", (shot.width, shot.height + BAR_H), (12, 15, 18))
    frame.paste(shot, (0, 0))
    d = ImageDraw.Draw(frame)
    d.rectangle([0, shot.height, shot.width, shot.height + BAR_H], fill=(24, 36, 54))
    d.text((16, shot.height + 8), f"Step {step}", font=small, fill=(140, 190, 255))
    d.text((16, shot.height + 30), caption, font=font, fill=(255, 255, 255))
    stamp = f"{wall}   +{elapsed:4.1f} s"
    d.text((shot.width - 16 - d.textlength(stamp, font=small), shot.height + 8), stamp, font=small,
           fill=(170, 180, 195))
    return frame


def write_outputs(frames, out_dir):
    font, small = load_font(19), load_font(15)
    images = [compose(png, t, wall, step, cap, font, small) for (t, wall, step, cap, png) in frames]

    # One still per step: the last frame captured during that step.
    last_of_step = {}
    for (t, wall, step, cap, png), img in zip(frames, images):
        last_of_step[step] = img
    for step, img in sorted(last_of_step.items()):
        img.save(out_dir / f"step-{step:02d}.png")

    durations = []
    for i in range(len(frames)):
        nxt = frames[i + 1][0] if i + 1 < len(frames) else frames[i][0] + 2.5  # hold the last frame
        durations.append(max(20, int(round((nxt - frames[i][0]) * 1000 / 10)) * 10))
    name = write_video(images, durations, out_dir)
    return len(images), sum(durations) / 1000.0, name


def write_video(images, durations_ms, out_dir):
    """recording.mp4 via macOS's built-in encoder; falls back to recording.gif elsewhere."""
    helper = pathlib.Path(__file__).resolve().parent / "frames_to_mp4.swift"
    for old in ("recording.mp4", "recording.gif"):
        (out_dir / old).unlink(missing_ok=True)
    if shutil.which("swift"):
        with tempfile.TemporaryDirectory(prefix="earshot-frames-") as tmp:
            lines = []
            for i, (img, ms) in enumerate(zip(images, durations_ms)):
                path = pathlib.Path(tmp) / f"{i:05d}.png"
                img.save(path)
                lines.append(f"{ms}\t{path}")
            manifest = pathlib.Path(tmp) / "manifest.tsv"
            manifest.write_text("\n".join(lines) + "\n")
            r = subprocess.run(["swift", "-suppress-warnings", str(helper), str(manifest), str(out_dir / "recording.mp4")],
                               capture_output=True, text=True)
            if r.returncode == 0:
                return "recording.mp4"
            print("MP4 encoding failed, writing a GIF instead:", r.stderr.strip()[-300:])
    # GIF with one shared palette, so unchanged regions compress away between frames.
    sample = images[:: max(1, len(images) // 12)][:12]
    sheet = Image.new("RGB", (sample[0].width, sample[0].height * len(sample)))
    for i, img in enumerate(sample):
        sheet.paste(img, (0, i * img.height))
    palette = sheet.quantize(colors=128, method=Image.Quantize.MEDIANCUT, dither=Image.Dither.NONE)
    gif_frames = [img.quantize(palette=palette, dither=Image.Dither.NONE) for img in images]
    gif_frames[0].save(out_dir / "recording.gif", save_all=True, append_images=gif_frames[1:],
                       duration=durations_ms, loop=0, optimize=False, disposal=1)
    return "recording.gif"


async def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawTextHelpFormatter)
    default_out = pathlib.Path(__file__).resolve().parent.parent / "evidence" / \
        f"{datetime.date.today():%Y-%m-%d}-sim-run"
    ap.add_argument("--out", default=str(default_out))
    args = ap.parse_args()
    out_dir = pathlib.Path(args.out)
    out_dir.mkdir(parents=True, exist_ok=True)
    if not DEFAULT_SIM_BIN.exists():
        sys.exit("build/sim_clip not found. Run `make sim` first.")
    log = out_dir / "messages.jsonl"
    log.unlink(missing_ok=True)
    for old in out_dir.glob("step-*.png"):
        old.unlink()

    profile = tempfile.mkdtemp(prefix="earshot-chrome-")
    chrome = subprocess.Popen(
        [find_chrome(), "--headless=new", f"--remote-debugging-port={DEBUG_PORT}",
         "--remote-allow-origins=*", f"--user-data-dir={profile}", "--no-first-run",
         "--no-default-browser-check", "--hide-scrollbars", f"--window-size={VIEW_W},{VIEW_H}",
         "about:blank"],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    tablet = MockTablet(port=PORT, sim_bin=DEFAULT_SIM_BIN, quiet=True, event_log=str(log))
    try:
        target = None
        for _ in range(100):  # wait for Chrome's debugging endpoint
            try:
                with urllib.request.urlopen(f"http://127.0.0.1:{DEBUG_PORT}/json", timeout=1) as r:
                    pages = [t for t in json.load(r) if t.get("type") == "page"]
                if pages:
                    target = pages[0]["webSocketDebuggerUrl"]
                    break
            except OSError:
                pass
            await asyncio.sleep(0.1)
        if not target:
            sys.exit("Chrome did not start.")

        async with websockets.connect(target, max_size=64 << 20) as ws:
            cdp = Cdp(ws)
            await cdp.call("Page.enable")
            await cdp.call("Emulation.setDeviceMetricsOverride", width=VIEW_W, height=VIEW_H,
                           deviceScaleFactor=1, mobile=False)
            await cdp.call("Page.navigate", url=f"http://127.0.0.1:{PORT}/")  # nothing serves yet: prime the tab
            await tablet.start()                                             # clip powers on now
            await cdp.call("Page.navigate", url=f"http://127.0.0.1:{PORT}/")
            for _ in range(50):
                if await cdp.evaluate("document.getElementById('conn')?.textContent") == "UI connected":
                    break
                await asyncio.sleep(0.1)

            print("Recording…", flush=True)
            rec = Recorder(cdp)
            capture = asyncio.create_task(rec.run())
            await scenario(cdp, rec)
            rec.running = False
            await capture
            final = await cdp.evaluate(
                "JSON.stringify({bytes: document.getElementById('tBytes').innerText,"
                " audioWithoutConsent: document.getElementById('tViol').innerText,"
                " consentLogged: document.getElementById('tRef').innerText,"
                " lost: document.getElementById('tLost').innerText,"
                " markers: document.getElementById('markers').childElementCount})")
            cdp.reader.cancel()
    finally:
        await tablet.stop()
        chrome.terminate()
        try:
            chrome.wait(5)
        except subprocess.TimeoutExpired:
            chrome.kill()
        shutil.rmtree(profile, ignore_errors=True)

    count, seconds, name = write_outputs(rec.frames, out_dir)
    size_mb = (out_dir / name).stat().st_size / 1e6
    print(f"\n{count} frames, {seconds:.0f} s -> {out_dir / name} ({size_mb:.1f} MB)")
    print(f"Final screen: {final}")
    print(f"Message log:  {log}")


if __name__ == "__main__":
    asyncio.run(main())
