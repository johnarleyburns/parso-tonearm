import XCTest
@testable import TonearmCore

final class QueueFailureRecoveryPolicyTests: XCTestCase {
    func testMiddleFailureAdvances() {
        XCTAssertEqual(QueueFailureRecoveryPolicy.decide(index: 1, count: 4, repeatMode: .off, autoplay: true, failedAttempts: 1), .advance(to: 2))
    }
    func testFinalFailureStops() {
        XCTAssertEqual(QueueFailureRecoveryPolicy.decide(index: 3, count: 4, repeatMode: .off, autoplay: true, failedAttempts: 2), .stop)
    }
    func testNoAutoplayStops() {
        XCTAssertEqual(QueueFailureRecoveryPolicy.decide(index: 0, count: 4, repeatMode: .off, autoplay: false, failedAttempts: 1), .stop)
    }
    func testRepeatOneDoesNotRecurse() {
        XCTAssertEqual(QueueFailureRecoveryPolicy.decide(index: 0, count: 4, repeatMode: .one, autoplay: true, failedAttempts: 1), .stop)
    }
    func testRepeatAllWrapsButIsBounded() {
        XCTAssertEqual(QueueFailureRecoveryPolicy.decide(index: 3, count: 4, repeatMode: .all, autoplay: true, failedAttempts: 1), .advance(to: 0))
        XCTAssertEqual(QueueFailureRecoveryPolicy.decide(index: 2, count: 4, repeatMode: .all, autoplay: true, failedAttempts: 4), .stop)
    }
}
