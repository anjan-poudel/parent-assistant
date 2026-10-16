import XCTest
@testable import ElderlyAssistant

/// The scene-block rework's core, exercised as what it is: a pure function
/// from (lines, objects) to blocks.
///
/// No camera, no Vision, no detector — because the grouping has none either. A
/// fixture is a handful of literal boxes, which is what lets these tests state
/// the owner's UX verdict as arithmetic: a dense panel resolves to a few large
/// surfaces, side-by-side signs stay apart, an object owns the text inside it,
/// and the same scene groups the same way twice.
final class SceneBlockGrouperTests: XCTestCase {

    // MARK: - Fixtures

    private func box(_ xMin: Double, _ yMin: Double, _ xMax: Double, _ yMax: Double) -> NormalizedBox {
        NormalizedBox(xMin: xMin, yMin: yMin, xMax: xMax, yMax: yMax)
    }

    private func line(_ text: String, _ xMin: Double, _ yMin: Double,
                      _ xMax: Double, _ yMax: Double,
                      confidence: Double = 0.9,
                      language: String? = nil) -> SceneTextLine {
        SceneTextLine(text: text,
                      normalizedBox: box(xMin, yMin, xMax, yMax),
                      confidence: confidence,
                      detectedLanguage: language)
    }

    private func object(_ label: String?, _ xMin: Double, _ yMin: Double,
                        _ xMax: Double, _ yMax: Double,
                        confidence: Double = 0.7) -> SceneObjectBox {
        SceneObjectBox(classLabel: label,
                       normalizedBox: box(xMin, yMin, xMax, yMax),
                       confidence: confidence)
    }

    /// A shop-sign page: eight short lines in one column, stacked the way a
    /// printed menu stacks them. Line pitch is inside the merge distance, so
    /// this is the fixture the owner's "fewer, bigger" is measured on.
    private var menuColumn: [SceneTextLine] {
        let rows = ["MENU", "Tea Rs 40", "Coffee Rs 80", "Momo Rs 120",
                    "Dal Bhat Rs 250", "Cold Drinks", "Water Rs 20", "OPEN 7AM"]
        return rows.enumerated().map { index, text in
            let y = 0.10 + Double(index) * 0.08
            return line(text, 0.20, y, 0.70, y + 0.05)
        }
    }

    // MARK: Scenario: a dense panel resolves to a few large surfaces

    func testADensePanelGroupsItsLinesIntoOneLargeBlock() {
        let blocks = SceneBlockGrouper.group(lines: menuColumn, objects: [], config: .default)

        XCTAssertEqual(blocks.count, 1,
                       "eight lines of one column are one surface, not eight: \(blocks.map(\.memberStrings))")
        XCTAssertEqual(blocks.first?.memberStrings.count, menuColumn.count,
                       "every line is a member of the block that carries it")
        XCTAssertEqual(blocks.first?.kind, .text)

        // The panel's rect is the union of what it holds — the whole column,
        // and no more.
        let panel = blocks.first?.normalizedBox
        XCTAssertEqual(panel?.yMin ?? -1, 0.10, accuracy: 0.0001)
        XCTAssertEqual(panel?.yMax ?? -1, 0.10 + 7 * 0.08 + 0.05, accuracy: 0.0001)
        XCTAssertEqual(panel?.xMin ?? -1, 0.20, accuracy: 0.0001)
        XCTAssertEqual(panel?.xMax ?? -1, 0.70, accuracy: 0.0001)
    }

    func testNoSceneEverExceedsTheVisibleBlockCap() {
        // Three separated panels, each with several lines: more surfaces than
        // the cap allows, so the cap is what decides.
        var lines: [SceneTextLine] = []
        for panel in 0..<3 {
            let x = 0.05 + Double(panel) * 0.31
            for row in 0..<3 {
                let y = 0.10 + Double(row) * 0.06
                lines.append(line("P\(panel) L\(row)", x, y, x + 0.25, y + 0.04))
            }
        }
        let blocks = SceneBlockGrouper.group(lines: lines, objects: [], config: .default)

        XCTAssertLessThanOrEqual(blocks.count, LiveTranslateConfig.default.maxVisibleBlocks)
        XCTAssertEqual(blocks.count, 3, "three columns are three surfaces")
    }

