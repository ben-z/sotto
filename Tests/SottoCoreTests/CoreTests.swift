import Foundation
import Testing
@testable import SottoCore

@Test func configurationRejectsBrokenPrerequisites() throws {
    var config = Configuration(recordingsDirectory: "relative/path")
    #expect(throws: SottoError.self) { try config.validate() }
    config.recordingsDirectory = "/tmp/sotto"
    config.model = "distil-whisper-large-v3-en"
    #expect(throws: SottoError.self) { try config.validate() }
    config.model = "whisper-large-v3-turbo"
    config.audioBitRate = 1
    #expect(throws: SottoError.self) { try config.validate() }
}

@Test func archiveRetainsAudioAndFailure() throws {
    let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: temp) }
    let archive = try Archive(directory: temp)
    var record = try archive.newRecord(model: "whisper-large-v3-turbo", language: nil, prompt: "CUDA", contextTerms: ["CUDA"])
    let audio = Data([1, 2, 3, 4])
    try audio.write(to: archive.audioURL(record))
    record.status = "failed"; record.error = "HTTP 429"
    try archive.save(record)
    #expect(try Data(contentsOf: archive.audioURL(record)) == audio)
    let json = try String(contentsOf: temp.appendingPathComponent("\(record.id).json"), encoding: .utf8)
    #expect(json.contains("HTTP 429"))
}

@Test func multipartPreservesBinaryAcrossChunks() throws {
    let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: temp) }
    let audio = temp.appendingPathComponent("test.m4a"), body = temp.appendingPathComponent("body")
    let bytes = Data((0..<150000).map { UInt8($0 % 256) })
    try bytes.write(to: audio)
    try GroqClient.writeMultipart(audio: audio, destination: body, boundary: "TEST", fields: [("model", "whisper-large-v3-turbo"), ("prompt", "CUDA")])
    let encoded = try Data(contentsOf: body)
    #expect(encoded.range(of: bytes) != nil)
    #expect(encoded.suffix(12) == Data("\r\n--TEST--\r\n".utf8))
    #expect(String(decoding: encoded.prefix(300), as: UTF8.self).contains("name=\"prompt\"\r\n\r\nCUDA"))
}

