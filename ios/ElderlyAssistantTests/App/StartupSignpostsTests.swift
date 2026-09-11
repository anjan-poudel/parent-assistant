import XCTest
@testable import ElderlyAssistant

/// Guards the startup instrumentation ([BOOT-REVIEW P0 item 1],
/// 2026-09-10). The review asks for SEVEN separate intervals and is
/// explicit that they must not be collapsed into one "startup complete"
/// number — a slow boot has to be attributable to a phase. The name list
/// below is therefore the contract: it is what an Instruments trace is
/// compared against across builds, and it is what a future edit would
/// have to change deliberately (never accidentally by reusing a name).
///
/// The tracker's PAIRING contract is also pinned, independently of
/// whether signposts are emitting in this process
/// (`OSSignposter.isEnabled` is false in an untraced test run — the
/// bookkeeping is deliberately not gated on it, see the tracker's
/// comment).
final class StartupSignpostsTests: XCTestCase {

    private let tracker = StartupSignpostTracker.shared

    override func setUp() {
        super.setUp()
        tracker.reset()
    }

    override func tearDown() {
        tracker.reset()
        super.tearDown()
    }

    // MARK: - The seven metrics, uncollapsed

    func testExactlySevenMetricsAreDeclared() {
        XCTAssertEqual(StartupInterval.allCases.count, 7)
        XCTAssertEqual(Set(StartupSignposts.metricNames).count, 7,
                       "two metrics sharing a name would collapse in the trace")
    }

    func testMetricNamesAreTheReviewedSetInOrder() {
        // Order is the boot's own order; names are stable identifiers for
        // trace comparison, so they are spelled out here verbatim.
        XCTAssertEqual(StartupSignposts.metricNames, [
            "bootstrap-init",
            "first-meaningful-frame",
            "safety-data-restored",
            "voice-pipeline-start-requested",
            "kws-session-ready",
            "voice-pipeline-callback-completed",
            "warm-engines-completed",
        ])
    }

    func testEveryMetricHasItsOwnCase() {
        for interval in StartupInterval.allCases {
            XCTAssertEqual(StartupSignposts.metricNames
                            .filter { $0 == interval.rawValue }.count, 1,
                           "\(interval) is not uniquely named")
        }
    }

    func testSignpostNameMatchesItsBookkeepingKey() {
        // The bookkeeping keys on `rawValue` while the emitted signpost
        // uses `signpostName` (a StaticString). If those drifted, the
        // trace would carry a name no test knows about.
        for interval in StartupInterval.allCases {
            XCTAssertEqual("\(interval.signpostName)", interval.rawValue)
        }
    }

    func testMetricsAreNotMergedIntoTheBootStageNames() {
        // The spinner's stage labels are a DIFFERENT list (`startup.*`
        // catalog keys) — the instrumentation must not be derived from
        // them, or a stage rename would silently rename a metric.
        let stageKeys = Set(StartupBootStage.allCases.map(\.labelKey))
        for name in StartupSignposts.metricNames {
            XCTAssertFalse(stageKeys.contains(name))
        }
        XCTAssertFalse(StartupSignposts.metricNames.contains("startup"),
                       "no catch-all 'startup' metric")
    }

    // MARK: - Pairing contract

    func testBeginThenEndClosesTheInterval() {
        XCTAssertFalse(tracker.isActive(.bootstrapInit))
        tracker.begin(.bootstrapInit)
        XCTAssertTrue(tracker.isActive(.bootstrapInit))
        tracker.end(.bootstrapInit)
        XCTAssertFalse(tracker.isActive(.bootstrapInit))
    }

    func testRepeatedBeginIsANoOp() {
        tracker.begin(.safetyDataRestored)
        tracker.begin(.safetyDataRestored)
        // One end must be enough to close it — a double-begin would leave
        // an interval open forever in the trace.
        tracker.end(.safetyDataRestored)
        XCTAssertFalse(tracker.isActive(.safetyDataRestored))
    }

    func testEndWithoutBeginIsANoOp() {
        tracker.end(.kwsSessionReady)
        XCTAssertFalse(tracker.isActive(.kwsSessionReady))
        // …and the interval is still openable afterwards (an early-return
        // path must not poison the later real one).
        tracker.begin(.kwsSessionReady)
        XCTAssertTrue(tracker.isActive(.kwsSessionReady))
    }

    func testEndTwiceIsANoOp() {
        tracker.begin(.warmEnginesCompleted)
        tracker.end(.warmEnginesCompleted)
        tracker.end(.warmEnginesCompleted)
        XCTAssertFalse(tracker.isActive(.warmEnginesCompleted))
    }

    func testIntervalsAreIndependent() {
        tracker.begin(.bootstrapInit)
        tracker.begin(.firstMeaningfulFrame)
        tracker.end(.bootstrapInit)
        XCTAssertFalse(tracker.isActive(.bootstrapInit))
        XCTAssertTrue(tracker.isActive(.firstMeaningfulFrame),
                      "ending one metric must not close another")
    }

    func testResetClosesEverything() {
        for interval in StartupInterval.allCases { tracker.begin(interval) }
        tracker.reset()
        for interval in StartupInterval.allCases {
            XCTAssertFalse(tracker.isActive(interval))
        }
    }

    func testNotesAndEventsDoNotChangeOpenState() {
        tracker.begin(.voicePipelineStartRequested)
        tracker.event(.voicePipelineStartRequested, "request-issued")
        tracker.end(.voicePipelineStartRequested, note: "request-issued")
        XCTAssertFalse(tracker.isActive(.voicePipelineStartRequested))
        // An event for a closed interval is equally harmless.
        tracker.event(.voicePipelineStartRequested, "late")
    }

    // MARK: - Cross-queue use (the reason the tracker is lock-guarded)

    func testBeginAndEndFromDifferentThreadsCloseTheInterval() {
        // Startup spans the boot queue, main and the voice stack's
        // callback thread — the same interval is begun on one queue and
        // ended on another.
        for interval in StartupInterval.allCases {
            tracker.begin(interval)
            DispatchQueue.global(qos: .userInitiated).sync {
                tracker.end(interval)
            }
            XCTAssertFalse(tracker.isActive(interval),
                           "\(interval) stayed open across queues")
        }
    }

    func testConcurrentBeginsOfDistinctMetricsAllOpen() {
        DispatchQueue.concurrentPerform(
            iterations: StartupInterval.allCases.count
        ) { index in
            tracker.begin(StartupInterval.allCases[index])
        }
        for interval in StartupInterval.allCases {
            XCTAssertTrue(tracker.isActive(interval))
        }
        for interval in StartupInterval.allCases { tracker.end(interval) }
        for interval in StartupInterval.allCases {
            XCTAssertFalse(tracker.isActive(interval))
        }
    }

    func testConcurrentDuplicateBeginsAreCoalesced() {
        DispatchQueue.concurrentPerform(iterations: 32) { _ in
            tracker.begin(.voicePipelineCallbackCompleted)
        }
        tracker.end(.voicePipelineCallbackCompleted)
        XCTAssertFalse(tracker.isActive(.voicePipelineCallbackCompleted))
    }
}