    // MARK: Scenario: what may merge, and what must not

    func testLinesFurtherApartThanTheMergeDistanceStaySeparate() {
        let lines = [line("Top sign", 0.20, 0.05, 0.70, 0.12),
                     line("Bottom sign", 0.20, 0.60, 0.70, 0.67)]
        let blocks = SceneBlockGrouper.group(lines: lines, objects: [], config: .default)

        XCTAssertEqual(blocks.count, 2,
                       "a gap wider than the merge distance is two signs, not one")
    }

    func testTwoSideBySideSignsDoNotBecomeOnePanel() {
        let lines = [line("EXIT", 0.05, 0.40, 0.25, 0.48),
                     line("PUSH", 0.70, 0.40, 0.90, 0.48)]
        let blocks = SceneBlockGrouper.group(lines: lines, objects: [], config: .default)

        XCTAssertEqual(blocks.count, 2,
                       "same row, no shared column: the merge rule is about a column, not a band")
    }

    func testAMergedBlockNeverExceedsTheSanitisationBudget() {
        // Six lines that would blow the per-request text bound if they were
        // all merged into one surface: three fit a request, four do not.
        // Nothing may be truncated on the way to the tier, so the merge stops
        // before the bound instead.
        var config = LiveTranslateConfig.default
        config.sceneTextMaxLength = 40
        let rows = (0..<6).map { index -> SceneTextLine in
            let y = 0.10 + Double(index) * 0.05
            return line("menu line \(index)", 0.10, y, 0.80, y + 0.04)
        }
        let blocks = SceneBlockGrouper.group(lines: rows, objects: [], config: config)

        XCTAssertGreaterThan(blocks.count, 1,
                             "lines that cannot fit one request are not one surface")
        for block in blocks {
            XCTAssertLessThanOrEqual(block.text.count, config.sceneTextMaxLength,
                                     "a block's text is what one request carries: \(block.text)")
        }
        XCTAssertEqual(blocks.flatMap(\.memberStrings).sorted(), rows.map(\.text).sorted(),
                       "splitting for the budget loses no line")
    }

    // MARK: Scenario: an object owns the text inside it

    func testALineInsideAnObjectBecomesThatObjectsBlock() {
        let objects = [object("microwave", 0.10, 0.20, 0.60, 0.70)]
        let lines = [line("START", 0.20, 0.40, 0.40, 0.47),
                     line("2 MIN", 0.20, 0.50, 0.38, 0.57)]
        let blocks = SceneBlockGrouper.group(lines: lines, objects: objects, config: .default)

        XCTAssertEqual(blocks.count, 1)
        XCTAssertEqual(blocks.first?.kind, .object(classLabel: "microwave"))
        XCTAssertEqual(blocks.first?.memberStrings, ["START", "2 MIN"],
                       "the object's text is in reading order")
        XCTAssertEqual(blocks.first?.text, "START\n2 MIN",
                       "one surface is one request: the members joined by the grouper's separator")
    }

    func testTheTightestObjectWinsWhenBoxesNest() {
        // A microwave on a kitchen counter: both boxes contain the line, and
        // the panel is the microwave's, not the room's.
        let objects = [object("kitchen", 0.00, 0.00, 1.00, 1.00),
                       object("microwave", 0.30, 0.30, 0.60, 0.60)]
        let lines = [line("START", 0.35, 0.40, 0.55, 0.47)]
        let blocks = SceneBlockGrouper.group(lines: lines, objects: objects, config: .default)

        XCTAssertEqual(blocks.first?.kind, .object(classLabel: "microwave"))
        // The panel is the object's box clipped to the words on it: the part
        // of the microwave that carries text, never the whole of it.
        XCTAssertEqual(blocks.first?.normalizedBox.yMin ?? -1, 0.40, accuracy: 0.0001)
        XCTAssertEqual(blocks.first?.normalizedBox.yMax ?? -1, 0.47, accuracy: 0.0001)
        XCTAssertEqual(blocks.first?.normalizedBox.xMin ?? -1, 0.35, accuracy: 0.0001)
        XCTAssertEqual(blocks.first?.normalizedBox.xMax ?? -1, 0.55, accuracy: 0.0001)
    }