@Test func keyCheckDistinguishesRejectedKeyFromServiceProblems() {
    for (status, expected) in [(401, "Key rejected"), (403, "Access denied"), (429, "rate limit"), (503, "could not be confirmed")] {
        do {
            try GroqClient.validateKeyResponse(Data(), statusCode: status, model: "whisper-large-v3-turbo")
            Issue.record("HTTP \(status) was incorrectly accepted")
        } catch { #expect(error.localizedDescription.contains(expected)) }
    }
}

@Test func keyCheckRequiresValidResponseAndSelectedModel() throws {
    let data = Data(#"{"data":[{"id":"whisper-large-v3-turbo"}]}"#.utf8)
    try GroqClient.validateKeyResponse(data, statusCode: 200, model: "whisper-large-v3-turbo")
    #expect(throws: SottoError.self) { try GroqClient.validateKeyResponse(data, statusCode: 200, model: "missing-model") }
    #expect(throws: (any Error).self) { try GroqClient.validateKeyResponse(Data("invalid JSON".utf8), statusCode: 200, model: "whisper-large-v3-turbo") }
}

@Test func whitespaceOptionDefaultsAndRoundTrips() throws {
    let encoder = JSONEncoder(), decoder = JSONDecoder()
    var config = Configuration(recordingsDirectory: "/tmp/sotto")
    var legacy = try JSONSerialization.jsonObject(with: encoder.encode(config)) as! [String: Any]
    legacy.removeValue(forKey: "trimWhitespace")
    #expect(try decoder.decode(Configuration.self, from: JSONSerialization.data(withJSONObject: legacy)).trimWhitespace)
    config.trimWhitespace = false
    #expect(try !decoder.decode(Configuration.self, from: encoder.encode(config)).trimWhitespace)
    legacy["trimWhitespace"] = "false"
    #expect(throws: (any Error).self) { try decoder.decode(Configuration.self, from: JSONSerialization.data(withJSONObject: legacy)) }
}

@Test func whitespaceTrimmingPreservesRawResponseAndInternalFormatting() {
    let text = " \t\nCUDA  and\nGroq.\u{00A0}"
    let raw = Data("raw response".utf8)
    let result = TranscriptionResult(text: text, rawResponse: raw, milliseconds: 42, requestID: "test")
    let trimmed = result.trimmingWhitespace(true)
    #expect(trimmed.text == "CUDA  and\nGroq.")
    #expect(trimmed.rawResponse == raw)
    #expect(trimmed.milliseconds == 42 && trimmed.requestID == "test")
    #expect(result.trimmingWhitespace(false).text == text)
}

@Test func completedArchivePreservesResponseAndDeliveryText() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let archive = try Archive(directory: directory)
    var record = try archive.newRecord(model: "whisper-large-v3-turbo", language: "en", prompt: "", contextTerms: [])
    let raw = Data(#"{"text":"  Hello. "}"#.utf8)
    let result = TranscriptionResult(text: "  Hello. ", rawResponse: raw, milliseconds: 42, requestID: "request")
        .trimmingWhitespace(true)
    try archive.complete(&record, with: result)
    #expect(record.status == "complete")
    #expect(record.requestMilliseconds == 42 && record.requestID == "request")
    #expect(try Data(contentsOf: directory.appendingPathComponent("\(record.id).response.json")) == raw)
    #expect(try String(contentsOf: directory.appendingPathComponent("\(record.id).txt"), encoding: .utf8) == "Hello.")
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let saved = try decoder.decode(RecordingRecord.self, from: Data(contentsOf: directory.appendingPathComponent("\(record.id).json")))
    #expect(saved.status == "complete" && saved.requestID == "request")
}

@Test func failedOutputWriteDoesNotMarkAttemptComplete() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let archive = try Archive(directory: directory)
    var record = try archive.newRecord(model: "whisper-large-v3-turbo", language: nil, prompt: "", contextTerms: [])
    record.status = "transcribing"
    // A directory where the response file should go makes persistence fail reliably.
    try FileManager.default.createDirectory(at: directory.appendingPathComponent("\(record.id).response.json"), withIntermediateDirectories: false)
    let result = TranscriptionResult(text: "Hello", rawResponse: Data(), milliseconds: 1, requestID: nil)
    #expect(throws: (any Error).self) { try archive.complete(&record, with: result) }
    #expect(record.status == "transcribing")
}

@Test func firstLaunchCreatesConfigAndPreservesExistingSettings() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("support/config.json")
    var config = try Configuration.loadOrCreate(from: url, recordingsDirectory: "/tmp/recordings")
    #expect(config.trimWhitespace && config.recordingsDirectory == "/tmp/recordings")
    #expect(config.hotkeyMode == "hold" && config.paste && config.language == "en")
    #expect(try Configuration.load(from: url) == config)
    config.language = "ja"
    config.hotkeyMode = "toggle"
    config.paste = false
    try config.save(to: url)
    #expect(try Configuration.loadOrCreate(from: url, recordingsDirectory: "/tmp/other") == config)
    let broken = Data("broken JSON".utf8)
    try broken.write(to: url)
    #expect(throws: (any Error).self) { try Configuration.loadOrCreate(from: url, recordingsDirectory: "/tmp/other") }
    #expect(try Data(contentsOf: url) == broken)
}

@Test(arguments: [0.0, 3601.0, Double.infinity, Double.nan])
func rejectsInvalidRecordingLimits(_ limit: Double) {
    var config = Configuration(recordingsDirectory: "/tmp/sotto")
    config.maxRecordingSeconds = limit
    #expect(throws: SottoError.self) { try config.validate() }
}

