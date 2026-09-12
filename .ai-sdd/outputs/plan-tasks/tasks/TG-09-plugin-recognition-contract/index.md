# TG-09: Plugin Recognition & Contract

> **Jira Epic:** Plugin Recognition & Contract

## Description

Makes plugin recognition honest and brain-independent: today plugin prompt fragments are composed only by the cloud interpreter, and the two on-device interpreters structurally cannot emit `action = "plugin"` at all. This group measures that reality (T-039, GO/NO-GO), designs the plugin contract v2 — recognition parity, the `PluginCommand.transcript` contract, core-enforced confirmation governance, and the compile-time/iOS-only invariants (T-040) — implements the chosen routing and contract fixes (T-041, T-042, T-043), and turns every load-bearing claim in `docs/plugin-architecture.md` into an executable test (T-044).

**Reconciliation with TG-08.** TG-08 (Nepali Intent Encoder) proposes a fixed-class on-device encoder as the primary intent recogniser, demoting the LLM to a fallback. A closed-class encoder cannot ingest runtime plugin prompt fragments and cannot emit arbitrary namespaced action names, so the two designs must not diverge silently:

- T-039 evaluates the encoder as one of five recognition paths, but the encoder branch is strictly **conditional on the T-033 GO**. If T-033 returns NO-GO, the encoder path is out of scope and T-039's decision must not assume an encoder exists. The LLaMA-path gap (LlamaCommandInterpreter deliberately omits plugin fragments; its GBNF grammar and JSON schema exclude the value "plugin") is real today and is therefore **not** conditional on TG-08.
- If T-039 selects the "encoder emits a plugin gate class and core's deterministic registry matcher resolves it" option, that is a change request against the TG-08 taxonomy and data tasks: it must be recorded in T-039's decision and in T-040's design, and cross-referenced against [T-035](../TG-08-nepali-intent-encoder/T-035-joint-intent-slot-encoder-design.md) (encoder taxonomy design) and [T-036](../TG-08-nepali-intent-encoder/T-036-training-distillation-pipeline.md) (training data). No TG-08 task file is edited by TG-09; the change is carried as an explicit input to those tasks.
- If T-039 selects any other option, T-040 must state that the encoder taxonomy carries **no** plugin class and that plugin eligibility on the encoder brain is handled outside the model (deterministic matcher or cloud pinning), so T-035's design is not contradicted later.

**Boundary this group does not cross.** The plugin system remains capability expansion only: emergency, medication acknowledgement/reminders, and the deterministic keyword layer stay in core (constitution; `design doc §5`). Android has no plugin runtime today and this group does not build one — it writes that invariant down and keeps it true. No dynamic plugin loading (signed bundles, marketplaces) is introduced; registration stays a fixed compile-time list (`PluginRegistry.swift:7-9`).

## Tasks

| ID | Title | Effort | Depends on | Risk |
|----|-------|--------|------------|------|
| [T-039](T-039-plugin-recognition-brains-rnd.md) | Plugin Recognition Across Brains — R&D Decision (GO/NO-GO) | M | — | HIGH |
| [T-040](T-040-plugin-contract-v2-design.md) | Plugin Contract v2 Design (recognition parity, transcript, governance) | M | T-039 | HIGH |
| [T-041](T-041-brain-independent-plugin-routing.md) | Implement Brain-Independent Plugin Recognition | M | T-040 | HIGH |
| [T-042](T-042-transcript-contract-and-doc-truth.md) | PluginCommand.transcript Contract + plugin-architecture.md Truth-Up | S | T-040 | MEDIUM |
| [T-043](T-043-plugin-confirmation-governance.md) | Plugin Confirmation Governance (core-enforced) | M | T-040 | HIGH |
| [T-044](T-044-plugin-doc-contract-verification.md) | Doc-as-Contract Verification Suite | L | T-041, T-042, T-043 | HIGH |

## Group effort estimate

- Optimistic (1 iOS dev + reviewer, T-042 in parallel with T-041): 21–33 days
- Realistic (1 iOS dev, review round-trips, T-043 enforcement touches router flow): 24–38 days
- Entry gate: none hard — T-039 can start immediately; only its encoder branch waits on the T-033 GO/NO-GO
- The group never extends the critical path of TG-08: T-039–T-044 are iOS-side work and run inside the existing iOS stream
