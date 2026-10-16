# ModelWarden — the app's memory manager, explained in pictures

> For humans and future sessions. The implementation lives in
> `ios/ElderlyAssistant/Services/ModelStore/` (`ModelLifecycleManager`,
> `ModelLoadReservation`, `ModelBudgetPolicy`, `ModelCostModel`) and the design
> spec is `docs/superpowers/specs/2026-09-18-model-memory-manager-proposal.md`.

## 1. The problem it exists for

The app hosts a growing zoo of on-device models, and the device has already
been **CPU-watchdog-killed** while two big models overlapped (99% CPU over
49 s, 1.2–1.4 GB footprint alongside a 2.5 GB brain). Jetsam (iOS's memory
reaper) is silent and external — by the time it kills you, you get no error,
just a missing app.

```mermaid
flowchart LR
    subgraph Zoo["The model zoo"]
        W["WhisperKit STT<br/>~1.0 GB"]
        B["Intent brain<br/>1.7B: 1.98 GB<br/>4B: 3.40 GB"]
        T["Translation model<br/>1.7B / 3B ladder"]
        P["Piper TTS<br/>~84 MB"]
        E["Encoder / KWS / VAD<br/>~0.14 GB + small"]
    end
    Zoo --> Device["iPhone 14 Pro Max<br/>5.5 GB RAM<br/>~3.2 GB usable budget"]
    Device -->|"two big models at once"| Kill["💀 watchdog / jetsam kill"]
```

## 2. The invariant it enforces

> **Peak resident memory ≈ the largest allowed model + a fixed working-set
> allowance — never two big models at once unless the budget proves they fit.**

Budgets are per **device class**:

| Class (physical RAM) | Model budget | Warm STT it keeps | Brain ladder | Example pick |
|---|---|---|---|---|
| compact (< 5 GB) | 2.0 GB | 0.65 GB (whisper.cpp small) | ≤ 1.0 GB file | 1B |
| standard (5–7 GB) | 3.2 GB | 1.00 GB (ANE) | ≤ 1.5 GB file | **1.7B** |
| roomy (≥ 7 GB) | 5.0 GB | 1.00 GB (ANE) | any | 4B / 3B |

A 3B does **not** fit a 6 GB phone beside a warm STT (2.82 + 1.00 = 3.82 > 3.2)
— the policy says so, and Automatic never picks it there.

## 3. The pieces

```mermaid
flowchart TB
    subgraph Warden["ModelWarden (one actor owns permission; handles stay with owners)"]
        RL["Reservation ledger<br/>in-flight requests + TTL"]
        Q["Serial load queue<br/>max 1 large load at a time"]
        LM["ModelLifecycleManager<br/>slots + budgets + victims"]
        PL["Priority ladder<br/>safetyCritical > foreground > background"]
        PR["Preemption<br/>ask → ack / refusal → force rules"]
        TG["Thrash guard<br/>load-rate cap + cooldowns"]
        BP["ModelBudgetPolicy<br/>what may be chosen per class"]
        CM["ModelCostModel<br/>reload cost vs residency value"]
    end
    Owners["Owners<br/>voice turn · whisper · live-translate tier"]
    Probe["MemoryProbe + phys_footprint + pressure DispatchSource"]
    Owners -->|"reserve/commit/abandon"| RL --> Q --> LM
    LM --> PL --> PR --> TG
    BP --> Owners
    CM --> LM
    Probe --> LM
```

## 4. How a load happens (reserve → commit → abandon)

No model may load without permission, and no two large loads run at once:

```mermaid
sequenceDiagram
    participant O as Owner (e.g. voice turn)
    participant W as ModelWarden
    participant R as Resident (other model)

    O->>W: reserve(model, purpose, footprint)
    W->>W: probe memory + subtract in-flight reservations
    alt fits?
        W->>R: ask lower-priority resident to unload
        R-->>W: ack (or refusal — see §6)
        W->>W: re-probe hard bytes, record permit
        W-->>O: permit
        O->>O: load model (serialized, one at a time)
        O->>W: commit
    else does not fit / denied
        W-->>O: deny(reason)  — fail fast, never silent
        O->>O: honest degraded path (e.g. cloud tier)
    end
    O->>W: abandon (done / cancelled / timed out)
```

## 5. Who may evict whom (the priority ladder)

```mermaid
flowchart LR
    S["safetyCritical<br/>live voice turn<br/>asks anything, asked by nothing<br/>never rate-capped"]
    F["foreground<br/>live translate<br/>capped + can be preempted"]
    B["background<br/>warm / maintenance<br/>capped"]
    S --> F --> B
```

Victim order: **ladder → heavy-first → cost-model score → LRU → size**.

## 6. Preemption (revocable leases)

```mermaid
sequenceDiagram
    participant W as ModelWarden
    participant V as Victim (lower priority)
    W->>V: releaseForWarden
    alt can release now
        V-->>W: ack(unloaded)
    else cannot
        V-->>W: refusal(reason)
        alt force allowed? (llama: yes)
            W->>V: force unload
        else NEVER forced (whisper perAttemptContext)
            W-->>W: restore bytes, refuse the new load instead
        end
    end
```

Repeated preemptions quarantine the victim (cooldown 20 s, 3 strikes → 120 s).

## 7. Automatic model picks (policy-aware)

```mermaid
flowchart TD
    A["Device asks: which brain?"]
    B{"Stored explicit preference?"}
    B -->|"yes, still in catalogue"| E["Use it — never overridden<br/>(even if over-budget: soloOverBudget)"]
    B -->|no / stale| C{"Does the class<br/>hold the default<br/>beside a warm STT?"}
    C -->|yes| D["Use the default"]
    C -->|no| F{"Any curated model<br/>fits beside warm STT?"}
    F -->|yes| G["Pick the largest that fits<br/>(6 GB → 1.7B, not 4B)"]
    F -->|no| H["Pick the lightest,<br/>flagged requires_evicting_warm_stt"]
```

## 8. The cost model (who pays to stay resident)

A resident's eviction score:

```
score = idleSeconds × freedBytes ÷ reloadCostSeconds
```

- ANE WhisperKit reload = **77 s** (135 s after a failed specialization) → it is
  almost never evicted (ANE-last by arithmetic, not a special case).
- whisper.cpp reload = 2 s → cheap to evict.
- The measured `load_ms` from real events replaces the priors over time.

## 9. What it cannot do (honest limits)

- iOS has **no app-controlled swap** — "offload" always means release + reload.
- **Jetsam is external and silent**; `os_proc_available_memory()` is advisory.
- The real invariant is *at most one large commit + one large load at a time*,
  not "peak equals the largest model" — release is never atomic.
- The only non-code lever is the `increased-memory-limit` entitlement.

## 10. The knobs (all runtime-mutable)

`maxConcurrentLargeLoads=1` · `largeLoadThresholdBytes=256MB` ·
`reservationTTLSeconds=30` · `loadWatchdogSeconds=120` ·
`unloadAckDeadlineSeconds=2` · `preemptionCooldownSeconds=20` ·
`preemptionsBeforeQuarantine=3` · `maxLoadsPerMinute=4` ·
`costAwareEvictionEnabled=true` · `idleEvictionPenalty=1.0`
