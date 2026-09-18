import CoreGraphics
import Foundation

// C13 — `SceneBlockGrouper` (owner UX verdict, 2026-09-18: "maximize text
// regions — bigger but fewer translations — and use object detection bounding
// boxes").
//
// What this file exists to make true:
//
//  - **The scene resolves into a few large surfaces, not a swarm of lines.**
//    A pass's recognized lines and a pass's detected objects go in; a small,
//    ordered set of *blocks* comes out. A block is the unit everything
//    downstream works on: the stabiliser stabilises blocks, the translation is
//    requested per block, and the overlay draws one panel per block. The
//    per-line box is no longer a render surface anywhere in the feature.
//  - **An object is the grouping when one is detected.** A recognized line
//    whose box lies inside a detected object's box belongs to that object, and
//    all the lines of one object are one block. The block's rect is anchored
//    to the *object's* box — a control panel is a physical thing that does not
//    move when one of its words is misread — intersected with the text it
//    actually holds, so a detected appliance does not become an opaque slab
//    over the whole of itself.
//  - **Everything else groups by reading geometry.** Leftover lines merge into
//    blocks by vertical proximity and shared column (overlapping x-ranges or a
//    shared left edge), transitively, so a column of menu lines becomes one
//    surface rather than five. The merge distance is deliberately generous
//    (`blockMergeDistance`): the owner's direction is fewer and bigger, not
//    per-line fidelity.
//  - **Deterministic, total, and pure.** No clock, no I/O, no Vision, no
//    camera. Every ordering is a total order over the inputs — reading order
//    first, then the block's own identity — so the same scene presented in any
//    array order produces the same blocks, in the same order, with the same
//    rects and the same identities. That is what makes a scripted scene a unit
//    test rather than a screenshot.
//  - **Identity is a property of what the block *is*.** A text block's
//    identity is the **set of its member strings** (order-independent, so a
//    line reordering is not a new block); an object block's is the **object
//    class plus its quantised centroid**, so OCR wobble inside a panel — the
//    common case, and the one that used to re-key a region per frame — keeps
//    the block and its translation. Quantisation is at `blockMergeDistance`,
//    the same distance the merge rule uses, so "the same block" means the same
//    thing in both places.
//  - **The budget is the sanitisation budget.** Merging stops before a block's
//    text would exceed `sceneTextMaxLength`, the per-string bound
//    `SceneTextSanitiser` truncates at: a block that was allowed to grow past
//    it would be silently cut off in the middle on its way to the tier, losing
//    whole lines. Keeping blocks under the bound is what makes truncation
//    impossible rather than merely unlikely. An object's text is bound by the
//    same rule, with the same consequence for breaking it: an object holding
//    more text than one request may carry goes down the text path in pieces
//    that fit rather than becoming one truncated panel.
//  - **The cap is the owner's number.** At most `maxVisibleBlocks` blocks reach
//    the live overlay, ranked by how much text they carry and then by
//    confidence, so a dense scene resolves to the few surfaces a person can
//    actually read. The blocks outside the cap are not errors: they are what the
//    snapshot card is for, and a block that later grows into the cap resolves
//    then. The cap belongs to the caller, not to the grouping — the snapshot
//    pass asks for every block, because there is no overlay there to crowd.

/// One recognized line of the scene, as the grouper takes it in.
///
/// The grouper's own input type, deliberately: it is pure and has no Vision,
/// no detector and no camera in it, so a fixture is a handful of literal
/// boxes.
struct SceneTextLine: Equatable {
    let text: String
    /// The feature's one box representation (0–1, origin top-left).
    let normalizedBox: NormalizedBox
    let confidence: Double
    let detectedLanguage: String?
}

/// One detected physical object: a box, and the class the runtime could name
/// it with (or `nil` when it could not name one — an unnamed object is still
/// an object, and still groups the text inside it).
struct SceneObjectBox: Equatable {
    let classLabel: String?
    let normalizedBox: NormalizedBox
    let confidence: Double
}

/// One surface the overlay draws: a physical object's text, or a merged text
/// block. The unit the stabiliser, the translation request and the panel all
/// work on.
struct SceneBlock: Equatable {

