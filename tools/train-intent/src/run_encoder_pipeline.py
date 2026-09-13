"""T-036 stage E4 — the end-to-end encoder pipeline (build → train → calibrate →
eval → publish), streamed, with a single publish decision.

Stages are separate processes, run with `sys.executable -u` and streamed line by
line (never buffered whole): a stage that goes quiet is visible immediately.
Every stage's stdout+stderr is teed to `<work_dir>/logs/<stage>.log`.

The eval stage is the UNMODIFIED T-038 harness (`eval_golden.py --backend
encoder --model-path <artifact> --manifest-out ...`) — this pipeline never
forks it, and reads the harness's own JSONL manifest to decide the publish.

Publication requires ALL of:
  - the harness exited 0 and its manifest's `gates_failed` is empty
    (that list includes the hard emergency-recall gate);
  - the calibration gate passed (accuracy-vs-confidence within ±max_gap);
  - `model.pt` did not change between the eval and the publish copy;
  - not `--smoke`;
  - `encoder.artifact.version` is set (it is T-035-owned — with the `null`
    placeholder the pipeline refuses to publish and says why).

Supply floors (`--waive-floor` / `--waive-reason`): forwarded to the E1 build
stage and NOWHERE ELSE — the later stages read the floor state from the build
report. A waiver demands a reason (EXIT_GUARD otherwise, before anything runs),
and the run manifest records the same `floors` keys as the build report
(`waived` / `unwaived` / `violations` / `waive_reason`) so the two audit records
reconcile. A waiver does NOT relax publication: a waived floor is an explicitly
recorded, internal-testing decision, and the artifact still has to clear the
calibration + harness gates on its own merits.

Consent (NFR-015): `--consent-export` is deliberately NOT implemented — the
flag exists so a caller asking for real-user data gets an explicit refusal
rather than a silent no-op. Real consented exports remain an ops/T-035 gate.

No PII (NFR-016): manifests carry paths, hashes, counters and the harness's
metric summary — never an utterance.
"""
from __future__ import annotations

import argparse
import json
import shutil
import subprocess
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))

from pipeline_guards import (  # noqa: E402
    EXIT_FLOOR, EXIT_GUARD, EXIT_OK, EXIT_STAGE, GuardError, read_json,
    sha256_file, utc_now, write_json,
)
from encoder_contract import load_contract  # noqa: E402
from encoder_rules import T035PendingError, load_rules, require_t035  # noqa: E402
from config import abs_path, load_config  # noqa: E402

ROOT = Path(__file__).resolve().parent.parent
EXIT_GATE = 5  # ship gates not met — a decision, not a crash (documented in README)


def retry_ok(exit_code, timed_out: bool, attempt: int, retries: int) -> bool:
    """Whether a failed stage is re-run automatically.

    ONLY a timeout is retried, and only when the operator asked for retries:
    every other failure (a refusal, a gate failure, a crash) is deterministic,
    so re-running it blind would burn GPU time and hide the cause. Re-running
    those stays a deliberate operator action (the stages are resumable).
    """
    return bool(timed_out) and exit_code != 0 and attempt < int(retries)


def _run_once(name: str, cmd: list[str], log: Path, timeout_s: float) -> dict:
    """One attempt: stream stdout+stderr to `log`, killing at `timeout_s` (>0)."""
    import os
    import threading
    printable = " ".join(str(c) for c in cmd)
    state = {"timed_out": False}
    t0 = time.time()
    with open(log, "w", encoding="utf-8") as f:
        p = subprocess.Popen([str(c) for c in cmd], cwd=str(ROOT),
                             stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                             text=True, bufsize=1,
                             env={**os.environ, "PYTHONUNBUFFERED": "1"})
        timer = None
        if timeout_s and timeout_s > 0:
            def _kill():
                state["timed_out"] = True
                print(f"[stage] {name}: TIMEOUT after {timeout_s}s — killing pid "
                      f"{p.pid} (operator-set --stage-timeout-seconds)", flush=True)
                try:
                    p.kill()
                except OSError:
                    pass
            timer = threading.Timer(timeout_s, _kill)
            timer.daemon = True
            timer.start()
        try:
            assert p.stdout is not None
            for line in p.stdout:      # incremental: never buffers the stage
                line = line.rstrip("\n")
                print(f"[{name}] {line}", flush=True)
                f.write(line + "\n")
        finally:
            if timer is not None:
                timer.cancel()
            if p.stdout is not None:
                p.stdout.close()       # release the pipe (no ResourceWarning)
    rc = p.wait()
    dt = time.time() - t0
    print(f"[stage] {name}: exit={rc} in {dt:.1f}s -> {log}", flush=True)
    return {"name": name, "cmd": printable, "exit": rc, "seconds": round(dt, 2),
            "log": str(log), "timed_out": state["timed_out"]}


