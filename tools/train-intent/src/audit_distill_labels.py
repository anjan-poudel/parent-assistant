"""[DISTILL] Audit teacher-distilled labels BEFORE trusting them.

Read-only. Written after phase-2 arm A taught the student to answer
`बिहान ८ बजे` with `८ बजे` and `सुनिता` with `sunita` — i.e. the teacher's
habits, not the corpus's. Three checks, each measured against the corpus's
own convention rather than an opinion of it:

1. COVERAGE — per intent, how many rows fill each slot. A bucket that fills
   a slot 100% of the time teaches "this slot is always present"; the real
   corpus is not like that.
2. VERBATIM — is the slot value a substring of the utterance (digits and
   whitespace normalized)? The pre-distill corpus scores LOW here (time
   46.7%, contact 52.9%) because its utterances are STT transcripts while
   its labels are canonicalized — so a low score is NOT by itself a defect.
   The DISTILL set, whose utterances are clean canonical text, scores high
   (time 89.8%, contact 97.3%), which puts its misses in a different light:
   with a clean utterance, a non-verbatim label is a rewrite or an error.
3. QUALIFIER CONTRADICTION — the check that has no legitimate excuse: a
   Nepali time qualifier (बिहान/दिउँसो/साँझ/बेलुका/राति/सवा/साढे/पौने) that
   appears in the utterance but not in the label, or a different one of the
   same class in its place, is a wrong time. Found 16/373 (4.3%) in the
   phase-2 distill set, e.g. `सवा ५` labelled `साढे ५ बजे` (5:15 → 5:30) and
   `बेलुका ८ बजे` labelled `बिहान ८ बजे` (evening → morning).

Usage: .venv/bin/python src/audit_distill_labels.py [data/distill.jsonl]
"""
import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
FIELDS = ["time", "contact", "medication", "message", "topic", "requestedApp"]
DAYPARTS = ["बिहान", "दिउँसो", "साँझ", "बेलुका", "राति", "अँध्यारो"]
QUANTIFIERS = ["सवा", "साढे", "पौने"]
NE_DIGITS = str.maketrans("०१२३४५६७८९", "0123456789")


def norm(s):
    return " ".join(str(s).translate(NE_DIGITS).split())


def qualifier_mismatch(utterance: str, value):
    """(said, wrote) when a time label contradicts the utterance's own
    qualifiers, else None — the one time-label check that has no legitimate
    excuse. Exposed for gen_distill's repair pass, which must touch ONLY
    these rows: the teacher's longer forms are otherwise often better than
    the bank phrase (`हरेक दिन बिहान ७ बजे` must not lose its recurrence)."""
    if not value:
        return None
    u, v = norm(utterance), norm(value)
    for group in (DAYPARTS, QUANTIFIERS):
        said = [q for q in group if q in u]
        wrote = [q for q in group if q in v]
        if said and said != wrote:
            return said, wrote
    return None


def qualifier_errors(rows):
    """Time labels that contradict an explicit qualifier in the utterance."""
    out = []
    for r in rows:
        bad = qualifier_mismatch(r["utterance"], r.get("time"))
        if bad:
            out.append((r, bad[0], bad[1]))
    return out


def main():
    path = Path(sys.argv[1]) if len(sys.argv) > 1 else ROOT / "data" / "distill.jsonl"
    rows = [json.loads(l) for l in open(path, encoding="utf-8") if l.strip()]
    print(f"auditing {path} ({len(rows)} rows)\n")

    print("coverage by intent (filled/rows):")
    intents = sorted({r.get("intent") for r in rows})
    print(f"  {'intent':16s} {'rows':>5s}  " + " ".join(f"{f[:9]:>9s}" for f in FIELDS))
    for it in intents:
        sel = [r for r in rows if r.get("intent") == it]
        cells = " ".join(f"{sum(1 for r in sel if r.get(f) not in (None, '', [])):>9d}"
                         for f in FIELDS)
        print(f"  {it:16s} {len(sel):5d}  {cells}")
    print()

    print("verbatim rate (value is a substring of the utterance):")
    for f in FIELDS:
        filled = [r for r in rows if r.get(f) not in (None, "", [])]
        hit = sum(1 for r in filled if norm(r[f]) in norm(r["utterance"]))
        n = len(filled) or 1
        print(f"  {f:14s} {len(filled):5d} filled  {hit / n:6.1%}")
    print()

    bad = qualifier_errors(rows)
    print(f"qualifier contradictions: {len(bad)} "
          f"({len(bad) / max(len(rows), 1):.1%} of rows)")
    for r, said, wrote in bad[:10]:
        print(f"  {r['intent']:14s} utt={r['utterance'][:44]!r} "
              f"-> time={r['time']!r}  (said {said}, wrote {wrote})")
    print("\nNOTE: nothing is auto-fixed here. The caller decides whether to "
          "drop, repair from the frame binding, or regenerate.")


if __name__ == "__main__":
    main()
