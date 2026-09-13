"""[SLOT-CANON] One canonical form per slot — the golden corpus's convention,
applied to BOTH sides: the training labels (build_dataset) and the eval's
extraction (eval_golden), so train and eval agree on what a slot value IS.

Measured 2026-09-13 (the 4B slot-gate diagnosis). Two conventions had drifted
apart between the corpus and the held-out golden table:

CONTACT. All six golden contact rows are BARE — माइया, maiya, छोरा, सुनिता,
didi, सुनिता — while 349 corpus labels still carry the dative particle
(सुनितालाई) and 17 carry it as a separate romanized token ("sita lai"):
24.5% of stt_noised / 21.0% of teacher / 0% of distill contact rows. Costs:
  * TRAIN — one slot taught in two shapes, so at decode time the particle is
    a coin flip rather than a rule;
  * EVAL — slot_f1 is token-level and whitespace-split, so a suffixed
    prediction loses the gold token AND gains a spurious one: one row's slip
    costs 2 of the 6 contact tokens (F1 1.000 -> 0.800 for the whole gate).
The app itself is tolerant — ContactResolver.score() contains-matches
("सुनितालाई" contains the stored "सुनिता" => 0.8, above the 0.6 accept
threshold, and relationshipAnchor() documents the dative as a compound it
handles) — so canonicalizing at eval time grades what the device would
resolve, not a spelling the device merely tolerates.

ONLY the dative/accusative particle is stripped, and ONLY from `contact`.
Deliberately NOT stripped:
  * -मा / -ma: 118 corpus contacts end in मा and it is NOT a particle there —
    आमा ("mother") and सिमा ("Sima") are bare words; stripping yields आ and
    सि. The first pass of this audit counted those as "case suffixes" and
    would have corrupted every such label; this module does not.
  * honorifics (जी/ज्यू): `strippingHonorifics` is the app's MATCH-time
    choice (see NepaliTextNormalizer — a name may legitimately end in one)
    and the golden corpus never strips them.
  * genitive -को: exactly one corpus contact carries it ("भाइको", on a
    garbled stt_noised row). One row is not a convention gap, and a rule
    added for it would misfire on any name containing को; left alone
    deliberately rather than by oversight.

TIME. The golden contract fills `time` only for reminders: gc-query-001
"भोलि मौसम कस्तो हुन्छ" carries slots {} — a time WORD in the utterance does
not make a time SLOT. The corpus disagreed on 55 non-reminder rows, 43 of
them weather queries with time=भोलि/आज; that is the data shape behind the
4B s43 gbnf failure "time None -> 'आज'" on gc-message-001. canonical_time
nulls the slot at build time.

  NOTE the asymmetry, which is deliberate: eval_golden canonicalizes the
  GOLD time but scores the PREDICTED time raw. Canonicalizing a prediction
  by its own predicted intent would forgive the exact spurious-time false
  positive the gate exists to catch.

Usage:
    .venv/bin/python src/slot_canonical.py     # self-test + corpus audit
"""
from __future__ import annotations

import json
import sys
import unicodedata
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

# The dative/accusative particle ("to/for X"): सुनितालाई = सुनिता + लाई.
# Both scripts, attached or as its own token. No other Nepali case marker is
# stripped — see the -मा note above.
DATIVE_DEV = "लाई"
DATIVE_LATIN = ("lai", "laai")
# A stem shorter than this is not a name ("लाई" alone, "लै"); never strip to it.
MIN_STEM = 2

# `time` is filled ONLY by these intents (create_calendar_event stays listed
# although the corpus currently has zero such rows — a calendar event
# legitimately carries a time and must not be nulled if rows are ever added).
TIME_INTENTS = frozenset({"set_reminder", "create_calendar_event"})


def _nfc(text: str) -> str:
    return unicodedata.normalize("NFC", text)


def strip_dative(value):
    """`contact` in the golden form: the name, without the case particle.

    Handles the three shapes the corpus actually uses —
        सुनितालाई        (attached Devanagari)
        सुनिता लाई       (separate Devanagari token)
        "sita lai" / "naatinilai"   (romanized, separate or attached)
    — and returns the value UNCHANGED when nothing strips, so a label that is
    already canonical stays byte-identical (idempotent, safe to re-run over
    an already-built dataset).

    Non-strings and whitespace-only values pass through untouched: the slot
    is `string|null`, and "absent" is not this function's business.
    """
    if not isinstance(value, str):
        return value
    text = value.strip()
    if not text:
        return value
    nfc = _nfc(text)

    # 1) separate token: "सुनिता लाई", "mero chhora lai", "Aama lai"
    tokens = nfc.split()
    if len(tokens) > 1 and (tokens[-1] == DATIVE_DEV
                            or tokens[-1].casefold() in DATIVE_LATIN):
        stem = " ".join(tokens[:-1]).strip()
        if len(stem) >= MIN_STEM:
            return stem

    # 2) attached Devanagari: "सुनितालाई", "मेरो आमालाई", "My sonलाई"
    if nfc.endswith(DATIVE_DEV):
        stem = nfc[:-len(DATIVE_DEV)].strip()
        if len(stem) >= MIN_STEM:
            return stem

    # 3) attached romanized: "naatinilai" -> naatini, "timilai" -> timi
    folded = nfc.casefold()
    for particle in DATIVE_LATIN:
        if folded.endswith(particle):
            stem = nfc[:len(nfc) - len(particle)].strip()
            if len(stem) >= MIN_STEM:
                return stem

    return value