    func testALineStraddlingAnObjectEdgeStaysATextBlock() {
        // Half the line is on the object, half off it: the honest reading is
        // that the line is text *of the scene*, so it takes the text path.
        let objects = [object("microwave", 0.10, 0.20, 0.40, 0.70)]
        let lines = [line("STRAY", 0.30, 0.40, 0.60, 0.47)]
        let blocks = SceneBlockGrouper.group(lines: lines, objects: objects, config: .default)

        XCTAssertEqual(blocks.count, 1)
        XCTAssertEqual(blocks.first?.kind, .text)
        XCTAssertEqual(blocks.first?.memberStrings, ["STRAY"])
    }

    func testAnObjectWithNoRecognizedTextIsNotASurface() {
        let objects = [object("microwave", 0.10, 0.20, 0.60, 0.70)]
        let lines = [line("MENU", 0.10, 0.80, 0.60, 0.88)]
        let blocks = SceneBlockGrouper.group(lines: lines, objects: objects, config: .default)

        XCTAssertEqual(blocks.map(\.kind), [.text],
                       "a panel with no words in it is a rectangle over the elder's view")
    }

    func testAnObjectHoldingMoreTextThanOneRequestCarriesGoesDownTheTextPath() {
        // An object whose text would be truncated by the sanitiser is not one
        // surface: its lines become text blocks that fit, rather than reaching
        // the tier as one string cut off in the middle.
        var config = LiveTranslateConfig.default
        config.sceneTextMaxLength = 40
        let objects = [object("book", 0.05, 0.05, 0.95, 0.95)]
        let lines = (0..<5).map { index -> SceneTextLine in
            let y = 0.10 + Double(index) * 0.08
            return line("line number \(index) of prose", 0.10, y, 0.80, y + 0.05)
        }
        let blocks = SceneBlockGrouper.group(lines: lines, objects: objects,
                                             config: config, limit: nil)

        for block in blocks {
            XCTAssertLessThanOrEqual(block.text.count, config.sceneTextMaxLength,
                                     "nothing may reach the tier longer than the bound")
        }
        XCTAssertEqual(blocks.flatMap(\.memberStrings).count, lines.count,
                       "the fallback loses no line")
    }

    // MARK: Scenario: the cap keeps what a reader would keep

    func testTheCapKeepsTheBlocksCarryingTheMostText() {
        // Five separated panels, each one shorter than the last; the cap allows
        // four. The one left out is the one carrying the least text.
        var lines: [SceneTextLine] = []
        for panel in 0..<5 {
            let y = 0.02 + Double(panel) * 0.21
            lines.append(line("P\(panel)", 0.10, y, 0.60, y + 0.10 - Double(panel) * 0.015))
        }
        var config = LiveTranslateConfig.default
        config.maxVisibleBlocks = 4
        let blocks = SceneBlockGrouper.group(lines: lines, objects: [], config: config)

        XCTAssertEqual(blocks.count, 4)
        XCTAssertFalse(blocks.flatMap(\.memberStrings).contains("P4"),
                       "the least text is the block the cap leaves out")
        XCTAssertEqual(blocks.flatMap(\.memberStrings), ["P0", "P1", "P2", "P3"],
                       "…and what is kept is still in reading order")
    }

    func testNoLimitMeansEveryBlockIsReturned() {
        var lines: [SceneTextLine] = []
        for panel in 0..<6 {
            let y = 0.01 + Double(panel) * 0.17
            lines.append(line("P\(panel)", 0.10, y, 0.60, y + 0.05))
        }
        let capped = SceneBlockGrouper.group(lines: lines, objects: [], config: .default)
        let all = SceneBlockGrouper.group(lines: lines, objects: [], config: .default, limit: nil)

        XCTAssertEqual(capped.count, LiveTranslateConfig.default.maxVisibleBlocks)
        XCTAssertEqual(all.count, 6,
                       "the still path asks for every block: the snapshot card is the "
                       + "fully-readable mode and has no overlay to crowd")
        XCTAssertTrue(capped.map(\.identityKey).allSatisfy(all.map(\.identityKey).contains),
                      "the cap selects from the same blocks; it does not regroup them")
    }

    // MARK: Scenario: identity survives what the runtime does to a scene

