import XCTest

@MainActor
final class HoldCountdownTests: XCTestCase {
    /// No real waiting in tests: each "second" just lets the countdown move on.
    private func makeHold() -> HoldCountdown {
        HoldCountdown(seconds: 3, sleep: { _ in await Task.yield() })
    }

    func testHoldingAllTheWayEndsOnce() async {
        let hold = makeHold()
        var ended = 0
        hold.onComplete = { ended += 1 }
        hold.press()
        XCTAssertEqual(hold.remaining, 3, "the countdown starts at 3 the moment you press")
        await hold.settle()
        XCTAssertEqual(ended, 1)
        XCTAssertEqual(hold.completions, 1)
        XCTAssertNil(hold.remaining)
        XCTAssertFalse(hold.isHolding)
    }

    func testLettingGoEarlyEndsNothing() async {
        let hold = makeHold()
        var ended = 0
        hold.onComplete = { ended += 1 }
        hold.press()
        hold.release()
        await hold.settle()
        XCTAssertEqual(ended, 0)
        XCTAssertNil(hold.remaining)
    }

    func testPressingAgainWhileHeldDoesNotRestart() async {
        let hold = makeHold()
        var ended = 0
        hold.onComplete = { ended += 1 }
        hold.press()
        hold.press()
        await hold.settle()
        XCTAssertEqual(ended, 1, "one hold ends the session once")
    }

    func testCanHoldAgainAfterLettingGo() async {
        let hold = makeHold()
        var ended = 0
        hold.onComplete = { ended += 1 }
        hold.press()
        hold.release()
        hold.press()
        await hold.settle()
        XCTAssertEqual(ended, 1)
    }
}
