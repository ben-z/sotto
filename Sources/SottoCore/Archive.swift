import Foundation

public struct RecordingRecord: Codable, Sendable, Identifiable {
    public var title: String?
    public var generatedTitle: String?
    public var timeZoneIdentifier: String?
    public var location: RecordingLocation?
    public var locationStatus: String?
    public var transcribedModel: String?
    public var displayTitle: String {
        if let title, !title.isEmpty { return title }
        return generatedTitle ?? "Voice note"
    }
    static func suggestedTitle(from text: String) -> String? {
        let heading = text.split(whereSeparator: { $0.isWhitespace }).prefix(9).joined(separator: " ")
        return heading.isEmpty ? nil : String(heading.prefix(80))
    }
    public var id: String
    public var startedAt: Date
    public var status: String
    public var model: String
    public var language: String?
    public var prompt: String
    public var contextTerms: [String]
    public var audioFile: String
    public var durationSeconds: Double?
    public var audioBytes: Int?
    public var requestMilliseconds: Int?
    public var requestID: String?
    public var error: String?

    public init(id: String, model: String, language: String?, prompt: String, contextTerms: [String], audioFile: String) {
        self.id = id; startedAt = Date(); status = "recording"
        timeZoneIdentifier = TimeZone.current.identifier
        self.model = model; self.language = language; self.prompt = prompt
        self.contextTerms = contextTerms; self.audioFile = audioFile
    }
}

public struct RecordingLocation: Codable, Sendable {
    public var latitude: Double
    public var longitude: Double
    public var accuracyMeters: Double
    public init(latitude: Double, longitude: Double, accuracyMeters: Double) {
        self.latitude = latitude; self.longitude = longitude; self.accuracyMeters = accuracyMeters
    }
}

public struct Archive: Sendable {
    public let directory: URL

    public init(directory: URL) throws {
        self.directory = directory
        // Never redirect a broken configured destination elsewhere.
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let probe = directory.appendingPathComponent(".sotto-write-test-\(UUID().uuidString)")
        try Data().write(to: probe)
        try FileManager.default.removeItem(at: probe)
    }

    public func newRecord(model: String, language: String?, prompt: String, contextTerms: [String]) throws -> RecordingRecord {
        let date = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let id = "\(date)-\(UUID().uuidString.lowercased())"
        let record = RecordingRecord(id: id, model: model, language: language, prompt: prompt, contextTerms: contextTerms, audioFile: "\(id).m4a")
        try save(record)
        return record
    }

    public func save(_ record: RecordingRecord) throws { try JSONFile.write(record, to: directory.appendingPathComponent("\(record.id).json")) }
    public func audioURL(_ record: RecordingRecord) -> URL { directory.appendingPathComponent(record.audioFile) }

    public func saveResult(_ result: TranscriptionResult, record: RecordingRecord) throws {
        try result.rawResponse.write(to: directory.appendingPathComponent("\(record.id).response.json"), options: .atomic)
        try result.text.write(to: directory.appendingPathComponent("\(record.id).txt"), atomically: true, encoding: .utf8)
    }

    /// Persist outputs before marking the attempt complete or delivering text.
    public func complete(_ record: inout RecordingRecord, with result: TranscriptionResult) throws {
        try saveResult(result, record: record)
        record.status = "complete"
        record.error = nil
        record.transcribedModel = record.model
        record.generatedTitle = RecordingRecord.suggestedTitle(from: result.text)
        record.requestMilliseconds = result.milliseconds
        record.requestID = result.requestID
        try save(record)
    }

}