    func testATextBlocksIdentityIsTheSetOfItsMemberStrings() {
        let lines = [line("Beta", 0.20, 0.20, 0.60, 0.28),
                     line("Alpha", 0.20, 0.30, 0.60, 0.38)]
        let reordered = [lines[1], lines[0]]

        XCTAssertEqual(SceneBlockGrouper.textIdentity(of: lines),
                       SceneBlockGrouper.textIdentity(of: reordered),
                       "a reordered pair of lines is the same sign: re-keying it would "
                       + "repaint the panel and re-ask a question already answered")
    }

    /// The owner's device regression, as the grouper's own claim (2026-09-18):
    /// **the object pass cannot re-key the text it grouped.**
    ///
    /// The same three lines under one appliance cluster as two text blocks on
    /// their own — the gap between the first two is wider than the merge
    /// distance — so the object's arrival changes the *grouping* and must not
    /// change the *identity*. When it did, every block the text pass had just
    /// grouped was re-keyed by the next pass's object answer, the stabiliser
    /// never reached its appear hysteresis for any of them, and the overlay
    /// drew nothing over four regions it had just read.
    func testTheObjectPassCannotRekeyTheLinesItGrouped() {
        let lines = [line("PREWASH 40", 0.10, 0.20, 0.50, 0.28),
                     line("RINSE AID", 0.10, 0.50, 0.50, 0.58),
                     line("NO SPIN", 0.10, 0.66, 0.50, 0.74)]
        let appliance = [object("microwave", 0.05, 0.15, 0.55, 0.80)]

        let withObject = SceneBlockGrouper.group(lines: lines, objects: appliance, config: .default)
        let without = SceneBlockGrouper.group(lines: lines, objects: [], config: .default)

        XCTAssertEqual(withObject.count, 1, "the appliance holds all three lines")
        XCTAssertEqual(without.count, 2, "the text geometry keeps the gap: \(without.map(\.text))")

        let panel = withObject[0]
        guard case .object(let label) = panel.kind else {
            return XCTFail("the object's text is an object block: \(panel.kind)")
        }
        XCTAssertEqual(label, "microwave", "the class label is still the block's own: it is "
                       + "grouping evidence, and the placement reads it")
        XCTAssertEqual(panel.identityKey, SceneBlockGrouper.textIdentity(of: panel.lines),
                       "…and it is not identity evidence: the block is the text it holds")

        // Both of the blocks the text pass formed are the panel's own surface.
        for piece in without {
            XCTAssertTrue(
                SceneBlockGrouper.identitiesDescribeTheSameSurface(panel.identityKey,
                                                                    piece.identityKey),
                "\(piece.text) is a piece of the panel, not a second sign")
        }
    }

    /// An object the runtime could not name groups text exactly like one it
    /// could: the class was never the identity.
    func testAnUnnamedObjectGroupsAndIsNamedByItsText() {
        let lines = [line("PREWASH 40", 0.10, 0.20, 0.50, 0.28),
                     line("RINSE AID", 0.10, 0.50, 0.50, 0.58)]
        let held = SceneBlockGrouper.group(lines: lines,
                                           objects: [object(nil, 0.05, 0.15, 0.55, 0.80)],
                                           config: .default)

        XCTAssertEqual(held.count, 1, "an unnamed object is still an object and still groups")
        XCTAssertEqual(held[0].kind, .object(classLabel: nil))
        XCTAssertEqual(held[0].identityKey, SceneBlockGrouper.textIdentity(of: held[0].lines))
    }

