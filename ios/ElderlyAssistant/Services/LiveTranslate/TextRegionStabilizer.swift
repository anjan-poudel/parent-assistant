import CoreGraphics
import Foundation

// C03 — `TextRegionStabilizer` (T-009: identity, hysteresis, the change-only
// gate; T-010: the declutter stage, applied before emission).
//
// Scene-block rework, 2026-09-18: the regions this stabilises are **blocks**
// (see `SceneBlockGrouper`), and a region carries the grouper's own identity
// for its block. That identity is the strongest matching signal — it outranks
// the string — because it is the claim that a set of lines is one surface,
// which is precisely the claim OCR wobble inside a panel would otherwise
// break. Nothing else in this file changed: the hysteresis, the departure
// grace, the declutter stage and the change-only gate are the same rules over
// the same kind of value.
//
// What this file exists to make true:
//
//  - **One gate on translation traffic.** A region's translation is requested
//    only when its recognized text changes (including first appearance). An
//    unchanged scene therefore produces an empty change list and zero traffic
//    (FR-LCT-005, design §2). There is no timer, no clock and no "re-request
//    just in case" path.
//  - **Stable identity, keyed by the string first.** A region whose
//    normalized string equals an observation's, and that was seen within
//    `regionStringIdentityPasses`, is that observation's region however far
//    its box has moved: a camera movement is not a new sign, and re-keying
//    the region would release its identifier — and with it the overlay and
//    the already-answered question. Geometry is the tiebreaker and the
//    fallback: it separates two occurrences of one string seen on the same
//    screen (each keeps the occurrence nearest it), and it is what lets a
//    sign whose *text* changed keep its identifier, because its box did not
//    move. A region below every threshold with no string to claim it starts
//    a new identity.
//  - **Two-sided hysteresis.** A region is published after
//    `regionAppearPasses` consecutive observations and removed after
//    `regionMissPasses` consecutive misses; one missed pass leaves the region
//    and its translation intact. The identifier of a removed region is
//    released and never resurrected.
//  - **A departure is bounded in time, not only in passes** (owner device
//    verdict, 2026-09-17: "the translation sticks around even when the camera
//    moved away"). Pass-count hysteresis is the wrong unit for how long an
//    overlay may linger: two misses is 0.5 s at the nominal cadence but 1.4 s
//    at the reduced still-scene cadence, which is the one a scene being panned
//    off actually runs at. A published region whose last sighting is older
//    than `overlayDepartureGraceSeconds` therefore stops being published on
//    that pass — it leaves the emitted set within one cycle plus the grace —
//    while identity, box and translation stay until `regionMissPasses` retires
//    them and re-emission still costs `regionAppearPasses` fresh sightings.
//  - **Readable, bounded output (T-010).** Same-string neighbours closer than
//    `declutterMergeCentroidDistance` on either axis merge into one region
//    (longest string, union box), and a scene over `declutterMaxRegions`
//    keeps the highest-confidence set, tie-broken by centroid y then x.
//    Decluttering runs **before** emission, so the render and the translation
//    request always see exactly the same set (FR-LCT-006, OD5).
//  - **Pure, deterministic, clock-injected.** A value type with mutating
//    consumption: no I/O, no clock, no camera, no network, no storage. It
//    consumes whatever passes it is given, which is what makes scripted pass
//    sequences reproduce exactly in unit tests (NFR-LCT-010). The one fact it
//    cannot derive from a pass — *when* that pass happened, which the departure
//    grace is measured against — is a parameter, never a call to `Date()`
//    inside (the consent gate's `now:` seam, same convention). The default
//    exists for callers that do not script time; every timing assertion
//    supplies its own.
//  - **Content-free changes.** `RegionChangeEvent` carries region identities,
//    never a recognized string; the text the pipeline requests is read from
//    `visible`, which is the same set the overlay renders.
//
// Every threshold is a `LiveTranslateConfig` parameter, never a literal
// (NFR-LCT-011, OD5).

// MARK: - The feature's one text normalization