def run_stage(name: str, cmd: list[str], log_dir: Path, dry_run: bool = False,
              timeout_s: float = 0.0, retries: int = 0) -> dict:
    """Run one stage, streaming its output; return {name, cmd, exit, seconds, log}.

    `timeout_s` (<=0 disables the watchdog) and `retries` come from
    `encoder.pipeline.*` in config.yaml / the matching CLI flags — parameters,
    not constants, so a shared box can bound a leg without a code change.
    """
    log_dir.mkdir(parents=True, exist_ok=True)
    printable = " ".join(str(c) for c in cmd)
    print(f"[stage] {name}: {printable}", flush=True)
    if dry_run:
        return {"name": name, "cmd": printable, "exit": None,
                "log": str(log_dir / f"{name}.log"), "dry_run": True}
    attempts = max(1, int(retries) + 1)
    result: dict = {}
    for attempt in range(attempts):
        log = log_dir / (f"{name}.log" if attempt == 0
                         else f"{name}.attempt{attempt + 1}.log")
        result = _run_once(name, cmd, log, timeout_s)
        result["attempt"] = attempt + 1
        if result["exit"] == 0 or not retry_ok(result["exit"], result["timed_out"],
                                               attempt, retries):
            return result
        print(f"[stage] {name}: attempt {attempt + 1}/{attempts} timed out — "
              f"retrying (only timeouts are retried)", flush=True)
    return result


def harness_metrics(manifest_out: Path) -> dict | None:
    """Last row of the harness's append-only JSONL manifest (its own metrics)."""
    if not manifest_out.exists():
        return None
    last = None
    with open(manifest_out, encoding="utf-8") as f:
        for line in f:
            if line.strip():
                last = line
    return json.loads(last) if last else None


def conformance_block(contract) -> dict:
    """Machine-readable conformance record for the run manifest.

    Two things the T-035 contract fixes that live outside the training maths and
    would otherwise be decided implicitly at export time: the export input dtype
    (contract says int64; the shipped CoreML artifact + T-037-a iOS runner use
    int32 — `EncoderContract.dtype_conformance()` states the reconciliation) and
    the interpreter-side `runtime.config` (recorded, not driven by this pipeline).
    """
    return {
        "input_dtype": contract.dtype_conformance(),
        "runtime_config": dict(contract.runtime_config),
        "note": "runtime.config is applied by the iOS interpreter (T-037); this "
                "pipeline neither drives nor overrides it — recorded so a T-035 "
                "revision is detectable",
    }


def build_stage_cmd(py: list[str], sources: list[str], build_dir: Path,
                    build_report: Path, smoke: bool, max_train: int,
                    waive_floor: str = "", waive_reason: str = "") -> list[str]:
    """The E1 command — the ONE place the waiver flags may appear.

    `train`/`calibrate`/`eval` never receive them: those stages read the floor
    state from the build report the waiver was recorded in, so forwarding the
    flags further would create a second, unaudited copy of the decision.
    """
    cmd = list(py) + ["src/build_encoder_dataset.py", "--sources", *sources,
                      "--out-dir", str(build_dir), "--report", str(build_report)]
    if smoke:
        cmd.append("--smoke")
    if max_train:
        cmd += ["--max-source-rows", str(max_train)]
    if waive_floor:
        cmd += ["--waive-floor", waive_floor]
        if waive_reason:
            cmd += ["--waive-reason", waive_reason]
    return cmd


