import Foundation
import Testing
@testable import SottoCore

@Test func promptBudgetAndPriority() {
    let prompt = Prompt.build(contextTerms: ["Kubernetes", "Groq", "CUDA", "groq", "AVFoundation", String(repeating: "X", count: 500)])
    #expect(prompt == "Kubernetes, Groq, CUDA, AVFoundation")
    #expect(prompt.utf8.count <= 200)
    let unicode = Prompt.build(contextTerms: Array(repeating: "技术词汇", count: 90))
    #expect(unicode.utf8.count <= 200)
}

@Test func contextIsBoundedAndDeduplicated() {
    let terms = Prompt.technicalTerms(from: "Use AVFoundation with CUDA and C++ and snake_case. CUDA is fast. Ordinary prose.")
    #expect(terms == ["AVFoundation", "CUDA", "C++", "snake_case"])
}

@Test func configurationRejectsBrokenPrerequisites() throws {
    var config = Configuration(recordingsDirectory: "relative/path")
    #expect(throws: SottoError.self) { try config.validate() }
    config.recordingsDirectory = "/tmp/sotto"
    config.model = "distil-whisper-large-v3-en"
    #expect(throws: SottoError.self) { try config.validate() }
    config.model = "whisper-large-v3-turbo"
    config.contextHistoryCount = 100
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
    #expect(try archive.recentContext(limit: 1) == ["CUDA"])
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

@Test func malformedHistoryIsNotSilentlyIgnored() throws {
    let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: temp) }
    let archive = try Archive(directory: temp)
    try Data("broken".utf8).write(to: temp.appendingPathComponent("2026-broken.json"))
    #expect(throws: (any Error).self) { try archive.recentContext(limit: 1) }
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
