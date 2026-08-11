import XCTest

@MainActor
final class VoicesInViewUITests: XCTestCase {
    private func launchApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "-ui-testing-reset",
            "-AppleLanguages", "(en)",
            "-AppleLocale", "en_US"
        ]
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

    func testCaptionSizeCanBeChangedFromHome() {
        continueAfterFailure = false
        let app = launchApp()
        let size = app.staticTexts["caption-size-value"]
        XCTAssertTrue(size.waitForExistence(timeout: 5))
        XCTAssertEqual(size.label, "36 points")
        app.buttons["Increase caption size"].tap()
        XCTAssertEqual(size.label, "42 points")
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

        app.buttons["Stop"].tap()
        app.buttons["End Session"].tap()
        XCTAssertTrue(startButton.waitForExistence(timeout: 15))
#endif
    }
}