def waiver_refusal(waive_floor: str, waive_reason: str, skip_build: bool,
                   has_sources: bool) -> str | None:
    """Refusal message when the waiver flags cannot be honored (None == fine).

    Stricter than the build stage in one corner: `--smoke` there auto-waives
    without a reason, but `--waive-floor` passed to THIS pipeline always needs
    its reason — in a smoke run the flag is inert anyway, so refusing costs
    nothing and closes the "waived without a recorded decision" path entirely.
    """
    if not waive_floor:
        return None
    if not waive_reason:
        return ("--waive-floor requires --waive-reason: a waived supply floor is "
                "an explicit, recorded decision (T-034 §5.3), never an implicit one")
    if skip_build or not has_sources:
        return ("--waive-floor was given but the build stage will not run "
                "(--skip-build / no --sources): the waiver would be forwarded "
                "nowhere and recorded nowhere — drop the flags or let E1 run")
    return None


def waiver_block(build_report: Path, requested: str, reason: str) -> dict:
    """Audit record of the supply-floor waiver for the run manifest.

    Keyed exactly like the build report's `floors` block (`violations` /
    `waived` / `unwaived` / `waive_reason`) so the two records reconcile
    line-for-line, plus `violations_waived` (the violation strings the waiver
    actually covered) and the zero-row actions — an action with no rows cannot
    have been learned, and the manifest must not let a run read as if it were.
    """
    requested_floors = [w.strip() for w in (requested or "").split(",") if w.strip()]
    block: dict = {
        "requested_floors": requested_floors,
        "waive_reason": reason or "",
        "recorded": False,
        "build_report": {"path": str(build_report), "sha256": None},
    }
    if not Path(build_report).exists():
        block["note"] = ("no build report to read (dry run?) — a waiver is only "
                         "ever recorded by an executed build stage")
        return block
    rep = read_json(Path(build_report))
    floors = rep.get("floors", {}) or {}
    violations = list(floors.get("violations", []) or [])
    unwaived = list(floors.get("unwaived", []) or [])
    unwaived_set = set(unwaived)
    per_action = rep.get("per_action", {}) or {}
    targets = rep.get("per_action_target", {}) or {}
    zero_rows = sorted(a for a in targets if not per_action.get(a, 0))
    block.update({
        "violations": violations,
        "waived": list(floors.get("waived", []) or []),
        "violations_waived": [v for v in violations if v not in unwaived_set],
        "unwaived": unwaived,
        "waive_reason": floors.get("waive_reason") or reason or "",
        "usable_for_training": bool(floors.get("usable_for_training")),
        "zero_row_actions": zero_rows,
        "recorded": True,
        "build_report": {"path": str(build_report),
                         "sha256": sha256_file(build_report)},
    })
    if zero_rows:
        block["zero_row_actions_note"] = (
            "these actions had 0 training rows after the waiver — the artifact "
            "cannot have learned them and their harness gates are uninformative; "
            "internal testing only")
    block["note"] = (
        "UNWAIVED floor violations remain — nothing here authorizes training"
        if unwaived else
        "waived floors are an explicit internal-testing decision recorded in the "
        "build report; the artifact still has to clear the calibration and "
        "harness gates on its own merits")
    return block