/// The feature's **one** text normalization — shared by C03's matching and
/// C05's cache key, so a region's text maps to exactly one key (T-009/T-012).
///
/// The rule is exactly three steps: **trim, collapse internal whitespace,
/// case-fold.** It is deliberately *not* extended with stemming, synonym
/// folding, Unicode normalization or diacritic folding: a near-miss must not
/// be served as if it were an exact match (FR-LCT-007). Two strings that
/// differ beyond those three steps — a ZWJ-joined conjunct versus its
/// unjoined form, say — stay different strings here, and the regression
/// fixture in `TextRegionStabilizerTests` pins that.
///
/// Whitespace is collapsed on Swift `Character`s, i.e. on **extended grapheme
/// clusters**: a Devanagari syllable and its vowel sign are one cluster, so
/// the collapse can neither split one nor leave a partial cluster behind.
enum LiveTranslateTextNormalization {

    /// The key's separator between the normalized text and the target
    /// language code (the design's `<normalizedText>|<targetLanguageCode>`).
    static let keySeparator = "|"

    /// trim + internal-whitespace collapse + case-fold.
    static func normalized(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
            .lowercased()
    }

    /// The cache key: `<normalizedText>|<targetLanguageCode>`.
    static func key(text: String, targetLanguage: String) -> String {
        normalized(text) + keySeparator + targetLanguage.lowercased()
    }

    /// The normalized text half of a key. Split at the **last** separator:
    /// the language code is the trailing token, so a recognized string that
    /// itself contains the separator still round-trips.
    static func normalizedText(fromKey key: String) -> String {
        guard let separator = key.range(of: keySeparator, options: .backwards) else { return key }
        return String(key[key.startIndex..<separator.lowerBound])
    }

    /// The target-language half of a key, or nil when the key has no
    /// separator (a shape this feature never writes — answered honestly
    /// rather than guessed).
    static func targetLanguage(fromKey key: String) -> String? {
        guard let separator = key.range(of: keySeparator, options: .backwards),
              separator.upperBound < key.endIndex else { return nil }
        return String(key[separator.upperBound...])
    }
}

// MARK: - C03

/// Pure region stabilisation and decluttering. Owned exclusively by the
/// pipeline actor; everything it needs is passed in.
struct TextRegionStabilizer {

    // MARK: Identity

    /// A region's stable identity.
    ///
    /// A **monotone counter**, not a UUID: identities must be reproducible
    /// (a scripted pass sequence replayed twice produces the very same
    /// identifiers) and an identity that has been released must never be
    /// resurrected. A counter gives both; a random source gives neither.
    struct RegionIdentity: Hashable, Comparable, Equatable, CustomStringConvertible {
        let rawValue: Int

        static func < (lhs: RegionIdentity, rhs: RegionIdentity) -> Bool {
            lhs.rawValue < rhs.rawValue
        }

        var description: String { "region#\(rawValue)" }
    }

    /// What the overlay renders for one visible region — the same set the
    /// translation request is built from.
    struct StableTextRegion: Equatable {
        let id: RegionIdentity
        /// The longest string of a merged set; the recognized string
        /// otherwise.
        let text: String
        /// trim + collapse + case-fold (shared with the cache key).
        let normalizedText: String
        let box: NormalizedBox
        let detectedLanguage: String?
        let confidence: Double
    }

    /// A change the pipeline must act on. Content-free by construction: an
    /// event names a region identity and nothing else, so no recognized
    /// string can travel in one. The text for an identity is read from
    /// `visible`, which is what keeps the request set and the render set
    /// identical.
    enum RegionChangeEvent: Equatable {
        /// The region reached its appear hysteresis and is now emitted.
        case appeared(id: RegionIdentity)
        /// A visible region's recognized text changed; its identity is kept.
        case textChanged(id: RegionIdentity)
        /// The region left the emitted set, by miss hysteresis or by the
        /// declutter cap. Its identity is released.
        case disappeared(id: RegionIdentity)
    }

    // MARK: Configuration and state

    let config: LiveTranslateConfig

    /// Internal tracking state, in identity order (append order). Identity
    /// order is the stable tie-break everywhere, so no dictionary iteration
    /// order can leak into an event.
    private var regions: [TrackedRegion] = []

    /// The previous pass's emitted set, for the change-only diff.
    private var emitted: [StableTextRegion] = []

    /// Monotone, never reset — not even by `reset()`: an identity that has
    /// been handed out is never handed out again.
    private var nextIdentityRawValue = 0

