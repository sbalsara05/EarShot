"""Download exactly the raw files render.py needs for the TEST bank, using URLs+sha256 from data/manifests/raw_manifest.jsonl."""
import hashlib, json, pathlib, sys, urllib.request, zipfile, concurrent.futures as cf
ROOT = pathlib.Path(sys.argv[1])
sys.path.insert(0, str(ROOT / "data/synth"))
from render import bank_of
want_prefix = ("Piper voice", "FSD50K/Knock", "FSD50K/Finger_snapping", "FSD50K/Traffic", "FSD50K/Siren", "FSD50K/Alarm",
               "FSD50K/Beep", "FSD50K/Idling", "FSD50K/Engine", "Knocking Sound", "DEMAND", "gelang/emergencyvehicle/ambulance")
per_file_banked = ("FSD50K/", "gelang/")
recs = []
for l in open(ROOT / "data/manifests/raw_manifest.jsonl"):
    r = json.loads(l)
    if not r["source"].startswith(want_prefix): continue
    if "libritts" in r["source"]: continue
    if r["source"].startswith(per_file_banked) and bank_of(r["path"]) != "test": continue
    recs.append(r)
print(len(recs), "files,", sum(r["bytes"] for r in recs) // 10**6, "MB")
def sha(p):
    h = hashlib.sha256(); f = open(p, "rb")
    for b in iter(lambda: f.read(1 << 20), b""): h.update(b)
    return h.hexdigest()
def get(r):
    dest = ROOT / r["path"]
    if dest.exists() and dest.stat().st_size == r["bytes"]:
        return r["path"], "cached", sha(dest) == r["sha256"]
    dest.parent.mkdir(parents=True, exist_ok=True)
    url = urllib.parse.quote(r["url"], safe=":/?=&%")
    for i in range(4):
        try:
            with urllib.request.urlopen(urllib.request.Request(url, headers={"User-Agent": "data-fetch/0.1"}), timeout=300) as u, open(str(dest) + ".part", "wb") as f:
                while (b := u.read(1 << 20)): f.write(b)
            pathlib.Path(str(dest) + ".part").rename(dest)
            return r["path"], "ok", sha(dest) == r["sha256"]
        except Exception as e:
            err = e
    return r["path"], f"FAIL {err}", False
import urllib.parse
bad = []
with cf.ThreadPoolExecutor(8) as ex:
    for p, st, okhash in ex.map(get, recs):
        if st != "cached" and st != "ok" or not okhash:
            bad.append((p, st, okhash)); print("PROBLEM", p, st, "sha_ok" if okhash else "sha_MISMATCH", flush=True)
print("problems:", len(bad))
raw = ROOT / "data/raw"
z = raw / "knocking_zenodo/knocking.zip"
if z.exists() and not (raw / "knocking_zenodo/x").exists(): zipfile.ZipFile(z).extractall(raw / "knocking_zenodo/x")
for n in ["TCAR_16k", "STRAFFIC_16k", "TBUS_16k"]:
    z = raw / f"demand/{n}.zip"
    if z.exists(): zipfile.ZipFile(z).extractall(raw / "demand")
print("extracted")
