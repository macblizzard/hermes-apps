import XCTest

final class HermesMacSmokeTests: XCTestCase {
    private let app = XCUIApplication()

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    override func tearDownWithError() throws {
        // Also preserve the last visible state when an assertion fails.
        screenshot("Final state")
        app.terminate()
    }

    func testLaunchAndDismissPairing() {
        app.launch()
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 20), "Hermes did not open a window")
        XCTAssertTrue(window.isHittable, "Hermes window is not visible")
        screenshot("Launched window")

        // Use the app's own menu shortcut, not coordinates or test-only app code.
        app.typeKey("p", modifierFlags: [.command, .shift])
        let urlField = app.textFields["WebSocket URL"]
        XCTAssertTrue(urlField.waitForExistence(timeout: 10), "Pairing sheet did not open")
        XCTAssertTrue(urlField.isHittable)
        screenshot("Pairing sheet")

        let cancel = app.buttons["Cancel"]
        XCTAssertTrue(cancel.waitForExistence(timeout: 5))
        cancel.click()
        let gone = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: urlField)
        wait(for: [gone], timeout: 10)
        XCTAssertTrue(window.isHittable, "Main window was not restored")
        screenshot("Pairing dismissed")
    }

    private func screenshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
