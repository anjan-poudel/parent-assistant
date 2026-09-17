import Foundation

/// `Result` is not `Equatable` when its `Success` is not (and `Void` never is),
/// so the feature's tests read outcomes through these two accessors instead of
/// `XCTAssertEqual(_:_:)`. Both are total: `failureError` answers `nil` for a
/// success and `isSuccess` answers `false` for a failure, so a test that
/// asserts the wrong half fails rather than compiling into a tautology.
extension Result {

    var isSuccess: Bool {
        if case .success = self { return true }
        return false
    }

    var failureError: Failure? {
        if case .failure(let error) = self { return error }
        return nil
    }
}
