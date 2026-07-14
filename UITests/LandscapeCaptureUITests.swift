import XCTest

@MainActor
final class LandscapeCaptureUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testLandscapeLeftCaptureControlsRemainVisibleAndUsable() throws {
        try verifyCaptureLayout(in: .landscapeLeft, keepsScreenshot: true)
    }

    func testLandscapeRightCaptureControlsRemainVisibleAndUsable() throws {
        try verifyCaptureLayout(in: .landscapeRight, keepsScreenshot: false)
    }

    func testPhotoTwoRequiresMatchingOrientationAndLocksFraming() throws {
        let device = XCUIDevice.shared
        device.orientation = .portrait
        defer { device.orientation = .portrait }

        let app = XCUIApplication()
        app.launchArguments = ["-demoSideTwo"]
        app.launchEnvironment["GROUPCAM_UI_TESTING"] = "1"
        app.launchEnvironment["GROUPCAM_LOCKED_ROTATION"] = "0"
        app.launch()

        let shutter = app.buttons["Capture second sequence"]
        XCTAssertTrue(shutter.waitForExistence(timeout: 5))
        XCTAssertTrue(
            app.staticTexts["Rotate back to the same landscape direction as Photo 1."]
                .waitForExistence(timeout: 2)
        )
        XCTAssertFalse(shutter.isEnabled)

        device.orientation = .landscapeLeft
        let window = app.windows.firstMatch
        let matchedOrientation = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in
                window.frame.width > window.frame.height && shutter.isEnabled
            },
            object: nil
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [matchedOrientation], timeout: 5),
            .completed,
            "Photo 2 should unlock only in Photo 1’s orientation"
        )
        XCTAssertFalse(app.buttons["Use 0.5× lens"].isEnabled)
        XCTAssertFalse(app.buttons["Use 1× lens"].isEnabled)
    }

    func testLandscapeProcessingLayoutRemainsReadable() throws {
        let device = XCUIDevice.shared
        device.orientation = .landscapeLeft
        defer { device.orientation = .portrait }

        let app = XCUIApplication()
        app.launchArguments = ["-demoProcessing"]
        app.launchEnvironment["GROUPCAM_UI_TESTING"] = "1"
        app.launch()

        XCTAssertTrue(app.staticTexts["BUILDING YOUR GROUP PHOTO"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Finding everyone’s best frame"].exists)
        XCTAssertTrue(app.buttons["Cancel"].isHittable)
    }

    func testLandscapeReviewShowsPrototypeResultAndActions() throws {
        let device = XCUIDevice.shared
        device.orientation = .landscapeRight
        defer { device.orientation = .portrait }

        let app = XCUIApplication()
        app.launchArguments = ["-demoReview"]
        app.launchEnvironment["GROUPCAM_UI_TESTING"] = "1"
        app.launch()

        XCTAssertTrue(app.staticTexts["PROTOTYPE COMPOSITE"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.images["Combined group photo preview"].exists)
        XCTAssertTrue(app.buttons["Share result"].isHittable)
        XCTAssertTrue(app.buttons["Retake Photo 2"].isHittable)
    }

    private func verifyCaptureLayout(
        in landscapeOrientation: UIDeviceOrientation,
        keepsScreenshot: Bool
    ) throws {
        let device = XCUIDevice.shared
        device.orientation = .portrait
        defer { device.orientation = .portrait }

        let app = XCUIApplication()
        app.launchArguments = ["-demoCapture"]
        app.launchEnvironment["GROUPCAM_UI_TESTING"] = "1"
        app.launch()

        let shutter = app.buttons["Capture first sequence"]
        XCTAssertTrue(shutter.waitForExistence(timeout: 5))

        device.orientation = landscapeOrientation
        let window = app.windows.firstMatch
        let landscapeExpectation = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in
                window.frame.width > window.frame.height
            },
            object: nil
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [landscapeExpectation], timeout: 5),
            .completed,
            "The app window should rotate into landscape before controls are checked"
        )

        XCTAssertTrue(shutter.isHittable)
        let guidance = app.staticTexts["PHOTO 1 OF 2"]
        XCTAssertTrue(guidance.exists)
        XCTAssertTrue(app.staticTexts["3"].exists)
        XCTAssertTrue(app.buttons["Cancel"].isHittable)
        let halfLens = app.buttons["Use 0.5× lens"]
        let wideLens = app.buttons["Use 1× lens"]
        XCTAssertTrue(halfLens.isHittable)
        XCTAssertTrue(wideLens.isHittable)
        XCTAssertEqual(wideLens.value as? String, "1×")
        XCTAssertGreaterThan(
            shutter.frame.midX,
            window.frame.midX,
            "Landscape shutter should be in the right-side control rail"
        )
        XCTAssertLessThan(
            guidance.frame.midX,
            window.frame.midX,
            "Landscape guidance should stay on the left side of the camera preview"
        )

        if keepsScreenshot {
            halfLens.tap()
            let halfLensExpectation = XCTNSPredicateExpectation(
                predicate: NSPredicate { _, _ in
                    halfLens.value as? String == "0.5×" &&
                        wideLens.value as? String == "Available"
                },
                object: nil
            )
            XCTAssertEqual(
                XCTWaiter.wait(for: [halfLensExpectation], timeout: 2),
                .completed,
                "The 0.5× lens should become selected before Photo 1"
            )
            wideLens.tap()
            let wideLensExpectation = XCTNSPredicateExpectation(
                predicate: NSPredicate { _, _ in
                    wideLens.value as? String == "1×"
                },
                object: nil
            )
            XCTAssertEqual(
                XCTWaiter.wait(for: [wideLensExpectation], timeout: 2),
                .completed
            )

            let screenshot = XCTAttachment(screenshot: window.screenshot())
            screenshot.name = "groupCam-landscape-capture"
            screenshot.lifetime = .keepAlways
            add(screenshot)
        }

        device.orientation = .portrait
        let portraitExpectation = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in
                window.frame.height > window.frame.width
            },
            object: nil
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [portraitExpectation], timeout: 5),
            .completed,
            "The capture UI should return to portrait without losing its controls"
        )
        XCTAssertTrue(shutter.isHittable)
    }
}