    /// What made this block a block.
    enum Kind: Equatable {
        /// The text inside a detected object's box. `classLabel` is the
        /// runtime's name for the object, or nil when it had none.
        case object(classLabel: String?)
        /// Text grouped by reading geometry alone (a menu, a sign, packaging).
        case text

        /// The class label, for the object kind.
        var classLabel: String? {
            guard case .object(let label) = self else { return nil }
            return label
        }
    }

    let kind: Kind
    /// The rect the panel is anchored to: the object's box (clipped to the
    /// text it holds), or the union of the merged lines.
    let normalizedBox: NormalizedBox
    /// The member lines, in reading order (top to bottom, then left to right).
    /// Never empty: a block with nothing to translate is not a block.
    let lines: [SceneTextLine]
    /// The block's stable identity — the member-string *set* for a text block,
    /// the object class plus quantised centroid for an object block. Survives
    /// line reordering, OCR wobble inside an object, and box jitter.
    let identityKey: String

    /// The block's text as the one string the translation request carries: the
    /// member lines joined by newlines, in reading order. One request per
    /// block — this is the "fewer translations" half of the owner's direction.
    var text: String { lines.map(\.text).joined(separator: Self.lineSeparator) }

    /// The separator between a block's lines. A newline, because that is what
    /// the tiers are handed and what the panel splits the answer on.
    static let lineSeparator = "\n"

    /// The recognized strings, in reading order.
    var memberStrings: [String] { lines.map(\.text) }

    /// The block's confidence: the highest of its members. A block is credible
    /// if the best line in it is; averaging would let one misread line pull a
    /// confident panel below a threshold it should clear.
    var confidence: Double { lines.map(\.confidence).max() ?? 0 }

    /// The block's language: the first member that reported one. Vision
    /// reports per observation, and a block is one surface, so the block
    /// reports the first honest answer its members gave.
    var detectedLanguage: String? {
        lines.compactMap(\.detectedLanguage).first
    }
}

/// Lines + objects → blocks. Pure, deterministic, total.
enum SceneBlockGrouper {

    // MARK: - Entry point

    /// Groups one pass's recognized lines and detected objects into blocks,
    /// capped at the live overlay's number of visible surfaces
    /// (`config.maxVisibleBlocks`).
    ///
    /// The shape every live caller wants. A caller that is not the live overlay
    /// — the snapshot card — says so by naming the `limit:` overload instead.
    static func group(lines: [SceneTextLine],
                      objects: [SceneObjectBox],
                      config: LiveTranslateConfig = .default) -> [SceneBlock] {
        group(lines: lines, objects: objects, config: config,
              limit: config.maxVisibleBlocks)
    }