    /// The pass counter the string-identity window is measured against.
    ///
    /// Monotone and never reset, for the same reason the identity counter is
    /// not: a pass number that could repeat would make a sighting from before
    /// a reset look like a recent one. `reset()` empties `regions`, so no
    /// stale pass number can be read anyway — this is what keeps that true
    /// even if the two ever drift apart.
    private var passIndex = 0

    /// What the stabiliser carries for one region between passes.
    private struct TrackedRegion: Equatable {
        let id: RegionIdentity
        var text: String
        var normalizedText: String
        var box: NormalizedBox
        var detectedLanguage: String?
        var confidence: Double
        /// The grouper's identity for the block this region is, when the
        /// detector reported one (scene-block rework, 2026-09-18). It is the
        /// strongest identity signal there is — the member-string *set* of the
        /// block, for every block — because it is the same claim the grouper
        /// already made when it decided which lines are one surface. `nil` for
        /// a region that arrived by any other path, and updated on every match
        /// so it can never outlive the block it names.
        var blockIdentity: String?
        /// The pass number this region was last observed in — recognized or
        /// tracked. The string-identity window is measured from here, so a
        /// region that stops being seen eventually stops being claimable by
        /// its text.
        var lastSeenPass: Int
        /// When this region was last observed — recognized or tracked — as
        /// reported by the caller. The departure grace is measured from here;
        /// only emission reads it, so identity (which is a pass count) cannot
        /// depend on the clock.
        var lastSeenAt: Date
        /// Consecutive passes this region was observed in.
        var consecutiveDetections: Int
        /// Consecutive passes it was not observed in.
        var consecutiveMisses: Int
        /// Whether the appear hysteresis has been satisfied.
        var isPublished: Bool

        var stable: StableTextRegion {
            StableTextRegion(id: id, text: text, normalizedText: normalizedText,
                             box: box, detectedLanguage: detectedLanguage,
                             confidence: confidence)
        }
    }

    // MARK: Init

    init(config: LiveTranslateConfig = .default) {
        self.config = config
    }

    // MARK: Consumption