def publish_reasons(smoke: bool, harness_exit: int | None, calibration_passed,
                    unchanged: bool, no_publish: bool, skip_calibration: bool,
                    version) -> tuple[list[str], str | None]:
    """Why the artifact must NOT be published (empty == publishable).

    Pure decision function: the reasons are the audit trail of a withheld
    publication, and they are unit-tested without running any stage.
    """
    reasons: list[str] = []
    if smoke:
        reasons.append("smoke run (wiring only): never publishes")
    if harness_exit not in (0, None):
        reasons.append("harness gates failed (see eval log / eval_manifest.jsonl)")
    if calibration_passed is False:
        reasons.append("calibration gate failed (accuracy-vs-confidence)")
    if calibration_passed is None and not skip_calibration:
        reasons.append("calibration gate not measurable (corpus below the contract "
                       "floor) — no calibrated claim can be made")
    if not unchanged:
        reasons.append("model.pt changed between eval and publish — provenance broken")
    if no_publish:
        reasons.append("--no-publish")
    if skip_calibration:
        reasons.append("calibration skipped — cannot claim a calibrated artifact")
    version_err = None
    if version is None:
        try:
            require_t035(version, "encoder.artifact.version")
        except T035PendingError as e:
            version_err = str(e)
        reasons.append("encoder.artifact.version is unset — the T-035 contract names "
                       "no artifact version, so the release step must set one")
    return reasons, version_err


def parse_args(argv=None):
    p = argparse.ArgumentParser(description="T-036: encoder pipeline (build→train→"
                                            "calibrate→eval→publish)")
    p.add_argument("--sources", nargs="*", default=None,
                   help="LLM-row JSONLs for stage E1 (omit to reuse an existing build)")
    p.add_argument("--build-report", default=None)
    p.add_argument("--work-dir", default=None)
    p.add_argument("--device", default="cpu")
    p.add_argument("--max-steps", type=int, default=0)
    p.add_argument("--max-train", type=int, default=0)
    p.add_argument("--smoke", action="store_true")
    p.add_argument("--fresh", action="store_true")
    p.add_argument("--skip-build", action="store_true")
    p.add_argument("--skip-calibration", action="store_true")
    p.add_argument("--export-onnx", action="store_true",
                   help="optional int8 ONNX export (T-037 owns on-device packaging)")
    p.add_argument("--publish-dir", default=None)
    p.add_argument("--no-publish", action="store_true")
    p.add_argument("--waive-floor", default="",
                   help="comma-separated supply floors to waive at the build stage "
                        "(build stage only; never forwarded to train/calibrate/eval): "
                        "corpus_floor,stt_noised_floor,per_action_floor")
    p.add_argument("--waive-reason", default="",
                   help="required with --waive-floor; recorded verbatim in the run "
                        "manifest and in the build report")
    p.add_argument("--consent-export", default=None,
                   help="REFUSED by design (NFR-015): real-user bundles are ops-gated")
    p.add_argument("--stage-timeout-seconds", type=float, default=None,
                   help="kill+retry a stage after N seconds (0 = no watchdog); "
                        "default encoder.pipeline.stage_timeout_seconds")
    p.add_argument("--stage-retries", type=int, default=None,
                   help="automatic RETRIES for a timed-out stage (only timeouts "
                        "are retried); default encoder.pipeline.stage_retries")
    p.add_argument("--dry-run", action="store_true")
    return p


