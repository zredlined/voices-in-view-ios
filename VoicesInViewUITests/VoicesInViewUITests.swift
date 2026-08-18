import XCTest

@MainActor
final class VoicesInViewUITests: XCTestCase {
    private func launchApp(additionalArguments: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "-ui-testing-reset",
            "-AppleLanguages", "(en)",
            "-AppleLocale", "en_US"
        ]
        app.launchArguments.append(contentsOf: additionalArguments)
        app.launch()
        return app
    }

    func testHomeScreenExposesThePrimaryCaptionFlow() {
        continueAfterFailure = false
        let app = launchApp()
        XCTAssertTrue(app.navigationBars["Voices in View"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Start Captions"].exists)
        XCTAssertTrue(app.buttons["Ghost Mode, not saved"].exists)
        XCTAssertTrue(app.buttons["Saved mode"].exists)
        XCTAssertTrue(app.buttons["Check Mic Levels"].exists)
        XCTAssertTrue(app.buttons["saved-transcripts"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["capture-profile-picker"].exists)
        XCTAssertTrue(app.buttons["iPhone"].exists)
        XCTAssertTrue(app.buttons["USB"].exists)
        XCTAssertTrue(app.buttons["AirPods"].exists)
    }

    func testAirPodsProfileDoesNotGateCaptionStart() {
        continueAfterFailure = false
        let app = launchApp()
        let farField = app.buttons["AirPods"]
        XCTAssertTrue(farField.waitForExistence(timeout: 5))

        farField.tap()

        XCTAssertFalse(app.buttons["AirPods HQ"].exists)
        XCTAssertTrue(app.buttons["Start Captions"].isEnabled)
    }

    func testGhostModeIsTheDefault() {
        continueAfterFailure = false
        let app = launchApp()
        let ghostMode = app.buttons["Ghost Mode, not saved"]
        XCTAssertTrue(ghostMode.waitForExistence(timeout: 5))
        XCTAssertTrue(ghostMode.isSelected)

        let savedMode = app.buttons["Saved mode"]
        savedMode.tap()
        XCTAssertTrue(savedMode.isSelected)
    }

    func testMicrophoneCheckCanStartAndStop() {
        continueAfterFailure = false
        let app = launchApp()
        let startButton = app.buttons["Check Mic Levels"]
        XCTAssertTrue(startButton.waitForExistence(timeout: 5))

        startButton.tap()

        let stopButton = app.buttons["Stop Mic Check"]
        XCTAssertTrue(stopButton.waitForExistence(timeout: 5))
        XCTAssertEqual(app.state, .runningForeground)

        stopButton.tap()
        XCTAssertTrue(startButton.waitForExistence(timeout: 5))
        XCTAssertEqual(app.state, .runningForeground)
    }

    func testLiveTranscriptCanBrowseHistoryAndJumpBackToCurrentCaption() {
        continueAfterFailure = false
        let app = launchApp(additionalArguments: ["-screenshot-fixture", "live"])
        let currentCaption = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS %@", "Keep talking")
        ).firstMatch

        XCTAssertTrue(currentCaption.waitForExistence(timeout: 5))
        XCTAssertTrue(currentCaption.isHittable)

        app.swipeDown()

        let jumpToLive = app.buttons["Jump to Live"]
        XCTAssertTrue(jumpToLive.waitForExistence(timeout: 5))
        jumpToLive.tap()
        XCTAssertTrue(currentCaption.waitForExistence(timeout: 5))
        XCTAssertTrue(currentCaption.isHittable)
    }

    func testPhysicalDeviceCanBeginAndEndCaptionSession() throws {
#if targetEnvironment(simulator)
        throw XCTSkip("The on-device SpeechTranscriber model is not available in Simulator.")
#else
        continueAfterFailure = false
        let app = launchApp()
        let startButton = app.buttons["Start Captions"]
        XCTAssertTrue(startButton.waitForExistence(timeout: 5))

        startButton.tap()

        XCTAssertTrue(app.staticTexts["Listening…"].waitForExistence(timeout: 60))
        XCTAssertFalse(app.alerts["Voices in View"].waitForExistence(timeout: 3))
        XCTAssertEqual(app.state, .runningForeground)

        let size = app.staticTexts["caption-size-value"]
        XCTAssertTrue(size.exists)
        let originalSize = size.label
        app.buttons["Increase caption size"].tap()
        XCTAssertNotEqual(size.label, originalSize)

        app.buttons["Stop"].tap()
        XCTAssertTrue(startButton.waitForExistence(timeout: 15))
#endif
    }
}
