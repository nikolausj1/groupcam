import XCTest

#if !targetEnvironment(simulator)
@MainActor
final class PhysicalCameraSmokeUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
    }

    override func tearDownWithError() throws {
        XCUIDevice.shared.orientation = .portrait
    }

    func testLandscapePhotoOneCaptureReachesHandoff() throws {
        let app = XCUIApplication()
        app.launch()

        let consent = app.switches["Everyone in frame agrees to be photographed"]
        XCTAssertTrue(consent.waitForExistence(timeout: 5))
        if consent.value as? String != "1" {
            consent.tap()
        }

        let start = app.buttons["Start a group photo"]
        XCTAssertTrue(start.isHittable)
        start.tap()

        let ready = app.buttons["I’m ready"]
        XCTAssertTrue(ready.waitForExistence(timeout: 15))
        ready.tap()

        let shutter = app.buttons["Capture first sequence"]
        XCTAssertTrue(shutter.waitForExistence(timeout: 5))

        XCUIDevice.shared.orientation = .landscapeLeft
        let landscapeExpectation = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in
                app.windows.firstMatch.frame.width > app.windows.firstMatch.frame.height &&
                    shutter.isHittable
            },
            object: nil
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [landscapeExpectation], timeout: 5),
            .completed
        )

        shutter.tap()
        XCTAssertTrue(
            app.staticTexts["HAND OFF THE PHONE"].waitForExistence(timeout: 20),
            "A real Photo 1 sequence should finish without terminating the app"
        )
    }
}
#endif
