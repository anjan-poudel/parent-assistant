# Amendment 7 — T-190 (4B tier candidate) re-opened and executing (2026-10-17)

Status: **applied**. Source: **owner decision** 2026-10-17, relayed via the main session —
recorded with owner provenance: an owner-level decision that arrived via relay, not an
in-session approval by any agent.

## The decision

T-190 (the P2 4B tier candidate and its admission verdict, FR-CNR-028) is **re-opened** and
executes now, inside this run, in parallel with the in-flight v17 full-gate decode. The owner
wants the 4B chat variant for the iPhone 17 Pro Max. Amendment 6's descope of T-188, T-189 and
T-191 **stands unchanged**; only T-190 is carved back into this run. The successor initiative
home (`docs/features/2026-10-15-p2-conversation-polish-initiative.md`, main checkout) keeps
the other three legs.

## Scope of the re-opened leg (verbatim shape from its task file)

Per `specs/plan-tasks/tasks/TG-39-p2-polish-and-feasibility-honesty/T-190-p2-4b-tier-candidate-and-admission.md`
(unchanged): same corpus, same recipe, 4B base; a gated, non-default, resolver-reachable entry
with its own artifact identity and full-harness eligibility; tier admission (memory + latency)
measured with the 1.7B's method and the honest verdict recorded; the design's reference-tier
expectation (LIKELY NOT ADMISSIBLE on the 6 GB tier) confirmed or overturned by measurement
only, never by preference. Device-side latency/memory on the 17 Pro Max follows the training
leg.

## Applied

- `specs/CNR-p2-4b-tier-notes.md` — descope record retained verbatim (descoping must never be
  silent — nor un-descoping); RE-OPENED section appended with the execution record (base choice
  and rationale, corpus/recipe identity, launch identity, discipline, outstanding items).
- `specs/CNR-feasibility-honesty-report.md` — §5 and its leg-table row annotated (dated, citing
  this amendment): the state moves from OWNER-DESCOPED to re-opened/executing; **no measured
  outcome is claimed** (no gate report, no export identity, no admission measurement yet).
- `specs/implement-notes.md` — dated annotation appended to the P2 descope block.
- `specs/plan-tasks/plan.md` — wave-table row 9 annotated.

## Timing and identity

- Training launched 2026-10-17T04:37 box-local (Australia), box-side detached chain
  `/mnt/nvme1/cnr-v17/chain-train-4b.sh`, run id **cnr-v17-4b-20261017-0437**.
- In-flight parallel work untouched: the v17 full-gate decode (gate pid 85884; CPU-bound, all
  cores) and the funded judge replay chain are the only other box jobs. The GPU was verified
  idle before launch (0 compute processes; CUDA smoke green); after launch it carries the
  training run alone (measured 100% util / ~13.9 GB / 83 °C at ramp).
- Critical path unchanged: P0/P1 artifacts and the T-183 close sequence are unmodified by this
  amendment; T-190 rides in parallel.

## What this amendment does not do

- It does not promote anything: the 4B candidate will be a gated, non-default, resolver-only
  entry, and no tier selects it without the T-190 admission measurement.
- It does not alter T-192's recorded statement beyond the dated annotation above; every other
  verdict row keeps its recorded status.
- It does not re-open T-188/T-189/T-191.