    /// The refusal the new relation must keep: two surfaces of *different text*
    /// are two surfaces, whatever the geometry says.
    ///
    /// The refusal the stabiliser applies is the narrower of the two — nothing
    /// in common at all — because that is the only case a block key can be
    /// *sure* of. A key that merely differs must not take away a match the plain
    /// string-and-box rule would have made, or an OCR stumble on one member line
    /// would re-key the panel it belongs to.
    ///
    /// Two relations, kept separate: this one is the pure member-set question,
    /// and the stabiliser gates it on `identityAssertsGrouping` for both keys
    /// before it refuses anything — a pair of one-line keys is not a pair of
    /// conflicting groupings, whatever their sets say.
    func testDifferentTextIsNeverTheSameSurface() {
        let panel = SceneBlockGrouper.textIdentity(of: [line("MENU", 0.30, 0.30, 0.60, 0.36),
                                                        line("Tea Rs 40", 0.30, 0.36, 0.60, 0.42)])
        let beside = SceneBlockGrouper.textIdentity(of: [line("START", 0.30, 0.30, 0.60, 0.60)])
        let elsewhere = SceneBlockGrouper.textIdentity(of: [line("PLAY", 0.70, 0.70, 0.90, 0.76)])
        let misread = SceneBlockGrouper.textIdentity(of: [line("MENU", 0.30, 0.30, 0.60, 0.36),
                                                          line("Tea Rs 4O", 0.30, 0.36, 0.60, 0.42)])

        XCTAssertFalse(SceneBlockGrouper.identitiesDescribeTheSameSurface(panel, beside),
                       "a panel is not the sign beside it: the text decides, not the boxes")
        XCTAssertFalse(SceneBlockGrouper.identitiesDescribeTheSameSurface(beside, elsewhere))
        XCTAssertTrue(SceneBlockGrouper.identitiesDescribeTheSameSurface(panel, panel))

        XCTAssertTrue(SceneBlockGrouper.identitiesAreKnownToBeDifferentSurfaces(panel, beside),
                      "nothing in common is the refusal the stabiliser applies")
        XCTAssertTrue(SceneBlockGrouper.identitiesAreKnownToBeDifferentSurfaces(beside, elsewhere))
        XCTAssertFalse(SceneBlockGrouper.identitiesAreKnownToBeDifferentSurfaces(panel, panel),
                       "a surface is never known to be different from itself")
        XCTAssertFalse(SceneBlockGrouper.identitiesAreKnownToBeDifferentSurfaces(panel, misread),
                       "a panel is not *known different* from itself because one of its lines was "
                       + "misread: the two share MENU, and the box is left to decide")
        XCTAssertFalse(
            SceneBlockGrouper.identitiesAreKnownToBeDifferentSurfaces("a caller's own key", panel),
            "a key that is not one of this type's is not a claim either way")
    }

    /// One line, seen twice: the member set is the identity, so the *set* is
    /// what has to match — a line that was misread is a different set, and the
    /// stabiliser's string and geometry gates are what carry that case.
    func testTheIdentityIsTheMemberSetNotTheReadingOrder() {
        let lines = [line("Beta", 0.20, 0.20, 0.60, 0.28),
                     line("Alpha", 0.20, 0.30, 0.60, 0.38)]
        let panel = SceneBlockGrouper.textIdentity(of: lines)
        let oneMember = SceneBlockGrouper.textIdentity(of: [lines[0]])
        let aDifferentLine = SceneBlockGrouper.textIdentity(of: [line("Beta 2", 0.20, 0.20, 0.60, 0.28)])

        XCTAssertTrue(SceneBlockGrouper.identitiesDescribeTheSameSurface(panel, oneMember),
                      "one of the panel's lines is a piece of the panel")
        XCTAssertFalse(SceneBlockGrouper.identitiesDescribeTheSameSurface(panel, aDifferentLine),
                       "a misread line is not a piece of anything: it is a different string, "
                       + "and the stabiliser's own gates decide that case")
    }

    /// Which keys may make a *grouping* claim at all, pinned where the key
    /// format lives.
    ///
    /// The stabiliser's one subtractive rule is gated on this (owner device
    /// report, 2026-09-18). Two one-line keys whose readings differ are disjoint
    /// keys — one member each, nothing shared — and read as a grouping claim that
    /// meant "two different surfaces", which took the box's own decision away
    /// from a region that had not moved and re-keyed it on every pass. A one-line
    /// key names a reading; only a block that grouped lines is claiming anything
    /// about what belongs with what.
    func testOnlyAKeyWithMoreThanOneMemberLineAssertsAGrouping() {
        let panel = SceneBlockGrouper.textIdentity(of: [line("MENU", 0.30, 0.30, 0.60, 0.36),
                                                        line("Tea Rs 40", 0.30, 0.36, 0.60, 0.42)])
        let oneLine = SceneBlockGrouper.textIdentity(of: [line("START", 0.30, 0.30, 0.60, 0.60)])
        let twoIdenticalLines = SceneBlockGrouper.textIdentity(of: [
            line("START", 0.30, 0.30, 0.60, 0.36), line("START", 0.30, 0.36, 0.60, 0.42)
        ])

        XCTAssertTrue(SceneBlockGrouper.identityAssertsGrouping(panel))
        XCTAssertFalse(SceneBlockGrouper.identityAssertsGrouping(oneLine),
                       "a one-line block's key is a reading with a label on it, not a grouping")
        XCTAssertFalse(SceneBlockGrouper.identityAssertsGrouping(twoIdenticalLines),
                       "the identity is the member *set*: two identical lines are the key of one line")
        XCTAssertFalse(SceneBlockGrouper.identityAssertsGrouping("a caller's own key"),
                       "a key that is not one of this type's groups nothing")
        XCTAssertFalse(SceneBlockGrouper.identityAssertsGrouping("text"),
                       "…and a bare prefix parses to no members at all")
    }