    /// Consumes one pass and returns the changes the pipeline must act on.
    ///
    /// `regions` are this pass's recognized observations (empty on a tracking
    /// pass); `tracked` is the detector's geometry for keys it still follows.
    /// The two empty cases are the same observation under either reading — a
    /// tracking pass that lost everything and an OCR pass that recognized
    /// nothing both mean "nothing was seen this pass" — so the semantics do
    /// not depend on telling them apart.
    ///
    /// `now` is when this pass happened, and it is the caller's to state: the
    /// only rule that reads it is the departure grace
    /// (`overlayDepartureGraceSeconds`), which decides when a region that has
    /// stopped being seen stops being *drawn*. The default keeps every caller
    /// that does not script time working unchanged, and — because consecutive
    /// calls then differ by microseconds — leaves the shipped pass-count
    /// hysteresis in charge for them. Duration assertions pass their own
    /// clock, so no test depends on how long a line of Swift takes to run.
    mutating func consume(regions observations: [LiveTextDetector.DetectedTextRegion],
                          tracked: [String: NormalizedBox] = [:],
                          at now: Date = Date()) -> [RegionChangeEvent] {
        passIndex += 1
        var seen: Set<RegionIdentity> = []

        // 1. Observations: match by normalized-string identity first, by
        //    geometry second, else start a new identity.
        for observation in observations {
            let normalized = LiveTranslateTextNormalization.normalized(observation.text)
            // An observation with nothing to translate, or with a box that
            // cannot be geometry, is not a region: it is not matched and not
            // created, so it counts as a miss for whatever it might have
            // matched (an unreadable sign must age out, not stay on screen).
            guard !normalized.isEmpty, observation.normalizedBox.isValid else { continue }

            if let index = bestMatchIndex(for: observation, normalized: normalized, seen: seen) {
                regions[index].text = observation.text
                regions[index].normalizedText = normalized
                regions[index].box = observation.normalizedBox
                regions[index].detectedLanguage = observation.detectedLanguage
                regions[index].confidence = observation.confidence
                regions[index].blockIdentity = observation.blockIdentity
                regions[index].lastSeenPass = passIndex
                regions[index].lastSeenAt = now
                regions[index].consecutiveDetections += 1
                regions[index].consecutiveMisses = 0
                seen.insert(regions[index].id)
            } else {
                let region = TrackedRegion(
                    id: RegionIdentity(rawValue: nextIdentityRawValue),
                    text: observation.text,
                    normalizedText: normalized,
                    box: observation.normalizedBox,
                    detectedLanguage: observation.detectedLanguage,
                    confidence: observation.confidence,
                    blockIdentity: observation.blockIdentity,
                    lastSeenPass: passIndex,
                    lastSeenAt: now,
                    consecutiveDetections: 1,
                    consecutiveMisses: 0,
                    isPublished: false)
                nextIdentityRawValue += 1
                regions.append(region)
                seen.insert(region.id)
            }
        }

        // 2. Tracked geometry: the region is still on screen, so it is not a
        //    miss, and its box moves with it. The text is untouched — a
        //    tracking pass cannot change a recognized string (T-007). A
        //    followed region is *seen*, so it refreshes the departure clock
        //    too: the overlay is following its box, and the grace exists for
        //    the camera having left, not for the OCR having skipped a pass.
        for (text, box) in tracked.sorted(by: { $0.key < $1.key }) {
            guard let index = regions.firstIndex(where: { !seen.contains($0.id) && $0.text == text })
            else { continue }
            regions[index].box = box
            regions[index].lastSeenPass = passIndex
            regions[index].lastSeenAt = now
            regions[index].consecutiveMisses = 0
            seen.insert(regions[index].id)
        }

        // 3. Hysteresis, in identity order — both directions, so one missed
        //    pass leaves the region (and its translation) intact while a
        //    first sighting does not yet paint an overlay.
        //
        //    The two directions are measured in different units on purpose.
        //    *Appearance* is passes: `regionAppearPasses` consecutive
        //    sightings, so a single false positive cannot paint a box, and an
        //    unpublished region that comes back pays that price again.
        //    *Departure* is bounded by both — `regionMissPasses` retires the
        //    identity, and `overlayDepartureGraceSeconds` un-publishes, which
        //    is the one the elder sees. The time bound is what keeps a
        //    departure honest at the reduced cadence, where two misses are
        //    1.4 s of translation hanging over text the camera has left.
        var survivors: [TrackedRegion] = []
        survivors.reserveCapacity(regions.count)
        for var region in regions {
            if seen.contains(region.id) {
                if !region.isPublished, region.consecutiveDetections >= config.regionAppearPasses {
                    region.isPublished = true
                }
            } else {
                region.consecutiveDetections = 0
                region.consecutiveMisses += 1
                if region.isPublished,
                   now.timeIntervalSince(region.lastSeenAt) >= config.overlayDepartureGraceSeconds {
                    // Out of the emitted set from this pass on — the next
                    // pass at the latest, whatever the cadence — while the
                    // identity, the box and the translation it carries stay
                    // until `regionMissPasses` retires them. A sighting
                    // within the grace never reaches here.
                    region.isPublished = false
                }
            }
            guard region.consecutiveMisses < config.regionMissPasses else { continue }
            survivors.append(region)
        }
        regions = survivors

        // 4. Declutter before emission (T-010), then diff for the change-only
        //    gate.
        let visible = Self.declutter(regions.filter(\.isPublished).map(\.stable), config: config)
        let changes = Self.changes(from: emitted, to: visible)
        emitted = visible
        return changes
    }

    /// The decluttered, published set this pass emits — the same set the
    /// overlay renders and the tier translates.
    var visible: [StableTextRegion] { emitted }

    /// Every region alive inside the stabiliser (published or still proving
    /// itself). Exposed for diagnostics; the pipeline consumes `visible`.
    var activeRegionCount: Int { regions.count }

    /// Drops every region — a process/system interruption. Identities are
    /// **not** recycled: the counter keeps climbing, so a late pass cannot
    /// resurrect an identifier this session already released. The pass
    /// counter keeps climbing too, and the region list is what makes the
    /// reset complete: a dropped region is not a candidate for anything, so
    /// its text cannot claim a region back into existence.
    mutating func reset() {
        regions.removeAll()
        emitted.removeAll()
    }

    // MARK: Matching