def main(argv=None) -> int:
    args, cfg = load_config(parse_args(), argv)

    if args.consent_export:
        print("[guard] REFUSED: --consent-export is not implemented (NFR-015). Real "
              "user data only enters training through the consented export bundle "
              "path, which is an ops/T-035 gate; this pipeline will not ingest "
              "arbitrary rows.")
        return EXIT_GUARD
    refusal = waiver_refusal(args.waive_floor, args.waive_reason, args.skip_build,
                             bool(args.sources))
    if refusal:
        print(f"[guard] REFUSED: {refusal}")
        return EXIT_GUARD
    try:
        rules = load_rules()
        contract = load_contract(cfg.get("encoder.contract_path"), rules=rules)
        rules_sha = sha256_file(rules.path)
    except (RuntimeError, KeyError) as e:
        print(f"[guard] REFUSED: {e}")
        return EXIT_GUARD

    stamp = time.strftime("%Y%m%d-%H%M%S")
    work = Path(args.work_dir).expanduser() if args.work_dir else abs_path(cfg, "encoder.work_dir") \
        if cfg.get("encoder.work_dir") else ROOT / "artifacts" / f"encoder-run-{stamp}"
    work = work if work.is_absolute() else ROOT / work
    # Every path handed to a stage process is made absolute HERE: stage commands
    # run with cwd=ROOT (the tool root), which is not the caller's cwd — a
    # relative path forwarded verbatim would be silently resolved against the
    # wrong directory. Resolve against the caller's cwd, once, and log it.
    if args.sources:
        args.sources = [str(Path(s).expanduser().resolve()) for s in args.sources]
    if args.build_report:
        args.build_report = str(Path(args.build_report).expanduser().resolve())
    if args.publish_dir:
        args.publish_dir = str(Path(args.publish_dir).expanduser().resolve())
    work = work.resolve()
    log_dir = work / "logs"
    build_dir = work / "build"
    train_dir = work / "train"
    build_report = Path(args.build_report) if args.build_report else build_dir / "build_report.json"
    artifact = train_dir / "artifact"
    eval_manifest = work / "eval_manifest.jsonl"
    py = [sys.executable, "-u"]
    stages: list[dict] = []
    gates: dict = {}
    version = cfg.get("encoder.artifact.version")
    label = f"t036-{version}" if version else ("t036-smoke" if args.smoke else "t036-unversioned")
    # Stage policy: parameters (config.yaml / CLI), never constants. 0 timeout =
    # no watchdog (a training leg must not be killed by surprise); retries only
    # ever apply to timeouts.
    timeout_s = float(args.stage_timeout_seconds if args.stage_timeout_seconds is not None
                      else (cfg.get("encoder.pipeline.stage_timeout_seconds") or 0))
    retries = int(args.stage_retries if args.stage_retries is not None
                  else (cfg.get("encoder.pipeline.stage_retries") or 0))
    stage_opts = {"timeout_s": timeout_s, "retries": retries}

    print(f"[pipeline] work_dir={work} device={args.device} smoke={args.smoke} "
          f"label={label} rules_sha={rules_sha[:12]} contract_sha={contract.sha256[:12]}")
    print(f"[pipeline] stage policy: timeout_s={timeout_s} (0=no watchdog) "
          f"retries={retries} (only timeouts are retried)")

    # ---- stage E1: build --------------------------------------------------
    if args.sources and not args.skip_build:
        cmd = build_stage_cmd(py, args.sources, build_dir, build_report, args.smoke,
                              args.max_train, args.waive_floor, args.waive_reason)
        st = run_stage("build", cmd, log_dir, args.dry_run, **stage_opts)
        stages.append(st)
        if st.get("exit") not in (0, None):
            print("[pipeline] build failed — stopping before any GPU work")
            held = (build_report.exists()
                    and bool((read_json(build_report).get("floors", {}) or {}).get("unwaived")))
            if held:
                print("[pipeline] HOLD: floor violations remain UNWAIVED (T-034 §5.3) "
                      "— this corpus is not trainable and no waiver covers it")
                return EXIT_FLOOR
            return EXIT_STAGE
    elif not build_report.exists() and not args.dry_run:
        print(f"[guard] REFUSED: no build report at {build_report!s} and no --sources "
              "given — the corpus would be untraceable")
        return EXIT_GUARD
    else:
        print(f"[pipeline] reusing build report {build_report!s}")

    train_jsonl = build_dir / "train.jsonl"
    valid_jsonl = build_dir / "valid.jsonl"
    if not args.dry_run and not (train_jsonl.exists() and valid_jsonl.exists()):
        print(f"[guard] REFUSED: {train_jsonl!s} / {valid_jsonl!s} missing")
        return EXIT_GUARD

    # ---- stage E2: train --------------------------------------------------
    cmd = py + ["src/train_encoder.py", "--train", str(train_jsonl),
                "--valid", str(valid_jsonl), "--build-report", str(build_report),
                "--out-dir", str(train_dir), "--device", args.device]
    if args.max_steps:
        cmd += ["--max-steps", str(args.max_steps)]
    if args.max_train:
        cmd += ["--max-train", str(args.max_train)]
    if args.smoke:
        cmd.append("--smoke")
    if args.fresh:
        cmd.append("--fresh")
    st = run_stage("train", cmd, log_dir, args.dry_run, **stage_opts)
    stages.append(st)
    if st.get("exit") not in (0, None):
        print("[pipeline] training failed/refused — stopping (nothing to evaluate)")
        return EXIT_STAGE

    # ---- stage E3: calibrate ---------------------------------------------
    calib_report = work / "calibration_report.json"
    if not args.skip_calibration:
        cmd = py + ["src/calibrate_encoder.py", "--artifact", str(artifact),
                    "--valid", str(valid_jsonl), "--device", args.device,
                    "--report", str(calib_report)]
        st = run_stage("calibrate", cmd, log_dir, args.dry_run, **stage_opts)
        stages.append(st)
        # The report carries the tri-state verdict (True / False / None =
        # not measurable); the exit code alone cannot tell "failed" from
        # "the corpus cannot support a claim".
        if calib_report.exists():
            gates["calibration_gate_passed"] = read_json(calib_report).get(
                "gate", {}).get("passed")
        elif st.get("exit") not in (0, None):
            gates["calibration_gate_passed"] = False   # refused before any report
        if st.get("exit") not in (0, None):
            print("[pipeline] calibration did not pass or was not measurable — "
                  "continuing to the harness for the full picture; publication is "
                  "withheld")
    elif not args.dry_run and calib_report.exists():
        gates["calibration_gate_passed"] = bool(
            read_json(calib_report).get("gate", {}).get("passed"))
    else:
        gates["calibration_gate_passed"] = None  # skipped: no claim made

    # ---- optional ONNX export (T-037 boundary) ---------------------------
    onnx_path = ""
    if args.export_onnx:
        export_script = ROOT / "src" / "bakeoff_export_onnx.py"
        if not export_script.exists():
            print(f"[guard] REFUSED: {export_script!s} not present — on-device export "
                  "is T-037/T-033 tooling; refusing to silently skip it")
            return EXIT_GUARD
        onnx_path = str(work / "model-int8.onnx")
        st = run_stage("export", py + ["src/bakeoff_export_onnx.py",
                                       "--model", str(artifact), "--out", onnx_path],
                       log_dir, args.dry_run, **stage_opts)
        stages.append(st)
        if st.get("exit") not in (0, None):
            print("[pipeline] export failed — withholding publication")
            return EXIT_STAGE

    # ---- stage E4: the T-038 harness (never forked) -----------------------
    digest_before = sha256_file(artifact / "model.pt") if (artifact / "model.pt").exists() else None
    cmd = py + ["src/eval_golden.py", "--backend", "encoder", "--model-path",
                str(artifact), "--label", label, "--manifest-out", str(eval_manifest)]
    if args.dry_run:
        stages.append(run_stage("eval", cmd, log_dir, True, **stage_opts))
        print("[pipeline] dry run — no stages executed")
        return EXIT_OK
    st = run_stage("eval", cmd, log_dir, **stage_opts)
    stages.append(st)
    metrics = harness_metrics(eval_manifest)
    gates["harness_exit"] = st["exit"]
    gates["harness_gates_failed"] = (metrics or {}).get("metrics", {}).get("gates_failed")
    gates["harness_metrics"] = (metrics or {}).get("metrics")
    gates["checkpoint_sha256_prefix"] = (metrics or {}).get("checkpoint_sha256", "")[:12] or None
    gates["corpus_sha256_prefix"] = (metrics or {}).get("corpus_sha256", "")[:12] or None

    digest_after = sha256_file(artifact / "model.pt") if (artifact / "model.pt").exists() else None
    unchanged = digest_before is not None and digest_before == digest_after

    # ---- publish decision -------------------------------------------------
    reasons, version_err = publish_reasons(
        args.smoke, st.get("exit"), gates.get("calibration_gate_passed"), unchanged,
        args.no_publish, args.skip_calibration, version)

    run_manifest = {
        "schema": "encoder-pipeline-run/v1",
        "waiver": waiver_block(build_report, args.waive_floor, args.waive_reason),
        "created_utc": utc_now(),
        "work_dir": str(work),
        "smoke": bool(args.smoke),
        "device": args.device,
        "full_training_run_launched": not args.smoke and not args.max_steps,
        "rules": {"path": str(rules.path), "sha256": rules_sha,
                  "schema": "annotation-rules/v1"},
        "contract": {"path": str(contract.path), "sha256": contract.sha256,
                     "schema": contract.schema, "task": contract.source_task,
                     "branch": contract.source_branch,
                     "note": "consumed as the T-035 revision present in this worktree; "
                             "the sha is recorded so a later T-035 revision is "
                             "detectable, and all logit ordering comes from it"},
        "stages": stages,
        "gates": gates,
        "conformance": conformance_block(contract),
        "publish": {"published": False, "dir": None, "label": label,
                    "withheld_reasons": reasons,
                    "version": version, "version_error": version_err},
        "dependencies": {
            "T-035": "landed: consumed encoder_contract.yaml (canonical logit order, "
                     "loss weights, KD formula tau/lambda_kd, calibration gate "
                     "policy). Stage 2 stays OFF unless a measured teacher "
                     "distribution exists (contract loss.distillation.enabled="
                     "conditional). The contract names no artifact version, so "
                     "encoder.artifact.version must be set at release time.",
            "T-038": "eval harness owner; this pipeline calls eval_golden.py as-is. "
                     "Per-row emergency misses are NOT available at this harness "
                     "revision (only aggregate metrics in the JSONL manifest), so a "
                     "failed emergency gate gives no row-level diagnosis here.",
            "T-034": "annotation contract (annotation_rules.yaml) — copy pinned in "
                     "this repo, sha recorded above",
        },
        "consent": {"real_user_rows": 0,
                    "consent_export_ingestion": "not implemented (NFR-015); "
                                                "--consent-export refuses loudly"},
        "pii": {"utterance_content_logged": False,
                "note": "stage logs may contain paths/hashes/metrics only"},
    }

    publish_dir = Path(args.publish_dir) if args.publish_dir else (
        abs_path(cfg, "encoder.publish_dir") if cfg.get("encoder.publish_dir")
        else ROOT / "models")
    if not reasons:
        dest = publish_dir / str(version)
        dest.mkdir(parents=True, exist_ok=True)
        for f in sorted(artifact.iterdir()):
            if f.is_file():
                shutil.copy2(f, dest / f.name)
        for extra in ("manifest.json", "run_config.json", "calibration.json"):
            src = train_dir / extra
            if src.exists():
                shutil.copy2(src, dest / extra)
        if calib_report.exists():
            shutil.copy2(calib_report, dest / "calibration_report.json")
        if build_report.exists():
            shutil.copy2(build_report, dest / "build_report.json")
        if eval_manifest.exists():
            shutil.copy2(eval_manifest, dest / "eval_manifest.jsonl")
        run_manifest["publish"].update({"published": True, "dir": str(dest)})
        print(f"[publish] {version} -> {dest}")
    else:
        print(f"[publish] WITHHELD: {'; '.join(reasons)}")

    # The run manifest is written into the work dir, and into the published
    # artifact so a shipped directory carries its own provenance.
    write_json(work / "run_manifest.json", run_manifest)
    if run_manifest["publish"]["published"]:
        write_json(Path(run_manifest["publish"]["dir"]) / "run_manifest.json", run_manifest)
    print(f"[pipeline] run manifest -> {work / 'run_manifest.json'}")

    if reasons:
        return EXIT_GATE
    return EXIT_OK


if __name__ == "__main__":
    try:
        sys.exit(main())
    except GuardError as e:
        print(f"[guard] REFUSED: {e}")
        sys.exit(EXIT_GUARD)
