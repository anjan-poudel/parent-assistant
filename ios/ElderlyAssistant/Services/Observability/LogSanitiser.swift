import Foundation

/// Removes PII from observability event metadata before it reaches any log
/// sink (Console / OSLog / disk / remote crash reporter).
///
/// Constitution §Privacy requires: "Logs must not contain PII (names, health
/// values, contacts). Log sanitiser required." This is the single choke point
/// for that guarantee — every `ObservabilityBus` implementation must route
/// through `sanitise(_:)` before emitting.
///
/// Approach:
///  - allow-listed metadata keys pass through verbatim (id hashes, counts,
///    enum tags, boolean flags),
///  - unknown keys are dropped rather than logged, so a caller adding a new
///    field cannot leak PII by accident,
///  - values on allowed keys are still scrubbed for obvious PII patterns
///    (phone numbers, e-mails, blood-pressure readings) as defence in depth,
///  - the top-level `error_code` is bounded to a code shape and a maximum
///    unbroken-run length (see `boundErrorCode`) — [T-050/B2] it was the one
///    content-bearing field copied through unscrubbed, which is how a
///    key-bearing URL reached the console.
struct LogSanitiser {

    /// Longest `error_code` preserved verbatim at the bus boundary.
    static let maxErrorCodeLength = 64