    /// The best existing region for an observation, or nil when nothing
    /// matches it.
    ///
    /// **A block claim outranks everything.** When the detector reports a
    /// `blockIdentity` — the grouper's member-string set, for every block,
    /// object or not — and a region is *the same surface of text*, seen within
    /// `regionStringIdentityPasses`, the two are the same surface whatever
    /// happened to the string inside it. This is the case the rework exists
    /// for: an OCR misread of one word of an appliance panel is not a new
    /// panel, and without this signal the region would be re-keyed and the
    /// panel repainted.
    ///
    /// "The same surface" includes a *regrouping* of the same lines — a panel
    /// and the pieces of itself — because the object pass is a cadenced,
    /// best-effort signal that changes its mind (`object_pass outcome=empty`
    /// over the very text it grouped a moment earlier). Treating a regrouping
    /// as a new surface is what left the owner's device drawing nothing: the
    /// region never reached `regionAppearPasses` again.
    ///
    /// **A conflicting block claim is a refusal, and only an unambiguous one
    /// is.** When both sides carry a block identity whose member lines have
    /// *nothing in common* — a panel and the sign beside it, a microwave's label
    /// where a television's was — the observation cannot take that region by
    /// geometry: the grouper has already said these are two surfaces, and only
    /// the string can still identify the region. Without this, a scene that
    /// resolved differently for one frame would hand one surface the other's
    /// identifier, and with it the other's translation, drawn over the wrong
    /// thing.
    ///
    /// A key that merely *differs* is not that case, which is what keeps the
    /// key additive: it can add a match, and it can refuse one between texts
    /// with nothing in common, but it can never take away a match the plain
    /// string-and-box rule would have made. An OCR misread of one member line
    /// shares the rest of them, so it is matched by the box that did not move —
    /// exactly as a region carrying no key at all would be.
    ///
    /// **The string is the identity; geometry is the tiebreaker and the
    /// fallback.** A region whose normalized text equals the observation's,
    /// and that was seen within `regionStringIdentityPasses`, is a candidate
    /// however far its box has moved — a camera movement is not a new sign,
    /// and re-keying the region would release its identifier, repaint the
    /// overlay and re-ask a question the session has already answered. Every
    /// other region must clear a geometry gate (`regionMatchIoU` or
    /// `regionMatchCentroidDistance`), which is what lets a sign whose *text*
    /// changed keep its identifier: its box did not move.
    ///
    /// A string match carries no distance limit, so among same-string
    /// candidates geometry decides — which is what keeps two occurrences of
    /// one word on one screen apart: each observation takes the occurrence
    /// nearest it, and `seen` makes the earlier choice unavailable to the
    /// later one.
    ///
    /// Among equals the higher IoU wins, then the shorter centroid distance,
    /// then the lower identity (the scan is in identity order, so the first
    /// wins a full tie). That ordering is total, which is what makes the
    /// choice reproducible.
    private func bestMatchIndex(for observation: LiveTextDetector.DetectedTextRegion,
                                normalized: String,
                                seen: Set<RegionIdentity>) -> Int? {
        var best: (index: Int, iou: Double, distance: Double,
                   sameBlock: Bool, sameString: Bool)?
        for (index, region) in regions.enumerated() where !seen.contains(region.id) {
            let iou = Self.intersectionOverUnion(region.box, observation.normalizedBox)
            let distance = Self.centroidDistance(region.box, observation.normalizedBox)
            let sameBlock: Bool
            if let claimed = observation.blockIdentity, let held = region.blockIdentity {
                sameBlock = passIndex - region.lastSeenPass <= config.regionStringIdentityPasses
                    && SceneBlockGrouper.identitiesDescribeTheSameSurface(claimed, held)
            } else {
                sameBlock = false
            }
            let sameString = region.normalizedText == normalized
                && passIndex - region.lastSeenPass <= config.regionStringIdentityPasses
            // Two blocks whose member lines have nothing in common are two
            // different surfaces, and geometry cannot make one into the other: a
            // panel and the sign beside it are not interchangeable however still
            // the frame was. Only the string can still identify the region in
            // that case.
            //
            // Nothing else is refused. Same text under a different *grouping* is
            // one surface, and that is what the object pass produces every time
            // it changes its mind; a shared member line with one of them misread
            // is not a different surface either, so the region is matched by its
            // box exactly as a region carrying no key at all would be — a member
            // line the OCR stumbled on does not re-key the panel it belongs to.
            // A `nil` on either side is not a claim, so a plain OCR region is
            // unaffected.
            if let claimed = observation.blockIdentity, let held = region.blockIdentity,
               SceneBlockGrouper.identitiesAreKnownToBeDifferentSurfaces(claimed, held),
               !sameString {
                continue
            }
            guard sameBlock
                    || sameString
                    || iou >= config.regionMatchIoU
                    || distance <= config.regionMatchCentroidDistance else { continue }
            let candidate = (index: index, iou: iou, distance: distance,
                             sameBlock: sameBlock, sameString: sameString)
            guard let current = best else { best = candidate; continue }
            if Self.isBetter(candidate, than: current) { best = candidate }
        }
        return best?.index
    }