def canonical_contact(value):
    """The `contact` slot in the golden form (see strip_dative)."""
    return strip_dative(value)


def canonical_time(value, intent):
    """The `time` slot in the golden form: filled only by TIME_INTENTS.

    A time word inside a non-reminder utterance ("आज भेट्नुहोस् भनेर मेसेज
    पठाउ") is part of the message, not a slot value; the golden table scores
    it as null and so must the training label, or the model learns to fill it
    (that is the measured 'आज' false positive). Returns None = slot absent.
    """
    if value is None or not str(value).strip():
        return value
    if intent not in TIME_INTENTS:
        return None
    return value


def canonicalize_row(row: dict) -> dict:
    """A new row with canonical slots — never mutates the caller's dict."""
    out = dict(row)
    out["contact"] = canonical_contact(row.get("contact"))
    out["time"] = canonical_time(row.get("time"), row.get("intent"))
    return out


def canonicalize_rows(rows: list[dict]) -> tuple[list[dict], dict]:
    """canonicalize_row over a list, plus the counts for the build log."""
    stats = {"contact": 0, "time": 0}
    out = []
    for row in rows:
        new = canonicalize_row(row)
        if new["contact"] != row.get("contact"):
            stats["contact"] += 1
        if new["time"] != row.get("time"):
            stats["time"] += 1
        out.append(new)
    return out, stats


# --------------------------------------------------------------------------
# Self-test / audit. Not a unit-test framework — this suite's discipline is
# runnable checks (cf. src/probe_grammar.py, src/probe_twins.py): it asserts
# the invariants the build and the gate depend on, then reports the residual
# counts in the BUILT dataset. Exit non-zero on any failed invariant.
# --------------------------------------------------------------------------
CASES = [
    # (input, expected) — the corpus shapes and the traps.
    ("सुनितालाई", "सुनिता"),
    ("मेरो आमालाई", "मेरो आमा"),
    ("My sonलाई", "My son"),
    ("सुनिता लाई", "सुनिता"),
    ("sita lai", "sita"),
    ("Aama lai", "Aama"),
    ("naatinilai", "naatini"),
    ("timilai", "timi"),
    # traps: NOT case suffixes
    ("आमा", "आमा"),
    ("सिमा", "सिमा"),
    ("सुनिता", "सुनिता"),
    ("didi", "didi"),
    ("maiya", "maiya"),
    # degenerate
    ("लाई", "लाई"),
    ("", ""),
    (None, None),
]


def main() -> None:
    failures = []

    for given, want in CASES:
        got = canonical_contact(given)
        if got != want:
            failures.append(f"strip_dative({given!r}) = {got!r}, want {want!r}")
        again = canonical_contact(got)
        if again != got:
            failures.append(f"strip_dative not idempotent on {given!r}: "
                            f"{got!r} -> {again!r}")

    # The golden corpus IS the convention: it must already be canonical, or
    # the two sides have drifted again and the eval is scoring a contract
    # the corpus does not follow.
    corpus = [json.loads(line) for line in
              open(ROOT / "eval" / "golden_corpus.jsonl", encoding="utf-8")
              if line.strip()]
    for row in corpus:
        for slot, fn in (("contact", lambda v: canonical_contact(v)),
                         ("time", lambda v: canonical_time(
                             v, row["intent"]))):
            raw = row.get("slots", {}).get(slot)
            if fn(raw) != raw:
                failures.append(f"golden {row['id']}.{slot} = {raw!r} is not "
                                f"canonical (canonical: {fn(raw)!r})")

    # Built-dataset residuals: what the build still lets through. Zero is the
    # invariant for contact; time is reported per intent.
    residual = {"contact": 0, "time": 0}
    total = 0
    for split in ("train", "valid"):
        path = ROOT / "data" / f"{split}.jsonl"
        if not path.exists():
            continue
        for line in open(path, encoding="utf-8"):
            if not line.strip():
                continue
            row = json.loads(line)
            total += 1
            if canonical_contact(row.get("contact")) != row.get("contact"):
                residual["contact"] += 1
            if canonical_time(row.get("time"), row["intent"]) != row.get("time"):
                residual["time"] += 1

    print(f"slot canonicalization self-test: {len(CASES)} cases, "
          f"{len(corpus)} golden rows")
    if total:
        print(f"built dataset: {total} rows, {residual['contact']} "
              f"non-canonical contact, {residual['time']} non-reminder time "
              "(both must be 0)")
    for line in failures:
        print(f"  FAIL {line}")
    if failures:
        sys.exit(f"{len(failures)} invariant(s) failed")
    print("all invariants hold")


if __name__ == "__main__":
    main()
