"""Earshot phonetic key (Metaphone-style).

This is a small, self-contained port of Lawrence Philips' original Metaphone
rules, tuned for drug names. The Swift side (EarshotCore/Text/Phonetic.swift)
implements the SAME rules so keys computed here and at runtime agree.
Keep the two files in sync; `core/Tests/EarshotCoreTests/PhoneticTests.swift`
pins a few expected keys.
"""

VOWELS = set("AEIOU")


def phonetic_key(word: str) -> str:
    w = "".join(c for c in word.upper() if c.isalpha())
    if not w:
        return ""
    # initial-letter exceptions
    for pre, rep in (("AE", "E"), ("GN", "N"), ("KN", "N"), ("PN", "N"), ("WR", "R")):
        if w.startswith(pre):
            w = rep + w[2:]
            break
    if w.startswith("X"):
        w = "S" + w[1:]
    if w.startswith("WH"):
        w = "W" + w[2:]
    out = []
    n = len(w)
    i = 0
    while i < n:
        c = w[i]
        prev = w[i - 1] if i > 0 else ""
        nxt = w[i + 1] if i + 1 < n else ""
        nxt2 = w[i + 2] if i + 2 < n else ""
        # skip duplicate adjacent letters except C
        if c == prev and c != "C":
            i += 1
            continue
        if c in VOWELS:
            if i == 0:
                out.append(c)
        elif c == "B":
            if not (prev == "M" and i == n - 1):
                out.append("B")
        elif c == "C":
            if nxt == "I" and nxt2 == "A":
                out.append("X")
            elif nxt == "H":
                out.append("X" if prev != "S" else "K")
                i += 1
            elif nxt in ("I", "E", "Y"):
                if prev != "S":
                    out.append("S")
            else:
                out.append("K")
        elif c == "D":
            if nxt == "G" and nxt2 in ("E", "Y", "I"):
                out.append("J")
                i += 1
            else:
                out.append("T")
        elif c == "G":
            if nxt == "H" and not (i + 2 < n and w[i + 2] not in VOWELS):
                i += 1
                out.append("F" if i + 1 >= n else "K")
            elif nxt == "N" and (i + 2 == n or (nxt2 == "E" and i + 3 < n and w[i + 3] == "D")):
                pass
            elif nxt in ("I", "E", "Y") and prev != "G":
                out.append("J")
            else:
                out.append("K")
        elif c == "H":
            if nxt in VOWELS and prev not in ("C", "S", "P", "T", "G"):
                out.append("H")
        elif c == "K":
            if prev != "C":
                out.append("K")
        elif c == "P":
            if nxt == "H":
                out.append("F")
                i += 1
            else:
                out.append("P")
        elif c == "Q":
            out.append("K")
        elif c == "S":
            if nxt == "H":
                out.append("X")
                i += 1
            elif nxt == "I" and nxt2 in ("O", "A"):
                out.append("X")
            else:
                out.append("S")
        elif c == "T":
            if nxt == "I" and nxt2 in ("O", "A"):
                out.append("X")
            elif nxt == "H":
                out.append("0")
                i += 1
            elif not (nxt == "C" and nxt2 == "H"):
                out.append("T")
        elif c == "V":
            out.append("F")
        elif c == "W":
            if nxt in VOWELS:
                out.append("W")
        elif c == "X":
            out.append("KS")
        elif c == "Y":
            if nxt in VOWELS:
                out.append("Y")
        elif c == "Z":
            out.append("S")
        else:  # F J L M N R
            out.append(c)
        i += 1
    return "".join(out)


if __name__ == "__main__":
    import sys
    for a in sys.argv[1:]:
        print(a, phonetic_key(a))