    /// Groups one pass's recognized lines and detected objects into blocks.
    ///
    /// Total: every input line either joins an object, merges into a text
    /// block, or is dropped for having nothing to translate — and the result
    /// is never larger than `limit`.
    ///
    /// `limit` is the number of *visible surfaces*, not a property of the
    /// grouping, and **`nil` is uncapped rather than "the config's number"**:
    /// the live path passes `config.maxVisibleBlocks`, and the snapshot pass
    /// passes `nil` because the snapshot card is the fully-readable mode —
    /// every block it can find is one more thing the reader can see at size,
    /// and there is no overlay for a fifth block to crowd. The grouping itself
    /// is identical either way; only the budget differs. That is why the two
    /// are separate overloads rather than one function with a defaulted
    /// parameter: an omitted argument and a deliberate `nil` are different
    /// requests, and one signature cannot tell them apart.
    static func group(lines: [SceneTextLine],
                      objects: [SceneObjectBox],
                      config: LiveTranslateConfig = .default,
                      limit: Int?) -> [SceneBlock] {
        // 1. Canonical input order, so no caller's array order can reach the
        //    result: reading order (top to bottom, then left to right), then
        //    the string, then the box. Total, so ties cannot fall back on
        //    whatever order the detector happened to report.
        let usable = lines
            .filter { !LiveTranslateTextNormalization.normalized($0.text).isEmpty
                      && $0.normalizedBox.isValid }
            .sorted(by: precedes)
        let usableObjects = objects.filter { $0.normalizedBox.isValid }

        // 2. Object membership: a line belongs to the smallest detected object
        //    whose box contains it. Smallest, because a microwave inside a
        //    kitchen is still one panel, and the tighter box is the panel.
        var ownedByObject: [Int: [SceneTextLine]] = [:]
        var leftover: [SceneTextLine] = []
        for line in usable {
            if let index = smallestContainingObject(of: line.normalizedBox, in: usableObjects) {
                ownedByObject[index, default: []].append(line)
            } else {
                leftover.append(line)
            }
        }

        // 2b. An object whose text would not fit the sanitisation budget is not
        //     one surface: its lines go down the text path in pieces that do
        //     fit, rather than being truncated mid-line on their way to the
        //     tier. The budget is the same bound the merge rule respects, so
        //     "a block's text fits" means one thing here.
        for (index, members) in ownedByObject.sorted(by: { $0.key < $1.key }) {
            let joined = members.map(\.text).joined(separator: SceneBlock.lineSeparator)
            guard joined.count > config.sceneTextMaxLength else { continue }
            ownedByObject[index] = nil
            leftover.append(contentsOf: members)
        }

        // 3. One block per object that owns text. An object with no recognized
        //    text is not a surface: there is nothing to translate for it, and
        //    drawing a panel over it would be a bubble with no words in it.
        var blocks: [SceneBlock] = []
        for (index, members) in ownedByObject.sorted(by: { $0.key < $1.key }) {
            let object = usableObjects[index]
            blocks.append(SceneBlock(
                kind: .object(classLabel: object.classLabel),
                normalizedBox: objectBox(object.normalizedBox, holding: members),
                lines: members,
                identityKey: objectIdentity(classLabel: object.classLabel,
                                            box: object.normalizedBox,
                                            mergeDistance: config.blockMergeDistance)))
        }

        // 4. Everything else: line-cluster grouping by proximity and column.
        for cluster in textClusters(from: leftover, config: config) {
            blocks.append(SceneBlock(kind: .text,
                                     normalizedBox: union(cluster.map(\.normalizedBox)),
                                     lines: cluster,
                                     identityKey: textIdentity(of: cluster)))
        }

        // 5. The cap: the owner's "fewer, bigger" as a number the config owns
        //    on the live path, and no cap at all where every block is legible.
        //
        //    `nil` is a caller saying there is nothing to crowd — not "use the
        //    config's number". The two are different questions and the
        //    difference is the whole point of the parameter: the snapshot card
        //    asks for every block it can find, and a fallback here would hand
        //    it the live overlay's four.
        let ranked = blocks.sorted { left, right in
            let leftArea = memberArea(left)
            let rightArea = memberArea(right)
            if leftArea != rightArea { return leftArea > rightArea }
            if left.confidence != right.confidence { return left.confidence > right.confidence }
            return precedes(left, right)
        }
        guard let visible = limit else { return readingOrder(ranked) }

        return readingOrder(Array(ranked.prefix(max(0, visible))))
    }

    // MARK: - Object membership

    /// The smallest object whose box contains the line, or nil when none does.
    ///
    /// Containment is a *coverage* rule rather than a point test: the line's own
    /// centre has to be inside the object, and at least half of the line's area
    /// has to be — a line straddling an object's edge is text of the scene, not
    /// text of the object, and the honest answer for it is the text-block path.
    ///
    /// "Smallest" is decided here, from the boxes themselves: the tightest
    /// enclosing box is the panel, and a microwave inside a kitchen is one
    /// panel rather than two. The tie-break is geometric and total (area, then
    /// top edge, then left edge, then the class label) rather than "whatever
    /// order the caller passed" — object detection reports its boxes in the
    /// runtime's own order, and a grouping that changed with it would make the
    /// whole feature's output depend on Vision's internals.
    static func smallestContainingObject(of line: NormalizedBox,
                                         in objects: [SceneObjectBox]) -> Int? {
        var best: (index: Int, rank: (Double, Double, Double, String))?
        for (index, object) in objects.enumerated()
        where contains(object.normalizedBox, line: line) {
            let box = object.normalizedBox
            let rank = (area(box), box.yMin, box.xMin, object.classLabel ?? "")
            guard let current = best else {
                best = (index, rank)
                continue
            }
            if Self.rank(rank, precedes: current.rank) { best = (index, rank) }
        }
        return best?.index
    }

