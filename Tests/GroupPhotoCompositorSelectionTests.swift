import XCTest
@testable import groupCam

final class GroupPhotoCompositorSelectionTests: XCTestCase {
    func testCompleteFaceSetRanksAheadOfHigherQualityPartialSet() {
        let complete = quality(faces: 4, scored: 4, minimum: 0.4, average: 0.6, index: 1)
        let partial = quality(faces: 4, scored: 3, minimum: 0.9, average: 0.95, index: 0)

        XCTAssertFalse(
            GroupPhotoCompositor.frameQualityIsWorse(
                complete,
                than: partial,
                maximumDetectedFaceCount: 4
            )
        )
        XCTAssertTrue(
            GroupPhotoCompositor.frameQualityIsWorse(
                partial,
                than: complete,
                maximumDetectedFaceCount: 4
            )
        )
    }

    func testFrameMissingAFaceRanksBehindCompleteSet() {
        let complete = quality(faces: 4, scored: 4, minimum: 0.3, average: 0.5, index: 1)
        let missingFace = quality(faces: 3, scored: 3, minimum: 0.95, average: 0.97, index: 0)

        XCTAssertTrue(
            GroupPhotoCompositor.frameQualityIsWorse(
                missingFace,
                than: complete,
                maximumDetectedFaceCount: 4
            )
        )
    }

    func testThreeFrameBurstAttemptsBalancedPairsInBoundedOrder() {
        let pairs = GroupPhotoCompositor.rankedPairIndices(
            sideOneCount: 3,
            sideTwoCount: 3
        ).map { "\($0.0),\($0.1)" }

        XCTAssertEqual(
            pairs,
            ["0,0", "0,1", "1,0", "1,1", "0,2", "2,0", "1,2", "2,1", "2,2"]
        )
    }

    func testPairAttemptsAreCapped() {
        XCTAssertEqual(
            GroupPhotoCompositor.rankedPairIndices(
                sideOneCount: 5,
                sideTwoCount: 5
            ).count,
            9
        )
    }

    private func quality(
        faces: Int,
        scored: Int,
        minimum: Float,
        average: Float,
        index: Int
    ) -> GroupPhotoCompositor.FrameQualitySummary {
        GroupPhotoCompositor.FrameQualitySummary(
            detectedFaceCount: faces,
            scoredFaceCount: scored,
            minimumFaceQuality: minimum,
            averageFaceQuality: average,
            sequenceIndex: index
        )
    }
}
