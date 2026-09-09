import XCTest

@MainActor
final class NotesUITests: XCTestCase {
    func testRecordEditAndRecoverWithoutKey() throws {
        let app = XCUIApplication()
        app.launch()
        let record = app.buttons["record-note"]
        XCTAssertTrue(record.waitForExistence(timeout: 10))
        addUIInterruptionMonitor(withDescription: "Microphone permission") { alert in
            let allow = alert.buttons["Allow"]
            if allow.exists { allow.tap(); return true }
            return false
        }
        record.tap()
        if app.alerts.firstMatch.waitForExistence(timeout: 2) { app.tap() }
        let stop = app.buttons["Stop recording"]
        XCTAssertTrue(stop.waitForExistence(timeout: 15), "Recording must become responsive")
        // The wait gives the encoder enough audio to produce a playable file.
        let saved = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Audio saved")).firstMatch
        XCUIDevice.shared.press(.home)
        Thread.sleep(forTimeInterval: 2)
        app.activate()
        XCTAssertTrue(stop.waitForExistence(timeout: 10), "Recording must survive backgrounding")
        stop.tap()
        XCTAssertTrue(saved.waitForExistence(timeout: 10), "Recording must save without a Groq key")
        saved.tap()
        app.buttons["Edit"].tap()
        let title = "Test note \(UUID().uuidString.prefix(8))"
        app.textFields["Title"].tap()
        app.textFields["Title"].typeText(title)
        app.textViews["Note text"].tap()
        app.textViews["Note text"].typeText("An editable local note.")
        app.buttons["Save"].tap()
        XCTAssertTrue(app.staticTexts["An editable local note."].waitForExistence(timeout: 5))
        app.terminate()
        app.launch()
        let restored = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", title)).firstMatch
        XCTAssertTrue(restored.waitForExistence(timeout: 10))
        restored.tap()
        XCTAssertTrue(app.staticTexts["An editable local note."].exists)
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Retained voice note"; attachment.lifetime = .keepAlways
        add(attachment)
    }
}