    /// Whether `left` sorts before `right` as "the tighter object": smaller
    /// area first, then higher in the frame, then further left, then the class
    /// label — the last only so two boxes identical in geometry still have one
    /// defined answer.
    private static func rank(_ left: (Double, Double, Double, String),
                             precedes right: (Double, Double, Double, String)) -> Bool {
        if left.0 != right.0 { return left.0 < right.0 }
        if left.1 != right.1 { return left.1 < right.1 }
        if left.2 != right.2 { return left.2 < right.2 }
        return left.3 < right.3
    }

    /// Whether `object` holds `line`: the line's centre inside the object, and
    /// at least half the line's area inside it.
    static func contains(_ object: NormalizedBox, line: NormalizedBox) -> Bool {
        let centre = line.center
        guard centre.x >= object.xMin, centre.x <= object.xMax,
              centre.y >= object.yMin, centre.y <= object.yMax else { return false }
        let lineArea = area(line)
        guard lineArea > 0 else { return false }
        return intersectionArea(object, line) / lineArea >= 0.5
    }

    /// The rect an object block is drawn on: the object's own box, clipped to
    /// the text it holds.
    ///
    /// The object's box is the anchor — a control panel keeps its rect while a
    /// character inside it is misread, which is the stability the owner asked
    /// for. The clip is what stops a detected microwave from becoming a slab
    /// over the whole of itself: the panel covers the part of the object that
    /// carries the words, never more.
    static func objectBox(_ object: NormalizedBox, holding lines: [SceneTextLine]) -> NormalizedBox {
        guard !lines.isEmpty else { return object }
        let text = union(lines.map(\.normalizedBox))
        let clipped = intersect(object, text)
        // A degenerate clip cannot happen through `contains` (half the line's
        // area is inside), but a caller may hand in a hand-built block: the
        // object's own box is the honest answer then, never a zero-area rect.
        return clipped.xMax > clipped.xMin && clipped.yMax > clipped.yMin ? clipped : object
    }

    // MARK: - Text-block grouping

    /// Merges leftover lines into blocks: repeatedly join the closest
    /// mergeable pair until no pair qualifies.
    ///
    /// Transitive by construction — a column of five lines is one block, not
    /// two — and the pair chosen each round is the one with the smallest
    /// vertical gap, ties going to the pair whose members come first in
    /// reading order, so the result cannot depend on the order the lines
    /// arrived in.
    static func textClusters(from lines: [SceneTextLine],
                             config: LiveTranslateConfig) -> [[SceneTextLine]] {
        var clusters: [[SceneTextLine]] = lines.map { [$0] }
        while let pair = firstMergeablePair(in: clusters, config: config) {
            let merged = clusters[pair.0] + clusters[pair.1]
            clusters.remove(at: pair.1)
            clusters[pair.0] = merged.sorted(by: precedes)
        }
        return clusters
    }

    /// The closest mergeable pair, or nil when the clusters are already
    /// blocks. Lowest index first, then lowest gap: a total rule.
    private static func firstMergeablePair(in clusters: [[SceneTextLine]],
                                           config: LiveTranslateConfig) -> (Int, Int)? {
        guard clusters.count > 1 else { return nil }
        var best: (pair: (Int, Int), gap: Double)?
        for lower in clusters.indices {
            for upper in clusters.index(after: lower)..<clusters.endIndex {
                guard let gap = mergeGap(clusters[lower], clusters[upper], config: config)
                else { continue }
                // Strictly closer wins, so the first pair encountered takes a
                // tie: the clusters are in reading order, which makes the answer
                // independent of how the lines arrived.
                if let current = best, gap >= current.gap { continue }
                best = ((lower, upper), gap)
            }
        }
        return best?.pair
    }

