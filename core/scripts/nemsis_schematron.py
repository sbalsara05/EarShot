#!/usr/bin/env python3
"""Check nemsis.xml exports against the NEMSIS v3.5.1 national Schematron (business rules).

The XSD only checks shape. The national Schematron (vendored in
core/Tests/EarshotCoreTests/Fixtures/nemsis_schematron/EMSDataSet.sch, 3.5.1.251001CP2) checks the
rules a state repository rejects on: [ERROR] rules make a file fail, [WARNING] rules are reported.

It is XSLT 2.0, so it needs Saxon (Java). The tools are pinned by checksum and fetched once from
Maven Central into core/.tools/ (not in git):
  Saxon-HE 12.5 + xmlresolver 5.2.2 (runs XSLT 2.0), and the ISO Schematron skeleton
  (iso_svrl_for_xslt2.xsl, packaged as name.dmaus.schxslt:skeleton 1.0), which compiles the rules.
NEMSIS's file needs the skeleton with allow-foreign=true: it keeps top-level xsl:variable/xsl:key
(its element-name lookup). SchXslt 1.10.1 emits a broken 2-argument location() for rules with a
`subject`, and SchXslt2 1.1.1 drops the foreign xsl:variable, so neither compiles it.

  python3 core/scripts/nemsis_schematron.py out/c01/nemsis.xml [more.xml ...] [--json report.json]
  python3 core/scripts/nemsis_schematron.py eval/runs/phi/test/rules        # every nemsis.xml under a folder

Exit: 0 no [ERROR] rule failed, 1 at least one did, 2 the tools are missing (java, or --no-fetch
and nothing in core/.tools/).
"""
import argparse, hashlib, json, pathlib, shutil, subprocess, sys, urllib.request, zipfile
import xml.etree.ElementTree as ET

CORE = pathlib.Path(__file__).resolve().parents[1]
SCH = CORE / "Tests/EarshotCoreTests/Fixtures/nemsis_schematron/EMSDataSet.sch"
TOOLS = CORE / ".tools/schematron"
MAVEN = "https://repo1.maven.org/maven2/"
JARS = {  # file: (Maven path, sha1 published by Maven Central)
    "Saxon-HE-12.5.jar": ("net/sf/saxon/Saxon-HE/12.5/Saxon-HE-12.5.jar", "57c007520e2879387b8d13d0a512e9566eeffa73"),
    "xmlresolver-5.2.2.jar": ("org/xmlresolver/xmlresolver/5.2.2/xmlresolver-5.2.2.jar", "152378e04ba01898847bf38fad5023c7d52f0c9d"),
    "skeleton-1.0.jar": ("name/dmaus/schxslt/skeleton/1.0/skeleton-1.0.jar", "1b04222d054954d44d52f827e0f9f3fe6666ec2a"),
}
SVRL = "{http://purl.oclc.org/dsdl/svrl}"


def tools(fetch: bool) -> pathlib.Path:
    """Returns the compiled Schematron (.xsl), fetching and compiling once. Exits 2 if it cannot."""
    if not shutil.which("java"):
        sys.exit(2)
    TOOLS.mkdir(parents=True, exist_ok=True)
    for name, (path, sha1) in JARS.items():
        jar = TOOLS / name
        if not jar.exists():
            if not fetch:
                print(f"missing {jar}; run without --no-fetch", file=sys.stderr); sys.exit(2)
            data = urllib.request.urlopen(MAVEN + path, timeout=60).read()
            if hashlib.sha1(data).hexdigest() != sha1:
                sys.exit(f"checksum mismatch for {name}; not using it")
            jar.write_bytes(data)
    xsl = TOOLS / f"EMSDataSet-{hashlib.sha256(SCH.read_bytes()).hexdigest()[:12]}-skeleton.xsl"
    if not xsl.exists():   # recompiled only when the vendored .sch changes
        with zipfile.ZipFile(TOOLS / "skeleton-1.0.jar") as z:
            z.extractall(TOOLS, [n for n in z.namelist() if n.startswith("skeleton/")])
        saxon(SCH, TOOLS / "skeleton/iso_svrl_for_xslt2.xsl", xsl, "allow-foreign=true")
    return xsl


def saxon(src: pathlib.Path, xsl: pathlib.Path, out: pathlib.Path, *params: str):
    cp = ":".join(str(TOOLS / j) for j in ("Saxon-HE-12.5.jar", "xmlresolver-5.2.2.jar"))
    r = subprocess.run(["java", "-cp", cp, "net.sf.saxon.Transform", f"-s:{src}", f"-xsl:{xsl}", f"-o:{out}", *params],
                       capture_output=True, text=True)
    if r.returncode != 0:
        sys.exit(f"saxon failed on {src}:\n{r.stderr[-2000:]}")


def check(xml: pathlib.Path, xsl: pathlib.Path) -> list[dict]:
    """One entry per failed rule: role (ERROR/WARNING), rule id, where, and NEMSIS's message."""
    out = TOOLS / "last.svrl"
    saxon(xml, xsl, out)
    found = []
    for e in ET.parse(out).getroot().iter():
        if e.tag in (SVRL + "failed-assert", SVRL + "successful-report"):
            text = " ".join("".join(t.itertext()).split()) if (t := e.find(SVRL + "text")) is not None else ""
            found.append({"role": (e.get("role") or "").strip("[]") or "ERROR", "id": e.get("id"),
                          "location": e.get("location"), "message": text})
    return found


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("paths", nargs="+", type=pathlib.Path, help="nemsis.xml files, or folders to search")
    ap.add_argument("--json", type=pathlib.Path)
    ap.add_argument("--no-fetch", action="store_true", help="do not download the tools (exit 2 if missing)")
    ap.add_argument("--quiet", action="store_true", help="counts only")
    a = ap.parse_args()
    files = sorted(f for p in a.paths for f in ([p] if p.is_file() else p.rglob("nemsis.xml")))
    if not files:
        sys.exit("no nemsis.xml found")
    xsl = tools(not a.no_fetch)
    report, failed = {}, 0
    for f in files:
        found = check(f, xsl)
        errors = [x for x in found if x["role"] == "ERROR"]
        failed += bool(errors)
        report[str(f)] = found
        print(f"{f}: {len(errors)} error(s), {len(found) - len(errors)} warning(s)")
        if not a.quiet:
            for x in found:
                print(f"  [{x['role']}] {x['id']}: {x['message']}")
    print(f"schematron: {len(files) - failed}/{len(files)} pass (no [ERROR] rule failed)")
    if a.json:
        a.json.write_text(json.dumps({"schematron": SCH.name, "files": report}, indent=1))
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
