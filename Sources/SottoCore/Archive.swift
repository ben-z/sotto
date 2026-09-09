import Foundation

public struct RecordingRecord: Codable, Sendable {
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
        self.model = model; self.language = language; self.prompt = prompt
        self.contextTerms = contextTerms; self.audioFile = audioFile
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
        record.requestMilliseconds = result.milliseconds
        record.requestID = result.requestID
        try save(record)
    }

    public func recentContext(limit: Int) throws -> [String] {
        guard limit > 0 else { return [] }
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" && !$0.lastPathComponent.hasSuffix(".response.json") }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }.prefix(limit)
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        return try files.flatMap { try decoder.decode(RecordingRecord.self, from: Data(contentsOf: $0)).contextTerms }
    }
}