    /// How far apart two clusters are, when they may merge at all: nil when
    /// they may not.
    ///
    /// Two clusters merge when **both** hold:
    ///
    ///  - their vertical gap is within `blockMergeDistance` — the generosity
    ///    the owner asked for: a menu read as five lines becomes one surface;
    ///  - they share a column: their x-ranges overlap by at least half the
    ///    narrower of the two, or their left edges (or their centres) are
    ///    within the merge distance — which is what keeps two side-by-side
    ///    signs, or a label beside its value, from becoming one panel.
    ///
    /// And the merged text must still fit the sanitisation budget, so a block
    /// can never be truncated on its way to the tier.
    static func mergeGap(_ left: [SceneTextLine],
                         _ right: [SceneTextLine],
                         config: LiveTranslateConfig) -> Double? {
        guard !left.isEmpty, !right.isEmpty else { return nil }
        let leftBox = union(left.map(\.normalizedBox))
        let rightBox = union(right.map(\.normalizedBox))

        let verticalGap = max(0, max(leftBox.yMin - rightBox.yMax, rightBox.yMin - leftBox.yMax))
        guard verticalGap <= config.blockMergeDistance else { return nil }

        let overlap = min(leftBox.xMax, rightBox.xMax) - max(leftBox.xMin, rightBox.xMin)
        let narrower = min(leftBox.xMax - leftBox.xMin, rightBox.xMax - rightBox.xMin)
        let sharedColumn = (narrower > 0 && overlap / narrower >= 0.5)
            || abs(leftBox.xMin - rightBox.xMin) <= config.blockMergeDistance
            || abs(leftBox.center.x - rightBox.center.x) <= config.blockMergeDistance
        guard sharedColumn else { return nil }

        let merged = (left + right).map(\.text).joined(separator: SceneBlock.lineSeparator)
        guard merged.count <= config.sceneTextMaxLength else { return nil }

        return verticalGap
    }

    // MARK: - Identity

    /// A text block's identity: the **set** of its member strings, normalized
    /// and sorted. Order-independent on purpose — a reordered pair of lines is
    /// the same sign, and re-keying it would repaint the panel and re-ask a
    /// question the session has already answered.
    static func textIdentity(of lines: [SceneTextLine]) -> String {
        let members = lines.map { LiveTranslateTextNormalization.normalized($0.text) }.sorted()
        return "text" + identitySeparator + members.joined(separator: identitySeparator)
    }

    /// An object block's identity: the class plus the **quantised** centroid.
    ///
    /// Quantised at `blockMergeDistance`, so a panel that jitters *inside* a
    /// cell keeps its identity — and with it its panel, its translation and its
    /// place in the overlay. An unnamed object keeps the same identity under a
    /// placeholder rather than falling out of the scheme.
    ///
    /// A grid has edges, and an object whose centroid sits on one crosses it
    /// with the smallest jitter. That is not a failure of the scheme but a
    /// division of labour: the key says *which* surface, and
    /// `identitiesShareScope` plus the stabiliser's geometry say whether a
    /// changed key is the same surface seen again or a different one. See
    /// `identitiesShareScope`.
    static func objectIdentity(classLabel: String?,
                               box: NormalizedBox,
                               mergeDistance: Double) -> String {
        let step = mergeDistance > 0 ? mergeDistance : 1
        let centre = box.center
        let qx = Int((centre.x / step).rounded())
        let qy = Int((centre.y / step).rounded())
        return objectPrefix + identitySeparator + (classLabel ?? "?")
            + identitySeparator + "\(qx),\(qy)"
    }

    /// Whether two identity keys name the same **scope**: the same kind of
    /// surface with the quantised geometry left out.
    ///
    /// This is the distinction the stabiliser needs, and it is not the same
    /// question as "are these the same block".
    ///
    /// *Different scope, different surface.* An object the runtime named and
    /// the text panel beside it are not interchangeable however still the frame
    /// was, and neither are a microwave and a television at one address: the
    /// runtime said they are two things, and geometry must not overrule it.
    ///
    /// *Same scope, same surface seen again.* One microwave panel whose
    /// quantised centroid crossed a cell edge between two passes is still the
    /// one microwave panel — the key changed and the surface did not — so the
    /// stabiliser is free to match it by geometry and hand it back its
    /// identifier and its translation. Without this, every object sitting near
    /// a grid line would be re-keyed (and re-asked, and briefly drawn twice)
    /// for moving a hundredth of the frame.
    ///
    /// A text key has no geometry in it at all: its member set *is* its
    /// identity, so its scope is the whole key, and two different sets of lines
    /// are two different signs rather than one sign that jittered.
    static func identitiesShareScope(_ left: String, _ right: String) -> Bool {
        scope(of: left) == scope(of: right)
    }