    /// Strict improvement only: a full tie keeps the earlier (lower-identity)
    /// candidate, so the outcome cannot depend on iteration order.
    ///
    /// The block claim outranks the string claim, which outranks geometry: the
    /// grouper decided which lines are one surface from the objects and the
    /// reading geometry, and that decision survives the OCR wobble that changes
    /// a member line's string — which is exactly the case this ordering exists
    /// for. A region with no block identity (`nil` on either side) can never
    /// match by block, so nothing about a plain OCR region changes.
    private static func isBetter(_ candidate: (index: Int, iou: Double, distance: Double,
                                               sameBlock: Bool, sameString: Bool),
                                 than current: (index: Int, iou: Double, distance: Double,
                                                sameBlock: Bool, sameString: Bool)) -> Bool {
        if candidate.sameBlock != current.sameBlock { return candidate.sameBlock }
        if candidate.sameString != current.sameString { return candidate.sameString }
        if candidate.iou != current.iou { return candidate.iou > current.iou }
        if candidate.distance != current.distance { return candidate.distance < current.distance }
        return false
    }

    // MARK: Change-only diff

    /// The events between the previous emitted set and this pass's.
    ///
    /// Deterministic order: departures first (in identity order), then the
    /// new set in its own canonical order, so replaying a pass sequence
    /// yields the same list twice. A change is reported **only** when the
    /// normalized text differs — a moved box with the same text is not a
    /// translation event.
    private static func changes(from previous: [StableTextRegion],
                                to next: [StableTextRegion]) -> [RegionChangeEvent] {
        var events: [RegionChangeEvent] = []
        let nextIds = Set(next.map(\.id))
        for region in previous.sorted(by: { $0.id < $1.id }) where !nextIds.contains(region.id) {
            events.append(.disappeared(id: region.id))
        }
        let previousByIdentity = Dictionary(uniqueKeysWithValues: previous.map { ($0.id, $0) })
        for region in next {
            guard let before = previousByIdentity[region.id] else {
                events.append(.appeared(id: region.id))
                continue
            }
            if before.normalizedText != region.normalizedText {
                events.append(.textChanged(id: region.id))
            }
        }
        return events
    }

    // MARK: Declutter (T-010)

    /// Reduces a candidate set to what a person can read on a phone screen:
    /// same-string neighbours merge, and the cap keeps the
    /// highest-confidence set.
    ///
    /// Pure and order-independent on purpose: the merge pairs are chosen in
    /// identity order and the output is re-ordered canonically, so the same
    /// candidates presented in two different array orders produce the same
    /// regions, the same boxes and the same order.
    static func declutter(_ candidates: [StableTextRegion],
                          config: LiveTranslateConfig) -> [StableTextRegion] {
        canonicalOrder(capped(merged(candidates, config: config), config: config))
    }

    /// Merge: same normalized string **and** centroid distance below
    /// `declutterMergeCentroidDistance` on **either** axis → one region,
    /// longest string of the set, box = union of the merged boxes so the
    /// overlay still points at all of them.
    ///
    /// Applied until no pair qualifies (a union can move a centroid), picking
    /// the lowest-identity qualifying pair each round — a total rule, so the
    /// result cannot depend on the order the candidates arrived in.
    private static func merged(_ candidates: [StableTextRegion],
                               config: LiveTranslateConfig) -> [StableTextRegion] {
        var working = candidates.sorted { $0.id < $1.id }
        while let pair = firstMergeablePair(in: working, config: config) {
            let combined = merge(working[pair.0], working[pair.1])
            working.remove(at: pair.1)
            working[pair.0] = combined
        }
        return working
    }