@Test(arguments: ["EN", "eng", "éé", "e1", ""])
func rejectsInvalidLanguageCodes(_ language: String) {
    var config = Configuration(recordingsDirectory: "/tmp/sotto")
    config.language = language
    #expect(throws: SottoError.self) { try config.validate() }
}

@Test func rejectsEmptyAudioBeforeAnyNetworkRequest() async throws {
    let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".m4a")
    defer { try? FileManager.default.removeItem(at: file) }
    try Data().write(to: file)
    do {
        _ = try await GroqClient().transcribe(file: file, key: "test-not-a-credential", model: "whisper-large-v3-turbo", language: "en", prompt: "")
        Issue.record("Empty audio was accepted")
    } catch {
        #expect(error.localizedDescription.contains("Audio must be nonempty"))
    }
    #expect(FileManager.default.fileExists(atPath: file.path))
}

@Test func archiveRejectsFileAsDestination() throws {
    let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: path) }
    try Data("keep me".utf8).write(to: path)
    #expect(throws: (any Error).self) { try Archive(directory: path) }
    #expect(try String(contentsOf: path, encoding: .utf8) == "keep me")
}

@Test func oldContextOptionsAreIgnoredAndNotRewritten() throws {
    var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(Configuration(recordingsDirectory: "/tmp/sotto"))) as! [String: Any]
    json["captureFocusedContext"] = true
    json["contextHistoryCount"] = 10
    let config = try JSONDecoder().decode(Configuration.self, from: JSONSerialization.data(withJSONObject: json))
    let saved = try JSONSerialization.jsonObject(with: JSONEncoder().encode(config)) as! [String: Any]
    #expect(saved["captureFocusedContext"] == nil && saved["contextHistoryCount"] == nil)
}

@Test func updateChecksDefaultOnAndPreserveOptOut() throws {
    let config = Configuration(recordingsDirectory: "/tmp/sotto")
    var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(config)) as? [String: Any])
    object.removeValue(forKey: "automaticUpdateChecks")
    let legacy = try JSONDecoder().decode(Configuration.self, from: JSONSerialization.data(withJSONObject: object))
    #expect(legacy.automaticUpdateChecks)
    var disabled = legacy
    disabled.automaticUpdateChecks = false
    #expect(try !JSONDecoder().decode(Configuration.self, from: JSONEncoder().encode(disabled)).automaticUpdateChecks)
}

@Test func updatesRequireNewerStableVersionAndReadyApp() throws {
    func release(_ tag: String, draft: Bool = false, prerelease: Bool = false, ready: Bool = true) throws -> AppRelease {
        let object: [String: Any] = ["tag_name": tag, "draft": draft, "prerelease": prerelease,
            "assets": ready ? [["name": "Sotto-\(tag.dropFirst())-macOS-universal.zip", "state": "uploaded", "size": 100]] : []]
        return try JSONDecoder().decode(AppRelease.self, from: JSONSerialization.data(withJSONObject: object))
    }
    #expect(try release("v0.1.10").updateURL(currentVersion: "0.1.9")?.absoluteString == "https://github.com/ben-z/sotto/releases/tag/v0.1.10")
    #expect(try release("v0.1.2").updateURL(currentVersion: "0.1.2") == nil)
    #expect(try release("v0.1.2").updateURL(currentVersion: "0.2.0") == nil)
    #expect(try release("v1.0.0", draft: true).updateURL(currentVersion: "0.1.2") == nil)
    #expect(try release("v1.0.0-beta", prerelease: true).updateURL(currentVersion: "0.1.2") == nil)
    #expect(throws: AppRelease.DownloadPending.self) { try release("v1.0.0", ready: false).updateURL(currentVersion: "0.1.2") }
    #expect(throws: SottoError.self) { try release("vgarbage").updateURL(currentVersion: "0.1.2") }
    #expect(throws: SottoError.self) { try release("v1.0.0").updateURL(currentVersion: "Development") }
}