    /// Codes are identifier-shaped: letters, digits and `._:-,;`.
    /// Anything else — spaces, `=`, quotes, `/`, `@`, braces, i.e. the
    /// shape an `Error` or `URL` description arrives in — is not a code
    /// and is replaced with `[redacted]` rather than logged.
    ///
    /// [T-050 / finding B2] `error_code` is a top-level event field copied
    /// through with no scrub, which is how `String(describing: URLError)`
    /// carried a key-bearing URL to the console. Emitters are fixed to
    /// pass content-free codes (`ErrorCodeMapper`); this bound catches the
    /// shapes a future emitter is most likely to hand over by accident (a
    /// rendered error or URL, a bare key-shaped token). It is a *shape*
    /// bound, not an entropy proof: a secret that is shorter than the run
    /// limit, or that the code charset splits into sub-limit runs, still
    /// passes verbatim — so nothing secret may be passed as `error_code`
    /// in the first place.
    private static let safeErrorCodePattern = try! NSRegularExpression(
        pattern: #"^[A-Za-z0-9][A-Za-z0-9._:,;\-]*$"#)

    /// Longest unbroken alphanumeric run tolerated in an `error_code`.
    /// Codes are short words joined by `_` / `-` / `,` (the longest run in
    /// the live vocabulary is `delivery`); a Google API key is one unbroken
    /// 39-character run (`AIza…`). 32 sits between the two.
    static let maxUnbrokenRunLength = 32

    /// Built from `maxUnbrokenRunLength` so the two cannot drift apart.
    private static let longRunPattern = try! NSRegularExpression(
        pattern: "[A-Za-z0-9]{\(maxUnbrokenRunLength),}")

    /// Keys known to carry non-PII values. Anything else is dropped.
    static let allowedKeys: Set<String> = [
        "entry_id_hash",
        "contact_id_hash",
        "refire_count",
        "entry_count",
        "alert_type",
        "outcome",
        "state",
        "duration_ms",
        "error_code",
        // [SCOPE-LEDGER] (2026-09-17) Google scope NAMES, normalized —
        // "calendar" / "contacts". Fixed vocabulary, no account data, no
        // token material; the console must be able to show which scope
        // is granted or missing (the ledger's whole diagnostic value).
        "calendar",
        "contacts",
        // [DECODE-DIAGNOSTIC] (2026-09-17) The Google SCHEMA field an
        // inbound decode failed on — e.g. "key_not_found:nextSyncToken".
        // Fixed schema vocabulary (field names + DecodingError kinds),
        // never content: the value is built by
        // `GoogleCalendarGateway.decodeDetail(from:)`, whose only inputs
        // are the error kind and the coding path.
        "decode_detail",
        // [DEAD-TAP-RECOVERY] (2026-09-17) The count of audio chunks a
        // capture received — count-shaped, the discriminator between a
        // silent capture and a dead tap.
        "chunks",
        // [TURN-TIMING] The serialized per-turn stage list
        // (`[{stage, ms}, …]`) — stage names and integer durations only,
        // never transcript or reply text (see VoiceTurnLatencyTracer).
        "stages",
        // [MULTIPART-DOWNLOAD] Which part of a multi-asset download failed
        // and why — the on-device report that drove this was three lines
        // ("download_started" … "download_checksum_failed") with nothing
        // naming the part or the HTTP status. NUMERIC ONLY by contract:
        // `part` / `parts` are indices and counts, `bytes` a byte count,
        // `http_status` an HTTP status code. Never a URL, never a body.
        "part",
        "parts",
        "bytes",
        "http_status",
        // [TG-12] The STT-error corrector's `turn_correction` payload. Each
        // value is count-only or binned BY CONSTRUCTION (A-16,
        // `CorrectionResult.observabilityMetadata`): mode and state are fixed
        // vocabulary, the counts are integers, `correction_reasons` and
        // `correction_classes` are `<token>:<count>` histograms over closed
        // vocabularies, `correction_entry_ids` are the bank's own row ids
        // (`lex-<n>` ordinals or authored `stt-reduction-*` ids — never a
        // surface form), the veto is a rule name, and the two buckets are
        // 0.05-wide ranges written `0.80~0.85` — a TILDE separator, because the
        // phone-number guard below matches a hyphenated six-digit run and would
        // redact the whole bucket. No key here may ever carry a transcript word,
        // a correction target or a raw score; a test pins that claim against the
        // builder, so a new key cannot be added to the event without being
        // added here deliberately.
        "correction_mode",
        "correction_state",
        "correction_lexicon_revision",
        "correction_tokens_considered",
        "correction_applied_count",
        "correction_threshold_bucket",
        "correction_reasons",
        "correction_veto",
        "correction_entry_ids",
        "correction_classes",
        "correction_class_origins",
        "correction_best_bucket",
        "correction_margin_bucket",
        // [LIVE-CAMERA-TRANSLATION] The feature's event metadata
        // (`Services/LiveTranslate/` `LiveTranslateEvents.swift`, T-003).
        // ADDITIVE ONLY: nothing above is removed, renamed or reordered.
        // Count-shaped, duration-shaped and closed-vocabulary values only, by
        // construction of the emitter API — `LiveTranslateEvents.MetadataKey`
        // is the only way one of these keys is spelled, and every one of its
        // cases is mirrored here (a test pins the two sets against each
        // other). No key here may ever carry recognized text, a translation,
        // an image or a scene identifier; the feature's catalogue and its
        // tests enforce that, and the values that land are integers, closed
        // tokens and the disclosure version stamp.
        "regionCount",
        // [LIVE-CAMERA-TRANSLATION] (2026-09-18) The one addition the owner's
        // identity-churn report asked for: `regionSetHash`, a 32-bit digest of
        // the *set* of normalized strings on screen, rendered `xxxx:xxxx` by
        // `LiveTranslateEvents.regionSetHashHex` from a `UInt32` — the emitter
        // takes no string, so no recognized text can reach this key. It is a
        // discriminator and nothing more: it is derived from the scene, not from
        // the device, the session or the user, it is never stored, and it is
        // stable only within one session's own log (where the owner compares two
        // lines). It carries no string, no substring and no per-region value;
        // being truncated to 32 bits it is not a commitment about the content
        // either. The colon in the rendering is deliberate: it is outside the
        // phone-number guard's character class below, which would otherwise
        // redact an all-digit digest intermittently and silently.
        "regionSetHash",
        "stringCount",
        "batchIndex",
        "batchCount",
        "resolvedCount",
        "unresolvedCount",
        "durationMs",
        "keyCount",
        "count",
        "origin",
        "mode",
        "reason",
        // [CASCADE-PROVENANCE] (2026-09-19) Which tier answered a settle —
        // `TranslationTier`, a closed token set (dictionary / onDeviceBrain
        // / cloud). The owner asked to log the cascade; no string rides in it.
        "tier",
        // [LLAMADEBUG] (2026-09-17) Where an on-device brain attempt stopped
        // — `BrainFailureStage`, a closed token set (availability / load /
        // prompt_budget / decode / deadline / cancelled / stage_deadline).
        // The device report behind it: every live-translate cycle logged
        // `brain_translation_unavailable` and the `reason` token could not
        // say which of four different failures it was.
        "failureStage",
        // [EMPTY-DECODE] (2026-09-19) The three keys the owner's
        // answered-nothing capture needed. Every brain batch ran 7–20 seconds
        // and resolved nothing, and `resolvedCount`/`unresolvedCount`/
        // `durationMs` could not say whether the decode emitted anything at
        // all or emitted a well-formed answer that every rule refused — two
        // different bugs with two different fixes.
        //
        //  - `generationLength` is a character COUNT of the raw answer. The
        //    characters themselves are never passed to the emitter, which
        //    takes a `BrainGenerationReading` and renders only its integer.
        //  - `generationShape` is `BrainGenerationShape`, a closed token set
        //    (empty / unparsable / no_array / array).
        //  - `rejections` is a histogram keyed by `BrainAnswerRejection`,
        //    another closed set, rendered `token:count,…` (or `none`). A
        //    closed enum is the only key type, so a recognized string has no
        //    way to be expressed in this value.
        "generationLength",
        "generationShape",
        "rejections",
        "disclosureVersion",
        // [LIVE-CAMERA-TRANSLATION] AM-2 decision, recorded rather than
        // widened silently: `cap`. The shipped `GeminiCostGovernor` emits
        // `daily_cap_warning` / `daily_cap_reached` with metadata `count` and
        // `cap` on component `gemini_cost`. Until this extension both keys
        // were dropped by this allow-list, so the family-visible cap signal
        // arrived with no count and no cap — the cap doing its job looked
        // like a cap doing nothing. `cap` is count-shaped and additive, and
        // the feature does not touch the shipped payloads: a test drives the
        // real governor over its cap and asserts both keys survive.
        "cap",
        // [LIVE-CAMERA-TRANSLATION] AM-2 decision, recorded rather than
        // widened silently: the code key. A code normally travels on the
        // event's top-level `errorCode` field, which `boundErrorCode`
        // (T-050/B2) already bounds — and the feature's own emitters use
        // exactly that field. Allow-listing the metadata spelling keeps the
        // design's catalogue convention ("content-free code" for the failure
        // events) inside the allow-list instead of silently dropping the
        // code, which is CL-5's failure mode. **It is not left unbounded**:
        // `codeShapedMetadataKeys` routes this one key through the same
        // `boundErrorCode` the top-level field gets, so it cannot become the
        // unbounded twin that the B2 defect was. Tests pin both halves: a
        // real code survives, a description does not.
        "errorCode",
        // [CLOUD-CASCADE] The cascade tier's `cloud_cascade_escalated`
        // payload (2026-09-16): which online provider took the turn and the
        // two scores that decided it. NUMBERS AND AN ID ONLY —
        // `provider` is a `CloudProvider` raw value ("gemini", a fixed
        // vocabulary), `threshold` and `confidence` are 0…1 scores
        // rendered "%.2f" by `PipelineTraceSummary.score` — never the
        // transcript, never the reply, never an API key (C9 policy). The
        // same `provider` key the `cloud_fallback` state event already
        // emits.
        "provider",
        "threshold",
        "confidence",
        // [MODEL-WARDEN] Step 0 (2026-09-18) — the memory ledger's own
        // vocabulary. The `model_lifecycle` component has been emitting
        // `slot` / `liveBytes` / `evicted` / `budgetBytes` since the ledger
        // shipped and every one of them was being DROPPED here, so the
        // family-visible memory story arrived as an event with no bytes in
        // it. These additions close that and cover the reservation layer
        // (`reserved` / `reservation_denied` / `reservation_committed` /
        // `reservation_abandoned` / `footprint_sample`).
        //
        // VALUES ARE BYTE COUNTS, MILLISECONDS, CLOSED TOKENS OR SLOT NAMES
        // BY CONSTRUCTION — `slot` / `evicted` are `ModelSlot` raw values,
        // `purpose` is a `ReservationPurpose` raw value, `reason` is a
        // closed denial/abandon token, `liveBytes` / `budgetBytes` /
        // `freed_bytes` / `phys_footprint` / `ceiling_bytes` /
        // `working_set_bytes` / `projected_peak_bytes` are integers,
        // `load_ms` and `heldSeconds` are durations, `priority` and
        // `isLargeLoad` are a closed token and a boolean. No key here may
        // ever carry a transcript, a prompt, a file path or a model URL —
        // the ledger deals in positions and bytes only, and a test pins
        // that claim against the bridge.
        "slot",
        "liveBytes",
        "budgetBytes",
        "evicted",
        "purpose",
        "isLargeLoad",
        "heldSeconds",
        // `T(t)` — the reserved-but-not-yet-loaded byte count. Named after
        // the ledger's own `liveBytes` rather than the proposal's `T` so a
        // capture reads as one vocabulary.
        "transientLiveBytes",
        // The cost-model keys §5.5 of the proposal names. `phys_footprint`
        // is the kernel's own number for us (`task_info(TASK_VM_INFO)`),
        // `ceiling_bytes` the app's jetsam limit, `working_set_bytes` the
        // non-model estimate W(t), `projected_peak_bytes` the M+T+W
        // projection, `freed_bytes` what an eviction actually returned, and
        // `load_ms` how long a load took — the quantity the thrash guard
        // and the Step 3 load-rate limit are built on. `priority` is
        // reserved for Step 2's ladder so its first field capture does not
        // require a sanitiser change to be readable.
        "phys_footprint",
        "ceiling_bytes",
        "working_set_bytes",
        "projected_peak_bytes",
        "freed_bytes",
        "load_ms",
        "priority"
    ]

    /// Metadata keys whose value must satisfy the *code* bound rather than a
    /// PII scrub alone. Deliberately a separate set from `allowedKeys`: the
    /// shipped snake_case `error_code` is **not** listed here, because
    /// shipped emitters already write it and re-bounding it would change
    /// their behaviour (NFR-LCT-012). Bounding a key that did not exist
    /// before this feature is additive; changing one that did is not.
    private static let codeShapedMetadataKeys: Set<String> = ["errorCode"]

    private static let piiPatterns: [NSRegularExpression] = {
        let patterns = [
            // phone numbers (7+ digits, common separators)
            #"\+?\d[\d\s\-().]{6,}\d"#,
            // e-mail addresses
            #"[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}"#,
            // blood-pressure-like readings (systolic/diastolic)
            #"\b\d{2,3}\s*/\s*\d{2,3}\b"#
        ]
        return patterns.compactMap { try? NSRegularExpression(pattern: $0) }
    }()

    func sanitise(_ event: ObservabilityEvent) -> ObservabilityEvent {
        var cleanMetadata: [String: String] = [:]
        for (key, value) in event.metadata where Self.allowedKeys.contains(key) {
            // A code-shaped key gets the same bound as the top-level field,
            // so allow-listing it cannot become a PII-scrubbed bypass of
            // that bound (T-050/B2). Every other allowed key is unchanged.
            cleanMetadata[key] = Self.codeShapedMetadataKeys.contains(key)
                ? (boundErrorCode(value) ?? "")
                : scrubValue(value)
        }
        return ObservabilityEvent(
            component: event.component,
            eventType: event.eventType,
            durationMs: event.durationMs,
            outcome: event.outcome,
            errorCode: boundErrorCode(event.errorCode),
            metadata: cleanMetadata
        )
    }

    /// Bounds a top-level `error_code` (T-050). Order matters: scrub first
    /// (phone / e-mail / BP shapes), then require the code charset — a
    /// value that fails it is not a code at all, so it is replaced rather
    /// than logged, then reject a key-shaped unbroken run (a pasted API
    /// key is charset-valid), and finally cap the length. A charset-valid,
    /// run-legal but over-long value is truncated — still content-free by
    /// shape, and codes are short by design.
    private func boundErrorCode(_ errorCode: String?) -> String? {
        guard let errorCode, !errorCode.isEmpty else { return nil }
        let scrubbed = scrubValue(errorCode)
        let range = NSRange(scrubbed.startIndex..<scrubbed.endIndex, in: scrubbed)
        guard Self.safeErrorCodePattern.firstMatch(in: scrubbed, options: [],
                                                   range: range) != nil else {
            return "[redacted]"
        }
        guard Self.longRunPattern.firstMatch(in: scrubbed, options: [],
                                             range: range) == nil else {
            // One unbroken 32+-character alphanumeric token: a key or a
            // hash, never a code — truncating it would still log most of
            // the secret.
            return "[redacted]"
        }
        return String(scrubbed.prefix(Self.maxErrorCodeLength))
    }

    private func scrubValue(_ value: String) -> String {
        var result = value
        let range = NSRange(result.startIndex..<result.endIndex, in: result)
        for pattern in Self.piiPatterns {
            result = pattern.stringByReplacingMatches(
                in: result,
                options: [],
                range: NSRange(result.startIndex..<result.endIndex, in: result),
                withTemplate: "[redacted]"
            )
            _ = range
        }
        return result
    }
}