    private static func firstMergeablePair(in regions: [StableTextRegion],
                                           config: LiveTranslateConfig) -> (Int, Int)? {
        guard regions.count > 1 else { return nil }
        for lower in regions.indices {
            for upper in regions.index(after: lower)..<regions.endIndex {
                if shouldMerge(regions[lower], regions[upper], config: config) {
                    return (lower, upper)
                }
            }
        }
        return nil
    }

    /// Same normalized string and close on either axis. Regions with
    /// different strings never merge, and no concatenation of two strings is
    /// ever produced.
    private static func shouldMerge(_ a: StableTextRegion,
                                    _ b: StableTextRegion,
                                    config: LiveTranslateConfig) -> Bool {
        guard a.normalizedText == b.normalizedText else { return false }
        let dx = abs(a.box.center.x - b.box.center.x)
        let dy = abs(a.box.center.y - b.box.center.y)
        return dx < config.declutterMergeCentroidDistance
            || dy < config.declutterMergeCentroidDistance
    }

    /// One region for a merged pair: the lower identity carries it (so the
    /// overlay keeps a stable owner), the text is the **longest** of the set
    /// (the most informative rendering; the lower identity wins a tie), and
    /// the box is the union.
    private static func merge(_ a: StableTextRegion, _ b: StableTextRegion) -> StableTextRegion {
        let longer = b.text.count > a.text.count ? b : a
        return StableTextRegion(
            id: a.id,
            text: longer.text,
            normalizedText: a.normalizedText,
            box: union(a.box, b.box),
            detectedLanguage: a.detectedLanguage ?? b.detectedLanguage,
            confidence: max(a.confidence, b.confidence))
    }

    /// Cap: over `declutterMaxRegions` the highest-confidence regions are
    /// kept, tie-broken by centroid y then x (then identity), so the same
    /// input always yields the same set (OD5). Regions outside the cap are
    /// simply not emitted — no error, no degraded marker; a region that stays
    /// visible can still resolve on a later pass.
    private static func capped(_ regions: [StableTextRegion],
                               config: LiveTranslateConfig) -> [StableTextRegion] {
        guard regions.count > config.declutterMaxRegions else { return regions }
        let ranked = regions.sorted { lhs, rhs in
            if lhs.confidence != rhs.confidence { return lhs.confidence > rhs.confidence }
            if lhs.box.center.y != rhs.box.center.y { return lhs.box.center.y < rhs.box.center.y }
            if lhs.box.center.x != rhs.box.center.x { return lhs.box.center.x < rhs.box.center.x }
            return lhs.id < rhs.id
        }
        return Array(ranked.prefix(config.declutterMaxRegions))
    }

    /// The emitted set's canonical order: top-to-bottom, then left-to-right,
    /// then by identity. Geometric on purpose — the order is a property of
    /// where the text is, not of when it was seen.
    private static func canonicalOrder(_ regions: [StableTextRegion]) -> [StableTextRegion] {
        regions.sorted { lhs, rhs in
            if lhs.box.center.y != rhs.box.center.y { return lhs.box.center.y < rhs.box.center.y }
            if lhs.box.center.x != rhs.box.center.x { return lhs.box.center.x < rhs.box.center.x }
            return lhs.id < rhs.id
        }
    }

    // MARK: Geometry

    private static func intersectionOverUnion(_ a: NormalizedBox, _ b: NormalizedBox) -> Double {
        let xOverlap = max(0, min(a.xMax, b.xMax) - max(a.xMin, b.xMin))
        let yOverlap = max(0, min(a.yMax, b.yMax) - max(a.yMin, b.yMin))
        let intersection = xOverlap * yOverlap
        let union = area(a) + area(b) - intersection
        return union > 0 ? intersection / union : 0
    }

    private static func centroidDistance(_ a: NormalizedBox, _ b: NormalizedBox) -> Double {
        let dx = a.center.x - b.center.x
        let dy = a.center.y - b.center.y
        return (dx * dx + dy * dy).squareRoot()
    }

    private static func area(_ box: NormalizedBox) -> Double {
        max(0, box.xMax - box.xMin) * max(0, box.yMax - box.yMin)
    }

    private static func union(_ a: NormalizedBox, _ b: NormalizedBox) -> NormalizedBox {
        NormalizedBox(xMin: min(a.xMin, b.xMin),
                      yMin: min(a.yMin, b.yMin),
                      xMax: max(a.xMax, b.xMax),
                      yMax: max(a.yMax, b.yMax))
    }
}
