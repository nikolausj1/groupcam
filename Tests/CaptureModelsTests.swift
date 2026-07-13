import XCTest
@testable import groupCam

final class CaptureModelsTests: XCTestCase {
    func testAutoSequenceUsesThreeFrames() {
        XCTAssertEqual(SequenceLength.auto.rawValue, 3)
    }

    func testProvisionalFramePrefersLargestSource() {
        let smaller = makeFrame(width: 1_000, height: 1_000, index: 0)
        let larger = makeFrame(width: 4_000, height: 3_000, index: 1)
        let pair = CapturedPair(
            sessionID: UUID(),
            sideOneFrames: [smaller, larger],
            sideTwoFrames: []
        )

        XCTAssertEqual(pair.provisionalSideOne?.id, larger.id)
    }

    private func makeFrame(width: Int, height: Int, index: Int) -> CapturedFrame {
        CapturedFrame(
            metadata: FrameMetadata(
                id: UUID(),
                side: .one,
                sequenceIndex: index,
                shutterIntentUptime: 1,
                callbackUptime: 2,
                capturedAt: Date(timeIntervalSince1970: 0),
                pixelWidth: width,
                pixelHeight: height,
                lens: .wide,
                motion: nil,
                exposureDurationSeconds: nil,
                iso: nil,
                whiteBalanceRedGain: nil,
                whiteBalanceGreenGain: nil,
                whiteBalanceBlueGain: nil,
                lensPosition: nil,
                captureMetadataPropertyList: nil
            ),
            imageData: Data()
        )
    }
}