    private static func scope(of key: String) -> String {
        let parts = key.components(separatedBy: identitySeparator)
        guard parts.count >= 3, parts[0] == objectPrefix else { return key }
        return parts.prefix(2).joined(separator: identitySeparator)
    }

    /// The separator inside an identity key. A control character, so it cannot
    /// collide with a recognized string.
    private static let identitySeparator = "\u{1}"

    /// The kind of a key whose scope is coarser than the key: an object block's.
    private static let objectPrefix = "object"

    // MARK: - Order

    /// Reading order: top to bottom, then left to right, then the text, then
    /// the box. Total, so two identical lines still have a defined order.
    private static func precedes(_ left: SceneTextLine, _ right: SceneTextLine) -> Bool {
        if left.normalizedBox.center.y != right.normalizedBox.center.y {
            return left.normalizedBox.center.y < right.normalizedBox.center.y
        }
        if left.normalizedBox.center.x != right.normalizedBox.center.x {
            return left.normalizedBox.center.x < right.normalizedBox.center.x
        }
        if left.text != right.text { return left.text < right.text }
        if left.normalizedBox.yMin != right.normalizedBox.yMin {
            return left.normalizedBox.yMin < right.normalizedBox.yMin
        }
        return left.normalizedBox.xMin < right.normalizedBox.xMin
    }

    /// The blocks' canonical order — the same order the stabiliser, the
    /// placement and the spoken reading order use.
    private static func readingOrder(_ blocks: [SceneBlock]) -> [SceneBlock] {
        blocks.sorted { left, right in
            if left.normalizedBox.center.y != right.normalizedBox.center.y {
                return left.normalizedBox.center.y < right.normalizedBox.center.y
            }
            if left.normalizedBox.center.x != right.normalizedBox.center.x {
                return left.normalizedBox.center.x < right.normalizedBox.center.x
            }
            return left.identityKey < right.identityKey
        }
    }

    private static func precedes(_ left: SceneBlock, _ right: SceneBlock) -> Bool {
        if left.normalizedBox.center.y != right.normalizedBox.center.y {
            return left.normalizedBox.center.y < right.normalizedBox.center.y
        }
        if left.normalizedBox.center.x != right.normalizedBox.center.x {
            return left.normalizedBox.center.x < right.normalizedBox.center.x
        }
        return left.identityKey < right.identityKey
    }

    // MARK: - Geometry

    /// How much text a block carries, as the area its member lines cover: the
    /// ranking quantity for the cap. Area rather than confidence, because it is
    /// a property of the scene and not of how sure Vision felt this frame, so
    /// the same scene keeps the same blocks in the same order.
    private static func memberArea(_ block: SceneBlock) -> Double {
        block.lines.reduce(0) { $0 + area($1.normalizedBox) }
    }

    private static func area(_ box: NormalizedBox) -> Double {
        max(0, box.xMax - box.xMin) * max(0, box.yMax - box.yMin)
    }

    private static func intersectionArea(_ a: NormalizedBox, _ b: NormalizedBox) -> Double {
        let width = max(0, min(a.xMax, b.xMax) - max(a.xMin, b.xMin))
        let height = max(0, min(a.yMax, b.yMax) - max(a.yMin, b.yMin))
        return width * height
    }

    /// The bounding box of a set of boxes. Internal because the detector needs
    /// the one definition of "the rect a block's members cover" when it turns a
    /// block's tracked line boxes back into block geometry — two unions that
    /// disagreed would put the panel somewhere the text is not.
    static func union(_ boxes: [NormalizedBox]) -> NormalizedBox {
        guard let first = boxes.first else {
            return NormalizedBox(xMin: 0, yMin: 0, xMax: 0, yMax: 0)
        }
        return boxes.dropFirst().reduce(first) { partial, box in
            NormalizedBox(xMin: min(partial.xMin, box.xMin),
                          yMin: min(partial.yMin, box.yMin),
                          xMax: max(partial.xMax, box.xMax),
                          yMax: max(partial.yMax, box.yMax))
        }
    }

    private static func intersect(_ a: NormalizedBox, _ b: NormalizedBox) -> NormalizedBox {
        NormalizedBox(xMin: max(a.xMin, b.xMin),
                      yMin: max(a.yMin, b.yMin),
                      xMax: min(a.xMax, b.xMax),
                      yMax: min(a.yMax, b.yMax))
    }
}
