import XCTest
@testable import RemoteInputCore

final class RemoteInputCoreTests: XCTestCase {
    func testMirroredInterfacesDoNotDuplicateLogicalEdges() {
        var state = MultiRemoteButtonState<String, String>()
        XCTAssertEqual(state.update(source: "A", button: "menu", pressed: true), .globalDown)
        XCTAssertEqual(state.update(source: "A", button: "menu", pressed: true), .duplicate)
        XCTAssertEqual(state.update(source: "B", button: "menu", pressed: true), .sourceOnly)
        XCTAssertEqual(state.update(source: "A", button: "menu", pressed: false), .sourceOnly)
        XCTAssertTrue(state.isPressed("menu"))
        XCTAssertEqual(state.update(source: "B", button: "menu", pressed: false), .globalUp)
    }

    func testDisconnectReleasesOnlyButtonsNoOtherRemoteOwns() {
        var state = MultiRemoteButtonState<String, String>()
        _ = state.update(source: "A", button: "menu", pressed: true)
        _ = state.update(source: "A", button: "siri", pressed: true)
        _ = state.update(source: "B", button: "menu", pressed: true)
        XCTAssertEqual(state.removeSource("A"), Set(["siri"]))
        XCTAssertTrue(state.isPressed("menu"))
    }

    func testVoiceChordOwnsBothReleasesAndReset() {
        var state = VoiceModeChordState()
        XCTAssertEqual(state.route(buttonName: "siri", pressed: true,
                                   muteIsDown: true, enabled: true), .cycle)
        XCTAssertEqual(state.route(buttonName: "siri", pressed: false,
                                   muteIsDown: true, enabled: true), .consume)
        XCTAssertEqual(state.route(buttonName: "mute", pressed: false,
                                   muteIsDown: false, enabled: true), .consume)
        state.reset()
        XCTAssertEqual(state.route(buttonName: "siri", pressed: false,
                                   muteIsDown: false, enabled: true), .passthrough)
    }

    func testHoldSelectionUsesCapturedMonotonicBoundaries() {
        let hold = RemoteHoldGesture(
            startedAt: 10,
            stages: [
                .init(key: "hold", delay: 0.5, ordinal: 1),
                .init(key: "hold2", delay: 1.0, ordinal: 2),
            ],
            cancelAt: 2.0
        )
        XCTAssertEqual(hold.selection(at: 10.499), .tap)
        XCTAssertEqual(hold.selection(at: 10.5), .stage(index: 0))
        XCTAssertEqual(hold.selection(at: 11.0), .stage(index: 1))
        XCTAssertEqual(hold.selection(at: 12.0), .cancel)
    }

    func testTapRunsAdvanceAndResolveIndependently() {
        var taps = RemoteTapRunState<String>()
        XCTAssertEqual(taps.advance("menu"), 1)
        XCTAssertEqual(taps.advance("menu"), 2)
        XCTAssertEqual(taps.advance("siri"), 1)
        XCTAssertEqual(taps.removeValue(forKey: "menu"), 2)
        XCTAssertNil(taps["menu"])
        XCTAssertEqual(taps["siri"], 1)
    }

    func testLayerAndRepeatOwnershipArePureState() {
        var layer = RemoteLayerState<String>()
        layer.engage(button: "tv", gesture: .direct("L1"))
        layer.markUsed()
        XCTAssertEqual(layer.button, "tv")
        XCTAssertEqual(layer.gesture?.target, "L1")
        XCTAssertTrue(layer.used)
        layer.stickyLayer = "L1"
        layer.stickyButton = "tv"
        layer.resetMomentary()
        XCTAssertNil(layer.button)
        XCTAssertEqual(layer.stickyLayer, "L1")

        var repeatState = RemoteRepeatEngagementState<String>()
        XCTAssertTrue(repeatState.insert("menu").inserted)
        XCTAssertTrue(repeatState.contains("menu"))
        XCTAssertEqual(repeatState.remove("menu"), "menu")
        XCTAssertFalse(repeatState.contains("menu"))
    }
}
