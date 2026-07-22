import XCTest
@testable import LivePaperCore

final class PlaybackTuningTests: XCTestCase {
    func testHighFpsClipCapsToDisplay() {
        XCTAssertEqual(PlaybackTuning.frameRateCapTarget(sourceFPS: 120, screenMaxFPS: 60), 60)
    }

    func testNormalFpsClipGetsNoCap() {
        XCTAssertNil(PlaybackTuning.frameRateCapTarget(sourceFPS: 60, screenMaxFPS: 60))
        XCTAssertNil(PlaybackTuning.frameRateCapTarget(sourceFPS: 30, screenMaxFPS: 60))
        XCTAssertNil(PlaybackTuning.frameRateCapTarget(sourceFPS: 23.976, screenMaxFPS: 60))
    }

    func testCapNeverExceeds60EvenOnProMotion() {
        // 120Hz ProMotion display, 120fps clip → still capped at 60.
        XCTAssertEqual(PlaybackTuning.frameRateCapTarget(sourceFPS: 120, screenMaxFPS: 120), 60)
        XCTAssertEqual(PlaybackTuning.frameRateCapTarget(sourceFPS: 240, screenMaxFPS: 120), 60)
    }

    func testUnknownRefreshFallsBackTo60() {
        XCTAssertEqual(PlaybackTuning.frameRateCapTarget(sourceFPS: 120, screenMaxFPS: 0), 60)
        XCTAssertNil(PlaybackTuning.frameRateCapTarget(sourceFPS: 60, screenMaxFPS: 0))
    }

    func testOneFpsGuardAvoidsPointlessCap() {
        // Just above target triggers; within 1fps does not.
        XCTAssertNil(PlaybackTuning.frameRateCapTarget(sourceFPS: 61, screenMaxFPS: 60))
        XCTAssertEqual(PlaybackTuning.frameRateCapTarget(sourceFPS: 62, screenMaxFPS: 60), 60)
    }
}
