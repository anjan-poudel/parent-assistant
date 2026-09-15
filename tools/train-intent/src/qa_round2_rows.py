"""Round-2 post-generation QA gate (ENCODER QUALITY ROUND-2, CPU-side).

Sits between the local teacher and the encoder chain: it validates the rows the
teacher produced for `gen_round2_requests.py` BEFORE they become a pipeline
source, and writes the clean subset plus a rejects file.

Every taxonomy / schema / span / edge-band check is REUSED BY IMPORT from the
stage that owns it — nothing here re-implements a gate:

  - `build_encoder_dataset.convert_row`  taxonomy (VALID_ACTIONS), schema,
    canonical text, refusal markers, edge bands, span derivation + validation
    (`encoder_align.validate_spans`), resolved-value smells, and the fixed
    8-field row shape the trainer consumes.
  - `build_dataset.load_golden_keys`      the held-out leak set: golden corpus
    AND `eval/emergency_nearmiss.jsonl`. E1's own guard covers only the golden
    corpus (`build_encoder_dataset.py` imports `pipeline_guards.golden_keys`),
    so this script is the one place the adversarial near-miss set is applied to
    the round-2 supply — deliberately stricter than the build, never looser.
  - `build_dataset.lossless_key`          in-campaign duplicate collapse.
  - `pipeline_guards.*`                   exit codes, held-out file hashes,
    `assert_not_golden_input`, atomic report write.
  - `encoder_rules.load_rules`            the T-034 contract (labels, refusal
    markers, floors) — a disagreement between rules and code is a hard error,
    never a silent pick.

Checks, in order: attribution → schema/convert_row → held-out leak → duplicate
→ class-cue fidelity → quota fill. Rejected rows never reach the pipeline.

Exit codes: 0 ok, 2 usage, 3 refused (an input IS the held-out corpus, a
required file is missing, an unattributed id rate above `--max-unattributed`),
4 quota hold (some class is below `--min-fill` of its requested rows — do not
fire the chain yet), 1 unexpected failure.

No PII (NFR-016): the report and the rejects file carry ids, counters, paths
and hashes only — never utterance text.
"""
from __future__ import annotations

import argparse
import json
import sys
from collections import Counter
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))

from build_dataset import load_golden_keys, lossless_key, normalize  # noqa: E402
from build_encoder_dataset import convert_row  # noqa: E402
from encoder_rules import load_rules  # noqa: E402
from pipeline_guards import (EXIT_FLOOR, EXIT_GUARD, EXIT_OK, EXIT_STAGE,  # noqa: E402
                             EXIT_USAGE, GOLDEN_CORPUS, GuardError,
                             assert_not_golden_input, golden_keys, read_jsonl,
                             sha256_file, utc_now, write_json)

ROOT = Path(__file__).resolve().parent.parent
NEARMISS = ROOT / "eval" / "emergency_nearmiss.jsonl"

# Fields a teacher row must carry for convert_row + the trainer's schema. The
# slot fields are optional-by-row but must be str|None when present (an empty
# string is a resolved-value smell the build refuses — surface it here first).
REQUIRED = ("id", "utterance", "action", "register", "source", "confidence")
SLOT_FIELDS = ("entryId", "contact", "time", "medication", "message",
               "callType", "requestedApp", "topic", "steps")


def attribute(row_id: str, req_ids: set[str]) -> tuple[str | None, str]:
    """Row id -> (request_id, how). Contract: "<request_id>-<k>", and the STT
    stage appends ":noise<n>" (stt_noise.py), so strip that first."""
    base = (row_id or "").split(":")[0]
    if base in req_ids:
        return base, "bare"
    req = base.rsplit("-", 1)[0]
    if req in req_ids:
        return req, "suffixed"
    return None, "unattributed"