    // MARK: Scenario: the same scene groups the same way, twice

    func testTheGroupingDoesNotDependOnTheOrderTheLinesArrivedIn() {
        let objects = [object("microwave", 0.10, 0.20, 0.60, 0.70)]
        let lines = menuColumn + [line("START", 0.20, 0.30, 0.40, 0.37)]

        let first = SceneBlockGrouper.group(lines: lines, objects: objects, config: .default)
        let second = SceneBlockGrouper.group(lines: lines.reversed(), objects: objects, config: .default)
        let third = SceneBlockGrouper.group(lines: lines.shuffled(), objects: objects.shuffled(),
                                            config: .default)

        XCTAssertEqual(first.map(\.identityKey), second.map(\.identityKey))
        XCTAssertEqual(first.map(\.identityKey), third.map(\.identityKey))
        XCTAssertEqual(first, second)
        XCTAssertEqual(first, third)
    }

    func testBlocksComeOutInReadingOrder() {
        let lines = [line("bottom", 0.20, 0.70, 0.60, 0.78),
                     line("top", 0.20, 0.10, 0.60, 0.18),
                     line("middle", 0.20, 0.40, 0.60, 0.48)]
        let blocks = SceneBlockGrouper.group(lines: lines, objects: [], config: .default)

        XCTAssertEqual(blocks.flatMap(\.memberStrings), ["top", "middle", "bottom"],
                       "the order the stabiliser, the placement and the spoken reading use")
    }

    func testLinesWithNothingToTranslateOrNoGeometryAreDropped() {
        let lines = [line("   ", 0.20, 0.20, 0.60, 0.28),
                     SceneTextLine(text: "zero area",
                                   normalizedBox: box(0.20, 0.40, 0.20, 0.40),
                                   confidence: 0.9,
                                   detectedLanguage: nil),
                     line("real", 0.20, 0.60, 0.60, 0.68)]
        let blocks = SceneBlockGrouper.group(lines: lines, objects: [], config: .default)

        XCTAssertEqual(blocks.flatMap(\.memberStrings), ["real"])
    }

    func testABlocksConfidenceIsItsBestLineAndItsLanguageIsTheFirstReported() {
        let lines = [line("पहिलो", 0.20, 0.20, 0.60, 0.28, confidence: 0.4, language: "ne"),
                     line("second", 0.20, 0.30, 0.60, 0.38, confidence: 0.8, language: "en")]
        let blocks = SceneBlockGrouper.group(lines: lines, objects: [], config: .default)

        XCTAssertEqual(blocks.first?.confidence, 0.8,
                       "a block is credible if its best line is; averaging would let one "
                       + "misread line pull a confident panel under a threshold")
        XCTAssertEqual(blocks.first?.detectedLanguage, "ne",
                       "the block reports the first honest answer its members gave")
    }

    func testAnObjectBlockIsRankedByItsTextAndKeepsItsMembersOrdered() {
        // Two surfaces, one of which is an object. The object's lines are out
        // of order in the input; the block's members are not.
        let objects = [object("television", 0.05, 0.05, 0.45, 0.45)]
        let lines = [line("second", 0.10, 0.30, 0.40, 0.38),
                     line("first", 0.10, 0.10, 0.40, 0.18),
                     line("other sign", 0.60, 0.70, 0.95, 0.78)]
        let blocks = SceneBlockGrouper.group(lines: lines, objects: objects, config: .default)

        let tv = blocks.first { $0.kind == .object(classLabel: "television") }
        XCTAssertEqual(tv?.memberStrings, ["first", "second"])
    }

