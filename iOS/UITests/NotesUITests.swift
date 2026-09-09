import XCTest

@MainActor
final class NotesUITests: XCTestCase {
    private func enableLocation(in app: XCUIApplication) {
        app.buttons["Settings"].tap()
        app.swipeUp()
        let location = app.switches["Save recording location"]
        XCTAssertTrue(location.waitForExistence(timeout: 5))
        if location.value as? String == "0" {
            location.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
            let allow = XCUIApplication(bundleIdentifier: "com.apple.springboard").buttons["Allow While Using App"]
            if allow.waitForExistence(timeout: 4) { allow.tap() }
        }
        XCTAssertEqual(location.value as? String, "1", "Location capture must be enabled before testing it")
    }

    func testLocationOptIn() {
        continueAfterFailure = false
        let app = XCUIApplication(); app.launch()
        XCTAssertTrue(app.buttons["Settings"].waitForExistence(timeout: 10))
        enableLocation(in: app)
        let location = app.switches["Save recording location"]
        location.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
        XCTAssertEqual(location.value as? String, "0")
        app.buttons["Done"].tap()
    }

    func testBatchDeletionAndCancel() {
        continueAfterFailure = false
        let app = XCUIApplication(); app.launch()
        XCTAssertTrue(app.buttons["Select"].waitForExistence(timeout: 10))
        app.buttons["Select"].tap()
        app.buttons["note-ios-delete-fixture-a"].tap()
        app.buttons["note-ios-delete-fixture-b"].tap()
        XCTAssertTrue(app.staticTexts["2 selected"].exists)
        app.buttons["Transcribe…"].tap()
        XCTAssertTrue(app.staticTexts["Transcribe 2 recordings"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Transcribe"].isEnabled)
        app.buttons["Cancel"].tap()
        app.buttons["Delete"].tap()
        app.buttons["Cancel"].tap()
        XCTAssertTrue(app.buttons["note-ios-delete-fixture-a"].exists)
        app.buttons["Delete"].tap()
        app.buttons["Delete permanently"].tap()
        XCTAssertFalse(app.buttons["note-ios-delete-fixture-a"].exists)
        XCTAssertFalse(app.buttons["note-ios-delete-fixture-b"].exists)
        app.terminate(); app.launch()
        XCTAssertTrue(app.buttons["note-ios-ui-fixture"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["note-ios-delete-fixture-a"].exists)
    }

    func testLongPressAndSwipeDeletionCancel() {
        continueAfterFailure = false
        let app = XCUIApplication(); app.launch()
        let fixture = app.buttons["note-ios-ui-fixture"]
        XCTAssertTrue(fixture.waitForExistence(timeout: 10))
        fixture.press(forDuration: 1)
        XCTAssertTrue(app.buttons["Rename"].waitForExistence(timeout: 5))
        app.buttons["Delete"].tap()
        app.buttons["Cancel"].tap()
        XCTAssertTrue(fixture.exists)
        fixture.swipeLeft()
        // A full swipe invokes Delete immediately; a shorter swipe exposes its button.
        if app.buttons["Delete"].exists { app.buttons["Delete"].tap() }
        XCTAssertTrue(app.buttons["Delete permanently"].waitForExistence(timeout: 5))
        app.buttons["Cancel"].tap()
        XCTAssertTrue(fixture.exists)
    }

    func testQuickRenameAndRetranscriptionOptions() {
        continueAfterFailure = false
        let app = XCUIApplication(); app.launch()
        let fixture = app.buttons["note-ios-ui-fixture"]
        XCTAssertTrue(fixture.waitForExistence(timeout: 10)); fixture.tap()
        app.buttons["Rename note"].tap()
        let title = app.alerts.textFields["Title"]
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        title.tap()
        title.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: (title.value as? String ?? "").count))
        title.typeText("Quick title")
        app.alerts.buttons["Save"].tap()
        XCTAssertTrue(app.staticTexts["Quick title"].exists)
        app.swipeUp()
        XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", "whisper-large-v3-turbo", "whisper-large-v3-turbo")).firstMatch.exists)
        app.buttons["Retranscribe…"].tap()
        XCTAssertTrue(app.buttons["Transcribe"].waitForExistence(timeout: 5))
        app.buttons["Cancel"].tap()
        app.swipeDown()
        app.buttons["Rename note"].tap()
        title.tap()
        title.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: "Quick title".count))
        title.typeText("UI test fixture")
        app.alerts.buttons["Save"].tap()
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Note details"; attachment.lifetime = .keepAlways; add(attachment)
    }

    func testEditedNoteSurvivesRelaunch() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launch()
        let fixture = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "UI test fixture")).firstMatch
        XCTAssertTrue(fixture.waitForExistence(timeout: 10), "Run scripts/seed-ios-fixture.py before this test")
        fixture.tap()
        XCTAssertTrue(app.staticTexts["Original fixture transcript."].exists)
        app.buttons["Edit"].tap()
        let editor = app.textViews["Note text"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        editor.tap()
        editor.typeText(" Added locally.")
        app.buttons["Save"].tap()
        app.terminate(); app.launch()
        fixture.tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Added locally.")).firstMatch.waitForExistence(timeout: 5))
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Edited retained note"; attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testKeyOnboarding() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.buttons["Settings"].waitForExistence(timeout: 10))
        app.buttons["Settings"].tap()
        XCTAssertTrue(app.secureTextFields["Groq API key"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Add a Groq API key to transcribe your recordings."].exists)
        XCTAssertFalse(app.buttons["Save and check key"].isEnabled)
        XCTAssertTrue(app.buttons["Create a Groq API key"].exists)
        app.buttons["Done"].tap()
        XCTAssertTrue(app.buttons["record-note"].waitForExistence(timeout: 5))
    }

    func testRejectedKeyIsNotSaved() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.buttons["Settings"].waitForExistence(timeout: 10))
        app.buttons["Settings"].tap()
        let key = app.secureTextFields["Groq API key"]
        XCTAssertTrue(key.waitForExistence(timeout: 5), "This test requires a simulator without a saved key")
        key.tap(); key.typeText("sotto-invalid-test-key")
        let save = app.buttons["Save and check key"]
        XCTAssertTrue(save.isEnabled)
        save.tap()
        XCTAssertTrue(app.staticTexts["Key rejected by Groq (HTTP 401). Check the API key and try again."].waitForExistence(timeout: 25), "The live Groq key check must reject the test key")
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Rejected Groq key"; attachment.lifetime = .keepAlways
        add(attachment)
        app.buttons["Done"].tap()
        app.buttons["Settings"].tap()
        XCTAssertTrue(app.secureTextFields["Groq API key"].waitForExistence(timeout: 5))
    }

    func testRecordEditAndRecoverWithoutKey() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launch()
        let record = app.buttons["record-note"]
        XCTAssertTrue(record.waitForExistence(timeout: 10))
        addUIInterruptionMonitor(withDescription: "Microphone permission") { alert in
            for label in ["Allow While Using App", "Allow"] {
                let allow = alert.buttons[label]
                if allow.exists { allow.tap(); return true }
            }
            return false
        }
        enableLocation(in: app)
        app.buttons["Done"].tap()
        record.tap()
        // Trigger the interruption handler even when the permission alert belongs to SpringBoard.
        app.tap()
        let stop = app.buttons["Stop recording"]
        XCTAssertTrue(stop.waitForExistence(timeout: 15), "Recording must become responsive")
        let recordingImage = XCTAttachment(screenshot: app.screenshot())
        recordingImage.name = "Recording"; recordingImage.lifetime = .keepAlways
        add(recordingImage)
        // The wait gives the encoder enough audio to produce a playable file.
        let saved = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Audio saved")).firstMatch
        XCUIDevice.shared.press(.home)
        Thread.sleep(forTimeInterval: 2)
        app.activate()
        XCTAssertTrue(stop.waitForExistence(timeout: 10), "Recording must survive backgrounding")
        stop.tap()
        XCTAssertTrue(saved.waitForExistence(timeout: 10), "Recording must save without a Groq key")
        saved.tap()
        XCTAssertTrue(app.buttons["recording-location"].waitForExistence(timeout: 10), "The simulated location must be saved with the recording")
        app.buttons["Play recording"].tap()
        let playback = app.buttons["Stop playback"]
        XCTAssertTrue(playback.waitForExistence(timeout: 5), "Saved audio must be playable")
        playback.tap()
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