def cue_hit(utterance: str, cue: str) -> bool:
    """Lexical cue check on the same normalization the leak guard uses. Both
    scripts are matched uniformly (Devanagari cues against Devanagari text,
    Latin cues case-folded) — a best-effort guard, not a semantic one."""
    return normalize(cue) in normalize(utterance)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--rows", required=True,
                        help="teacher output jsonl (intent/v2 rows)")
    parser.add_argument("--requests", required=True,
                        help="request list from gen_round2_requests.py")
    parser.add_argument("--out", default="data/round2/round2_clean.jsonl",
                        help="rows that PASS, ready as a pipeline source")
    parser.add_argument("--rejects", default="data/round2/round2_rejects.jsonl",
                        help="rejected rows: id + reason only (no text)")
    parser.add_argument("--report", default="data/round2/round2_qa_report.json")
    parser.add_argument("--noised", default="",
                        help="optional noised jsonl (stt_noise.py --out) to audit: "
                             "every row must attribute to a request, match its "
                             "parent's action, and clear the held-out leak guard")
    parser.add_argument("--min-fill", type=float, default=0.90,
                        help="a class below this fraction of its requested rows is a "
                             "quota hold (exit 4). Default 0.90")
    parser.add_argument("--max-unattributed", type=float, default=0.02,
                        help="refuse (exit 3) when more than this fraction of rows "
                             "carry an id that matches no request. Default 0.02")
    parser.add_argument("--dry-run", action="store_true",
                        help="report only; write no rows files")
    args = parser.parse_args()

    rows_path = Path(args.rows).expanduser()
    req_path = Path(args.requests).expanduser()
    for p, role in ((rows_path, "--rows"), (req_path, "--requests")):
        if not p.exists():
            print(f"[round2-qa] REFUSED: {role} not found at {p}", file=sys.stderr)
            return EXIT_GUARD

    try:
        rules = load_rules()
        assert_not_golden_input(rows_path, "--rows")
        if args.noised:
            assert_not_golden_input(Path(args.noised).expanduser(), "--noised")
        held_out = golden_keys(GOLDEN_CORPUS) | load_golden_keys(NEARMISS)
    except GuardError as e:
        print(f"[guard] REFUSED: {e}", file=sys.stderr)
        return EXIT_GUARD
    except Exception as e:  # noqa: BLE001 — a missing held-out file is a refusal
        print(f"[guard] REFUSED: {e}", file=sys.stderr)
        return EXIT_GUARD

    requests = read_jsonl(req_path)
    req_by_id = {r["request_id"]: r for r in requests}
    implied_classes = {r["class"]: r for r in requests}

    rows = read_jsonl(rows_path)
    counters = Counter()
    rejects: list[dict] = []
    clean: list[dict] = []
    seen: dict[str, str] = {}          # lossless_key -> row id (first wins)
    by_class = Counter()
    by_class_register: dict[str, Counter] = {}
    by_intent = Counter()
    unattributed = 0
    bare_ids = 0

    for row in rows:
        counters["rows_in"] += 1
        rid = row.get("id")
        req_id, how = attribute(str(rid or ""), set(req_by_id))
        if req_id is None:
            unattributed += 1
            rejects.append({"id": rid, "reason": "unattributed_id"})
            continue
        if how == "bare":
            bare_ids += 1
        req = req_by_id[req_id]
        cls = req["class"]

        missing = [f for f in REQUIRED if not row.get(f)]
        if missing:
            counters["schema_missing_field"] += 1
            rejects.append({"id": rid, "reason": "schema_missing_field:" + ",".join(missing)})
            continue
        for f in SLOT_FIELDS:
            if f in row and row[f] is not None and not isinstance(row[f], (str, list)):
                counters["schema_slot_type"] += 1
                rejects.append({"id": rid, "reason": f"schema_slot_type:{f}"})
                break
        else:
            if row.get("action") != req["intent"]:
                # The teacher was told which intent this seed belongs to; a row
                # labelled otherwise would silently undo the class accounting.
                counters["intent_mismatch"] += 1
                rejects.append({"id": rid,
                                "reason": f"intent_mismatch:{row.get('action')}!= {req['intent']}"})
                continue
            if row.get("register") != req["register"]:
                counters["register_mismatch"] += 1
                rejects.append({"id": rid,
                                "reason": f"register_mismatch:{row.get('register')}!= {req['register']}"})
                continue
            # convert_row owns: taxonomy, canonical text, refusal markers, edge
            # band, span derivation/validation, resolved-value smells.
            converted = convert_row(row, rules, counters)
            if converted is None:
                rejects.append({"id": rid, "reason": "convert_row_refused"})
                continue
            counters["converted"] += 1
            if normalize(converted["utterance"]) in held_out:
                counters["held_out_leak"] += 1
                rejects.append({"id": rid, "reason": "held_out_leak"})
                continue
            key = lossless_key(converted["utterance"])
            if key in seen:
                counters["duplicate"] += 1
                rejects.append({"id": rid, "reason": f"duplicate_of:{seen[key]}"})
                continue
            bad_cue = next((c for c in req.get("must_exclude") or []
                            if cue_hit(converted["utterance"], c)), None)
            if bad_cue is None:
                inc = req.get("must_include") or []
                if inc and not any(cue_hit(converted["utterance"], c) for c in inc):
                    bad_cue = f"missing_required_cue:{inc[0]}"
            if bad_cue:
                counters["class_cue"] += 1
                rejects.append({"id": rid, "reason": f"class_cue:{bad_cue}"})
                continue
            seen[key] = str(rid)
            clean.append(converted)
            by_class[cls] += 1
            by_class_register.setdefault(cls, Counter())[req["register"]] += 1
            by_intent[converted["action"]] += 1

    # ---- noised audit (optional): attribution + parent action + leak--------
    noised_audit: dict = {}
    if args.noised:
        n_path = Path(args.noised).expanduser()
        if not n_path.exists():
            print(f"[round2-qa] REFUSED: --noised not found at {n_path}", file=sys.stderr)
            return EXIT_GUARD
        n_rows = read_jsonl(n_path)
        parent_action = {str(r["id"]): r.get("action") for r in rows}
        n_ok = n_attr = n_parent = n_leak = 0
        for row in n_rows:
            n_attr_seen, _ = attribute(str(row.get("id") or ""), set(req_by_id))
            if n_attr_seen is None:
                n_attr += 1
                continue
            parent = str(row.get("id") or "").split(":")[0]
            if parent not in parent_action or parent_action[parent] != row.get("action"):
                n_parent += 1
                continue
            if normalize(str(row.get("utterance") or "")) in held_out:
                n_leak += 1
                continue
            n_ok += 1
        noised_audit = {"rows": len(n_rows), "usable": n_ok,
                        "unattributed": n_attr,
                        "parent_action_mismatch_or_missing_parent": n_parent,
                        "held_out_leak": n_leak}
        counters["noised_unattributed"] = n_attr
        counters["noised_parent_mismatch"] = n_parent
        counters["noised_held_out_leak"] = n_leak

    # ---- quota fill ---------------------------------------------------------
    fill: dict[str, dict] = {}
    short: list[str] = []
    for cls, req in implied_classes.items():
        want = int(req.get("class_rows") or req.get("rows") or 0)
        got = by_class.get(cls, 0)
        frac = (got / want) if want else 1.0
        fill[cls] = {"requested": want, "rows": got, "fill": round(frac, 4),
                     "intent": req["intent"],
                     "registers": dict(sorted(by_class_register.get(cls, {}).items()))}
        if frac < args.min_fill:
            short.append(cls)

    report = {
        "schema": "round2-qa-report/v1",
        "created_utc": utc_now(),
        "rules": {"path": str(rules.path), "sha256": sha256_file(rules.path),
                  "labels": list(rules.labels)},
        "held_out": {
            "golden_corpus": {"path": str(GOLDEN_CORPUS), "sha256": sha256_file(GOLDEN_CORPUS)},
            "nearmiss": {"path": str(NEARMISS), "exists": NEARMISS.exists()},
            "keys": len(held_out)},
        "inputs": {
            "rows": {"path": str(rows_path), "sha256": sha256_file(rows_path),
                     "rows": counters["rows_in"]},
            "requests": {"path": str(req_path), "sha256": sha256_file(req_path),
                         "requests": len(requests)},
            "noised": args.noised or None},
        "counters": {k: v for k, v in sorted(counters.items()) if v},
        "rows_clean": len(clean),
        "rows_rejected": len(rejects),
        "bare_request_ids": bare_ids,
        "fill_by_class": fill,
        "short_classes": short,
        "min_fill": args.min_fill,
        "rows_by_intent": dict(sorted(by_intent.items())),
        "noised_audit": noised_audit,
        "note": "rejects carry ids and reasons only (no utterance text); the "
                "held-out leak guard here also covers eval/emergency_nearmiss.jsonl, "
                "which the E1 build's guard does not",
    }

    if not args.dry_run:
        out = Path(args.out)
        if not out.is_absolute():
            out = ROOT / out
        out.parent.mkdir(parents=True, exist_ok=True)
        with open(out, "w", encoding="utf-8") as f:
            for r in clean:
                f.write(json.dumps(r, ensure_ascii=False) + "\n")
        rej = Path(args.rejects)
        if not rej.is_absolute():
            rej = ROOT / rej
        rej.parent.mkdir(parents=True, exist_ok=True)
        with open(rej, "w", encoding="utf-8") as f:
            for r in rejects:
                f.write(json.dumps(r, ensure_ascii=False) + "\n")
        rep = Path(args.report)
        if not rep.is_absolute():
            rep = ROOT / rep
        write_json(rep, report)
        print(f"[round2-qa] clean -> {out}")
        print(f"[round2-qa] rejects -> {rej}")
        print(f"[round2-qa] report -> {rep}")

    print(f"[round2-qa] {counters['rows_in']} in, {len(clean)} clean, "
          f"{len(rejects)} rejected, {unattributed} unattributed "
          f"(held-out leaks: {counters['held_out_leak']}, duplicates: "
          f"{counters['duplicate']}, cue violations: {counters['class_cue']})")
    for cls in sorted(fill, key=lambda c: fill[c]["fill"]):
        f_ = fill[cls]
        flag = "  <-- SHORT" if cls in short else ""
        print(f"[round2-qa]   {cls:6s} {f_['rows']:5d}/{f_['requested']:5d} "
              f"({f_['fill']:.2f}) {f_['intent']}{flag}")

    if unattributed > args.max_unattributed * max(1, counters["rows_in"]):
        print("[round2-qa] REFUSED: unattributed ids above "
              f"--max-unattributed ({unattributed}/{counters['rows_in']})",
              file=sys.stderr)
        return EXIT_GUARD
    if short:
        print("[round2-qa] HOLD: classes below --min-fill "
              f"{args.min_fill}: {', '.join(short)} — do not fire the chain",
              file=sys.stderr)
        return EXIT_FLOOR
    return EXIT_OK


if __name__ == "__main__":
    try:
        sys.exit(main())
    except SystemExit:
        raise
    except Exception as e:  # noqa: BLE001 — a crash is a stage failure
        print(f"[round2-qa] STAGE FAILED: {type(e).__name__}: {e}", file=sys.stderr)
        sys.exit(EXIT_STAGE)