    // MARK: Scenario: the never-empty rule

    /// The rule the owner's device verdict is about, stated as a property of
    /// the fallback: **one line in, one block out.**
    ///
    /// `group` is total over the lines it can carry, so this is the guard for
    /// what it cannot: a caller whose grouping came back empty for any reason
    /// publishes the lines themselves rather than nothing. The degenerate
    /// grouping is the per-line publication the feature shipped before blocks
    /// existed — same text, same box, the grouper's own text identity — so
    /// nothing downstream can tell that a fallback happened, and the elder
    /// loses the *merge* and not the words.
    func testThePerLineFallbackTurnsEveryUsableLineIntoItsOwnBlock() {
        let lines = [line("START", 0.20, 0.20, 0.60, 0.28),
                     line("2 MIN", 0.20, 0.32, 0.60, 0.40)]

        let blocks = SceneBlockGrouper.perLineBlocks(from: lines, limit: nil)

        XCTAssertEqual(blocks.count, 2,
                       "each line is a block: the fallback is a grouping of one")
        XCTAssertEqual(blocks.flatMap(\.memberStrings), ["START", "2 MIN"])
        XCTAssertEqual(blocks.map(\.normalizedBox), lines.map(\.normalizedBox),
                       "the block's rect is the line's own box: the fallback invents no geometry")
        XCTAssertTrue(blocks.allSatisfy { $0.kind == .text },
                      "a fallback block is a text block — no object was detected for it")
        XCTAssertEqual(blocks.map(\.identityKey),
                       lines.map { SceneBlockGrouper.textIdentity(of: [$0]) },
                       "…and it carries the grouper's own identity for that line, so the "
                       + "stabiliser keys it exactly as it keys any other block")
        XCTAssertEqual(blocks.map(\.text), ["START", "2 MIN"],
                       "the block's text is the line's text: this is what the tier is asked "
                       + "and what the panel draws")
    }

    /// The rule is a *floor*, not a second opinion: it carries exactly the
    /// lines the grouping would carry — the ones with something to translate
    /// and a box that can be geometry — so the two cannot disagree about which
    /// recognized lines a pass publishes.
    func testThePerLineFallbackCarriesExactlyTheLinesTheGroupingWouldCarry() {
        let blank = line("   ", 0.20, 0.20, 0.60, 0.28)
        let degenerate = SceneTextLine(text: "zero area",
                                       normalizedBox: box(0.20, 0.40, 0.20, 0.40),
                                       confidence: 0.9,
                                       detectedLanguage: nil)
        let real = line("real", 0.20, 0.60, 0.60, 0.68)

        let blocks = SceneBlockGrouper.perLineBlocks(from: [blank, degenerate, real], limit: nil)

        XCTAssertEqual(blocks.flatMap(\.memberStrings), ["real"],
                       "a line with nothing to translate or no geometry is not published by "
                       + "the fallback either — the same rule the grouping uses")
        for line in [blank, degenerate, real] {
            XCTAssertEqual(SceneBlockGrouper.isUsable(line),
                           blocks.contains { $0.memberStrings == [line.text] },
                           "'usable' is one definition shared by the grouping and the "
                           + "fallback: \(line.text)")
        }
    }

    /// The cap is the caller's, in the fallback exactly as in the grouping:
    /// the live overlay's few surfaces, and the snapshot card's uncapped list.
    func testThePerLineFallbackRespectsTheCallersCap() {
        let lines = (0..<6).map { index in
            line("L\(index)", 0.20, 0.05 + Double(index) * 0.15, 0.60, 0.12 + Double(index) * 0.15)
        }

        XCTAssertEqual(SceneBlockGrouper.perLineBlocks(from: lines, limit: 4).count, 4,
                       "the live path's cap still bounds the fallback")
        XCTAssertEqual(SceneBlockGrouper.perLineBlocks(from: lines, limit: nil).count, 6,
                       "and the snapshot path is uncapped here too")
    }

    /// Zero lines is the one case where publishing nothing is the honest
    /// answer — the rule is "never empty *over lines it read*", not "never
    /// empty".
    func testThePerLineFallbackPublishesNothingWhenNothingWasRecognized() {
        XCTAssertTrue(SceneBlockGrouper.perLineBlocks(from: [], limit: nil).isEmpty)
    }
}
