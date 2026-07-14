import XCTest
@testable import groupCam

final class GroupPhotoCompositorTests: XCTestCase {
    func testStaticBackgroundGateAcceptsMostlyMatchingUnmaskedPixels() {
        var difference = [UInt8](repeating: 8, count: 1_200)
        difference.replaceSubrange(
            0..<80,
            with: repeatElement(UInt8(120), count: 80)
        )
        let people = [UInt8](repeating: 0, count: difference.count)
        let valid = [UInt8](repeating: 255, count: difference.count)

        XCTAssertTrue(
            GroupPhotoCompositor.staticBackgroundIsAcceptable(
                difference: difference,
                basePeople: people,
                donorPeople: people,
                validDonor: valid
            )
        )
    }

    func testStaticBackgroundGateRejectsMisregisteredBackground() {
        let difference = [UInt8](repeating: 150, count: 1_200)
        let people = [UInt8](repeating: 0, count: difference.count)
        let valid = [UInt8](repeating: 255, count: difference.count)

        XCTAssertFalse(
            GroupPhotoCompositor.staticBackgroundIsAcceptable(
                difference: difference,
                basePeople: people,
                donorPeople: people,
                validDonor: valid
            )
        )
    }

    func testStaticBackgroundGateRequiresEnoughVisibleBackground() {
        let difference = [UInt8](repeating: 0, count: 12_000)
        var people = [UInt8](repeating: 255, count: difference.count)
        people.replaceSubrange(
            0..<500,
            with: repeatElement(UInt8(0), count: 500)
        )
        let valid = [UInt8](repeating: 255, count: difference.count)

        XCTAssertFalse(
            GroupPhotoCompositor.staticBackgroundIsAcceptable(
                difference: difference,
                basePeople: people,
                donorPeople: people,
                validDonor: valid
            )
        )
    }
}
