import XCTest

@MainActor
final class NotesUITests: XCTestCase {
    func testPullToRefreshLoadsExternalChangesWhileRecording() throws {
        continueAfterFailure = false
        let libraryPath = try XCTUnwrap(ProcessInfo.processInfo.environment["SOTTO_TEST_LIBRARY_PATH"], "Run scripts/test-ios.sh with a disposable simulator.")
        XCTAssertTrue(libraryPath.contains("/CoreSimulator/Devices/"))
        let directory = URL(fileURLWithPath: libraryPath, isDirectory: true)
        let metadata = directory.appendingPathComponent("ios-ui-fixture.json")
        let deleted = directory.appendingPathComponent("ios-delete-fixture-a.json")
        let added = directory.appendingPathComponent("ios-refresh-fixture.json")
        let original = try Data(contentsOf: metadata)
        let deletedOriginal = try Data(contentsOf: deleted)
        defer {
            do {
                try original.write(to: metadata, options: .atomic)
                try deletedOriginal.write(to: deleted, options: .atomic)
                try FileManager.default.removeItem(at: added)
            } catch { XCTFail("Could not restore refresh fixtures: \(error)") }
        }
        let app = XCUIApplication(); app.launch()
        let existing = app.buttons["note-ios-ui-fixture"]
        XCTAssertTrue(existing.waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["note-ios-delete-fixture-a"].exists)
        let loaded = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in !app.progressIndicators.firstMatch.exists }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [loaded], timeout: 10), .completed)
        XCTAssertFalse(app.buttons["Try again"].exists)
        app.buttons["record-note"].tap()
        let stop = app.buttons["Stop recording"]
        XCTAssertTrue(stop.waitForExistence(timeout: 10))
        var changed = try XCTUnwrap(JSONSerialization.jsonObject(with: original) as? [String: Any])
        changed["title"] = "Changed on another device"
        try JSONSerialization.data(withJSONObject: changed).write(to: metadata, options: .atomic)
        changed["id"] = "ios-refresh-fixture"
        changed["audioFile"] = "ios-refresh-fixture.m4a"
        changed["title"] = "Added on another device"
        try JSONSerialization.data(withJSONObject: changed).write(to: added, options: .atomic)
        try FileManager.default.removeItem(at: deleted)
        XCTAssertFalse(existing.label.contains("Changed on another device"))
        XCTAssertFalse(app.buttons["note-ios-refresh-fixture"].exists)
        app.collectionViews.firstMatch.swipeDown()
        let refreshed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            existing.label.contains("Changed on another device") && app.buttons["note-ios-refresh-fixture"].exists && !app.buttons["note-ios-delete-fixture-a"].exists
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [refreshed], timeout: 10), .completed)
        XCTAssertTrue(stop.exists, "Refreshing must preserve the current recording")
        XCTAssertFalse(app.buttons["Try again"].exists)
        stop.tap()
        let saved = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Audio saved")).firstMatch
        XCTAssertTrue(saved.waitForExistence(timeout: 10))
        deleteNote(saved, in: app)
    }

    private func deleteNote(_ row: XCUIElement, in app: XCUIApplication) {
        let id = row.identifier
        row.tap()
        app.buttons["Delete note"].tap()
        app.buttons["Delete permanently"].tap()
        XCTAssertFalse(app.buttons[id].exists)
    }

    func testRecordingShortcutStartsAfterColdLaunch() {
        continueAfterFailure = false
        let app = XCUIApplication()
        let shortcuts = XCUIApplication(bundleIdentifier: "com.apple.shortcuts")
        addTeardownBlock {
            await MainActor.run { XCUIApplication().terminate() }
        }
        shortcuts.launch()
        for _ in 0..<3 {
            app.terminate()
            shortcuts.activate()
            let action = shortcuts.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Record a voice note")).firstMatch
            XCTAssertTrue(action.waitForExistence(timeout: 10), shortcuts.debugDescription)
            action.tap()
            XCTAssertTrue(app.wait(for: .runningForeground, timeout: 15), "The shortcut must bring Sotto to the foreground")
            // Attach XCTest to the process launched by Shortcuts before querying its UI.
            app.activate()
            let stop = app.buttons["Stop recording"]
            XCTAssertTrue(stop.waitForExistence(timeout: 15), app.debugDescription)
            let saved = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Audio saved"))
            let count = saved.count
            Thread.sleep(forTimeInterval: 1)
            stop.tap()
            let added = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in saved.count == count + 1 }, object: nil)
            XCTAssertEqual(XCTWaiter.wait(for: [added], timeout: 10), .completed)
            deleteNote(saved.firstMatch, in: app)
        }
    }

    func testUnreadableNoteDoesNotBlockRecording() {
        continueAfterFailure = false
        let app = XCUIApplication(); app.launch()
        let failure = app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] %@", "load earlier notes")).firstMatch
        XCTAssertTrue(failure.waitForExistence(timeout: 10))
        let progress = app.staticTexts.matching(NSPredicate(format: "label MATCHES %@", "[0-9]+ of [0-9]+ notes loaded")).firstMatch
        XCTAssertTrue(progress.exists)
        let initialProgress = progress.label
        let counts = initialProgress.split(separator: " ")
        guard counts.count == 5, let loaded = Int(counts[0]), let total = Int(counts[2]) else {
            XCTFail("Loading failure must show validated and total note counts"); return
        }
        XCTAssertGreaterThanOrEqual(loaded, 3)
        XCTAssertEqual(total, loaded + 1)
        XCTAssertTrue(app.buttons["record-note"].exists)
        XCTAssertTrue(app.buttons["note-ios-ui-fixture"].exists)
        XCTAssertTrue(app.buttons["note-ios-delete-fixture-a"].exists)
        XCTAssertTrue(app.buttons["note-ios-delete-fixture-b"].exists)
        XCTAssertFalse(app.buttons["Choose notes folder"].exists)
        XCTAssertFalse(app.progressIndicators.firstMatch.exists)
        app.buttons["record-note"].tap()
        XCTAssertTrue(app.buttons["Stop recording"].waitForExistence(timeout: 10))
        Thread.sleep(forTimeInterval: 1)
        app.buttons["Stop recording"].tap()
        let saved = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Audio saved")).firstMatch
        XCTAssertTrue(saved.waitForExistence(timeout: 10))
        app.buttons["Try again"].tap()
        XCTAssertTrue(failure.waitForExistence(timeout: 10))
        XCTAssertEqual(progress.label, "\(loaded + 1) of \(total + 1) notes loaded")
        XCTAssertTrue(saved.exists)
        app.buttons["Technical details"].tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "000-unreadable.json")).firstMatch.exists)
        app.buttons["Copy details"].tap()
        XCTAssertTrue(app.buttons["Details copied"].exists)
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Library read failure details"; attachment.lifetime = .keepAlways; add(attachment)
        deleteNote(saved, in: app)
    }

    private func enableLocation(in app: XCUIApplication) {
        app.buttons["Settings"].tap()
        let location = app.switches["Save recording location"]
        XCTAssertTrue(location.waitForExistence(timeout: 5))
        XCTAssertTrue(location.isHittable, "The location switch must be visible before tapping it")
        if location.value as? String == "0" {
            location.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
            let allow = XCUIApplication(bundleIdentifier: "com.apple.springboard").buttons["Allow While Using App"]
            if allow.waitForExistence(timeout: 4) { allow.tap() }
        }
        XCTAssertEqual(location.value as? String, "1", "Location capture must be enabled before testing it")
    }

    func testRecordingLimitPersistsAndStopsAtCapturedDeadline() {
        continueAfterFailure = false
        let app = XCUIApplication(); app.launch()
        func openLimit() -> XCUIElement {
            app.buttons["Settings"].tap()
            let field = app.textFields["Maximum recording duration in minutes"]
            XCTAssertTrue(field.waitForExistence(timeout: 5))
            return field
        }
        func enter(_ value: String, into field: XCUIElement) {
            field.tap()
            field.typeKey("a", modifierFlags: .command)
            field.typeText(value)
            XCTAssertEqual(field.value as? String, value)
            app.buttons["Done"].tap()
        }
        let limit = openLimit()
        if app.buttons["Reset to 3 hours"].isEnabled { app.buttons["Reset to 3 hours"].tap() }
        XCTAssertEqual(limit.value as? String, "180")
        enter("1", into: limit)
        app.terminate(); app.launch()
        XCTAssertEqual(openLimit().value as? String, "1")
        app.buttons["Done"].tap()
        let saved = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Audio saved"))
        let previousID = saved.firstMatch.exists ? saved.firstMatch.identifier : ""
        app.buttons["record-note"].tap()
        XCTAssertTrue(app.buttons["Stop recording"].waitForExistence(timeout: 10))
        _ = openLimit()
        app.buttons["Reset to 3 hours"].tap()
        XCTAssertEqual(limit.value as? String, "180")
        app.buttons["Done"].tap()
        let stopped = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            !app.buttons["Stop recording"].exists && saved.firstMatch.exists && saved.firstMatch.identifier != previousID
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [stopped], timeout: 70), .completed,
                       "Changing Settings must not extend the active recording's one-minute deadline")
        saved.firstMatch.tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label MATCHES %@", "0:59|1:0[0-2]")).firstMatch.waitForExistence(timeout: 5),
                      "The one-minute recording must not gain several seconds of timer tolerance")
        app.terminate(); app.launch()
        XCTAssertEqual(openLimit().value as? String, "180")
        app.buttons["Done"].tap()
        deleteNote(saved.firstMatch, in: app)
    }

    func testLanguageSelectionPersists() {
        continueAfterFailure = false
        let app = XCUIApplication(); app.launch()
        XCTAssertTrue(app.buttons["Settings"].waitForExistence(timeout: 10))
        app.buttons["Settings"].tap()
        app.buttons["language-picker"].tap()
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap(); search.typeText("Japanese")
        XCTAssertTrue(app.buttons["language-ja"].waitForExistence(timeout: 5))
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Language search"; attachment.lifetime = .keepAlways; add(attachment)
        app.buttons["language-ja"].tap()
        app.terminate(); app.launch()
        app.buttons["Settings"].tap()
        app.buttons["language-picker"].tap()
        search.tap(); search.typeText("ja")
        XCTAssertEqual(app.buttons["language-ja"].value as? String, "Selected")
        // Inspect the persisted API code, then restore the default through the same UI.
        app.buttons["language-auto"].tap()
        app.buttons["language-picker"].tap()
        search.tap(); search.typeText("English")
        app.buttons["language-en"].tap()
        app.buttons["Done"].tap()
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

    func testBackToBackRecordingsKeepTheirLocations() {
        continueAfterFailure = false
        let app = XCUIApplication(); app.launch()
        XCTAssertTrue(app.buttons["Settings"].waitForExistence(timeout: 10))
        enableLocation(in: app)
        app.buttons["Done"].tap()
        let saved = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Audio saved"))
        var noteIDs: [String] = []
        for _ in 0..<2 {
            let previousID = saved.firstMatch.exists ? saved.firstMatch.identifier : nil
            app.buttons["record-note"].tap()
            XCTAssertTrue(app.buttons["Stop recording"].waitForExistence(timeout: 15))
            Thread.sleep(forTimeInterval: 1)
            app.buttons["Stop recording"].tap()
            let added = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in saved.firstMatch.exists && saved.firstMatch.identifier != previousID }, object: nil)
            XCTAssertEqual(XCTWaiter.wait(for: [added], timeout: 10), .completed)
            noteIDs.append(saved.firstMatch.identifier)
        }
        XCTAssertEqual(Set(noteIDs).count, 2)
        for id in noteIDs {
            app.buttons[id].tap()
            XCTAssertTrue(app.buttons["recording-location"].waitForExistence(timeout: 10))
            app.navigationBars.buttons["Notes"].tap()
            deleteNote(app.buttons[id], in: app)
        }
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
        XCTAssertTrue(app.staticTexts["Original fixture transcript."].waitForExistence(timeout: 5))
        app.buttons["Edit note"].tap()
        let editor = app.textViews["Note text"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        XCTAssertFalse(app.textFields["Title"].exists)
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
        app.launchArguments = ["--reject-key-check"]
        app.launch()
        XCTAssertTrue(app.buttons["Settings"].waitForExistence(timeout: 10))
        app.buttons["Settings"].tap()
        let key = app.secureTextFields["Groq API key"]
        XCTAssertTrue(key.waitForExistence(timeout: 5), "This test requires a simulator without a saved key")
        key.tap(); key.typeText("sotto-invalid-test-key")
        let save = app.buttons["Save and check key"]
        XCTAssertTrue(save.isEnabled)
        save.tap()
        XCTAssertTrue(app.staticTexts["Key verification rejected by the UI-test fixture."].waitForExistence(timeout: 5))
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Rejected Groq key"; attachment.lifetime = .keepAlways
        add(attachment)
        app.terminate(); app.launch()
        XCTAssertTrue(app.buttons["Settings"].waitForExistence(timeout: 10))
        app.buttons["Settings"].tap()
        XCTAssertTrue(app.secureTextFields["Groq API key"].waitForExistence(timeout: 5))
    }

    func testRecordEditAndRecoverWithoutKey() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launch()
        let record = app.buttons["record-note"]
        XCTAssertTrue(record.waitForExistence(timeout: 10))
        enableLocation(in: app)
        app.buttons["Done"].tap()
        record.tap()
        let stop = app.buttons["Stop recording"]
        XCTAssertTrue(stop.waitForExistence(timeout: 15), "Recording must become responsive")
        let recordingImage = XCTAttachment(screenshot: app.screenshot())
        recordingImage.name = "Recording"; recordingImage.lifetime = .keepAlways
        add(recordingImage)
        // A one-shot location request needs foreground access before backgrounding.
        let recordingRow = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label ENDSWITH %@", "note-", "Recording")).firstMatch
        XCTAssertTrue(recordingRow.waitForExistence(timeout: 5)); recordingRow.tap()
        XCTAssertTrue(app.buttons["Rename note"].isEnabled)
        XCTAssertFalse(app.buttons["Recover note…"].exists)
        XCTAssertTrue(app.buttons["recording-location"].waitForExistence(timeout: 10), "The simulated location must arrive before backgrounding")
        app.navigationBars.buttons["Notes"].tap()
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
        let title = "Test note \(UUID().uuidString.prefix(8))"
        app.buttons["Rename note"].tap()
        app.alerts.textFields["Title"].tap()
        app.alerts.textFields["Title"].typeText(title)
        app.alerts.buttons["Save"].tap()
        app.buttons["Edit note"].tap()
        XCTAssertFalse(app.textFields["Title"].exists)
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
        app.navigationBars.buttons["Notes"].tap()
        deleteNote(restored, in: app)
    }
    func testTranscriptReplacesEditedNoteOnlyAfterConfirmation() {
        continueAfterFailure = false
        let app = XCUIApplication(); app.launch()
        let fixture = app.buttons["note-ios-ui-fixture"]
        XCTAssertTrue(fixture.waitForExistence(timeout: 10)); fixture.tap()
        XCTAssertTrue(app.buttons["Edit note"].waitForExistence(timeout: 5))
        app.buttons["Edit note"].tap()
        let editor = app.textViews["Note text"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5)); editor.tap()
        editor.typeText(" Replacement test edit.")
        app.buttons["Save"].tap()
        app.swipeUp()
        app.buttons["Machine transcript"].tap()
        XCTAssertTrue(app.buttons["Replace note with transcript…"].waitForExistence(timeout: 5))
        app.buttons["Replace note with transcript…"].tap()
        app.buttons["Cancel"].tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Replacement test edit.")).firstMatch.exists)
        app.buttons["Replace note with transcript…"].tap()
        app.buttons["Replace note"].tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label == %@", "Original fixture transcript.")).firstMatch.waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Replacement test edit.")).firstMatch.exists)
        XCTAssertFalse(app.buttons["Replace note with transcript…"].exists)
        app.terminate(); app.launch(); fixture.tap()
        XCTAssertTrue(app.staticTexts["Original fixture transcript."].waitForExistence(timeout: 5))
    }

    func testUnfinishedNoteRequiresExplicitRecovery() {
        continueAfterFailure = false
        let app = XCUIApplication(); app.launch()
        let row = app.buttons["note-ios-recovery-fixture"]
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        XCTAssertTrue(row.label.contains("Unfinished recording"))
        row.tap()
        XCTAssertFalse(app.buttons["Rename note"].isEnabled)
        XCTAssertFalse(app.buttons["Edit note"].isEnabled)
        XCTAssertFalse(app.buttons["Transcribe…"].isEnabled)
        XCTAssertFalse(app.buttons["Delete note"].isEnabled)
        let recover = app.buttons["Recover note…"]
        XCTAssertTrue(recover.isEnabled)
        recover.tap()
        XCTAssertTrue(app.alerts.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Stop it there and let its files sync before recovering")).firstMatch.exists)
        app.alerts.buttons["Cancel"].tap()
        XCTAssertFalse(app.buttons["Delete note"].isEnabled)
        recover.tap()
        app.alerts.buttons["Recover note"].tap()
        XCTAssertTrue(app.buttons["Delete note"].isEnabled)
        XCTAssertTrue(app.buttons["Rename note"].isEnabled)
        XCTAssertTrue(app.buttons["Edit note"].isEnabled)
        XCTAssertTrue(app.buttons["Transcribe…"].isEnabled)
        XCTAssertFalse(recover.exists)
        XCTAssertTrue(app.staticTexts["Retained recovery text."].exists)
        app.terminate(); app.launch()
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        XCTAssertTrue(row.label.contains("Recording interrupted"))
        deleteNote(row, in: app)
    }

    func testUnreadableEditedTextRemainsUntilExplicitReplacement() {
        continueAfterFailure = false
        let app = XCUIApplication(); app.launch()
        let fixture = app.buttons["note-ios-unreadable-text-fixture"]
        XCTAssertTrue(fixture.waitForExistence(timeout: 10)); fixture.tap()
        let error = app.staticTexts["note-text-read-error"]
        XCTAssertTrue(error.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Edit note"].exists)
        XCTAssertFalse(app.staticTexts["No note text yet."].exists)
        app.swipeUp()
        app.buttons["Machine transcript"].tap()
        XCTAssertTrue(app.staticTexts["Recoverable machine transcript."].waitForExistence(timeout: 5))
        let replace = app.buttons["Replace note with transcript…"]
        XCTAssertTrue(replace.waitForExistence(timeout: 5)); replace.tap()
        app.buttons["Cancel"].tap()
        XCTAssertTrue(error.exists)
        app.terminate(); app.launch(); fixture.tap()
        XCTAssertTrue(error.waitForExistence(timeout: 5))
        app.swipeUp()
        app.buttons["Machine transcript"].tap()
        XCTAssertTrue(replace.waitForExistence(timeout: 5)); replace.tap()
        app.buttons["Replace note"].tap()
        app.buttons["Machine transcript"].tap()
        XCTAssertTrue(app.staticTexts["Recoverable machine transcript."].waitForExistence(timeout: 5))
        XCTAssertFalse(error.exists)
        app.terminate(); app.launch(); fixture.tap()
        XCTAssertTrue(app.staticTexts["Recoverable machine transcript."].waitForExistence(timeout: 5))
        XCTAssertFalse(error.exists)
    }

}
