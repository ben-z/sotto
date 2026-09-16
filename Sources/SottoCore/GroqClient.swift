import Foundation

public struct TranscriptionResult: Sendable {
    public let text: String
    public let rawResponse: Data
    public let milliseconds: Int
    public let requestID: String?

    func trimmingWhitespace(_ enabled: Bool) -> Self {
        Self(text: enabled ? text.trimmingCharacters(in: .whitespacesAndNewlines) : text,
             rawResponse: rawResponse, milliseconds: milliseconds, requestID: requestID)
    }
}

public struct GroqClient: Sendable {
    static let maximumAttachmentBytes = 25_000_000
    private typealias Response = (text: String, rawResponse: Data, requestID: String?)
    private let transcriptionEndpoint: URL
    private let uploadConfiguration: URLSessionConfiguration
    public init() {
        self.init(transcriptionEndpoint: URL(string: "https://api.groq.com/openai/v1/audio/transcriptions")!)
    }

    // Internal test seam: production callers always use Groq's HTTPS endpoint.
    init(transcriptionEndpoint: URL, uploadConfiguration: URLSessionConfiguration = .ephemeral) {
        self.transcriptionEndpoint = transcriptionEndpoint
        self.uploadConfiguration = uploadConfiguration.copy() as! URLSessionConfiguration
        self.uploadConfiguration.timeoutIntervalForRequest = 120
        self.uploadConfiguration.timeoutIntervalForResource = 180
    }

    /// Authenticated, read-only check. This does not prove inference quota or
    /// microphone/transcription operation; the UI states that distinction.
    public func verifyKey(_ key: String, model: String) async throws {
        guard !key.isEmpty else { throw SottoError("No Groq API key is saved.") }
        var request = URLRequest(url: URL(string: "https://api.groq.com/openai/v1/models")!)
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15; config.timeoutIntervalForResource = 20
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw SottoError("Groq returned a non-HTTP response.") }
        try Self.validateKeyResponse(data, statusCode: response.statusCode, model: model)
    }

    static func validateKeyResponse(_ data: Data, statusCode: Int, model: String) throws {
        switch statusCode {
        case 200: break
        case 401: throw SottoError("Key rejected by Groq (HTTP 401). Check the API key and try again.")
        case 403: throw SottoError("Access denied by Groq (HTTP 403). Check project/account permissions.")
        case 429: throw SottoError("Groq rate limit reached (HTTP 429). Try again later; this does not mean the key is invalid.")
        default: throw SottoError("Groq check failed (HTTP \(statusCode)). Key validity could not be confirmed.")
        }
        struct Models: Decodable { struct Model: Decodable { let id: String }; let data: [Model] }
        let models = try JSONDecoder().decode(Models.self, from: data)
        guard models.data.contains(where: { $0.id == model }) else {
            throw SottoError("Key accepted, but \(model) is not listed by Groq.")
        }
    }

    public func transcribe(file: URL, key: String, model: String, language: String?, prompt: String, trimWhitespace: Bool = true) async throws -> TranscriptionResult {
        try Task.checkCancellation()
        let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size > 0 else { throw SottoError("Audio must be nonempty; original is retained at \(file.path).") }
        guard !key.isEmpty else { throw SottoError("Groq API key is empty.") }
        var fields = [("model", model), ("response_format", "verbose_json"), ("temperature", "0")]
        if let language { fields.append(("language", language)) }
        if !prompt.isEmpty { fields.append(("prompt", prompt)) }
        let needsChunks = size >= Self.maximumAttachmentBytes
        if needsChunks { fields.append(("timestamp_granularities[]", "word")) }

        // All parts share one session. Final timing and whitespace handling apply
        // to the complete transcription, regardless of how many uploads it takes.
        let session = URLSession(configuration: uploadConfiguration)
        defer { session.invalidateAndCancel() }
        let start = ContinuousClock.now
        let upload = { (audio: URL) in
            try await transcribeUpload(file: audio, key: key, fields: fields, session: session)
        }
        let response = if needsChunks {
            try await transcribeChunks(file: file, upload: upload)
        } else {
            try await upload(file)
        }
        try Task.checkCancellation()
        let elapsed = start.duration(to: .now).components
        let milliseconds = Int(elapsed.seconds * 1000 + elapsed.attoseconds / 1_000_000_000_000_000)
        return TranscriptionResult(text: response.text, rawResponse: response.rawResponse, milliseconds: milliseconds,
                                   requestID: response.requestID).trimmingWhitespace(trimWhitespace)
    }

    private func transcribeChunks(file: URL, upload: (URL) async throws -> Response) async throws -> Response {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Sotto-chunks-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let chunk = directory.appendingPathComponent("chunk.wav")
        let reader = try AudioChunks(file: file)
        var merger = ChunkTranscriptMerger()
        var completed = 0
        let responseFile = directory.appendingPathComponent("response.json")
        guard FileManager.default.createFile(atPath: responseFile.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw SottoError("Cannot create temporary transcription response.")
        }
        let output = try FileHandle(forWritingTo: responseFile)
        defer { try? output.close() }
        try output.write(contentsOf: Data("{\"chunks\":[".utf8))
        while let range = try reader.next(to: chunk) {
            do {
                let result = try await upload(chunk)
                try autoreleasepool {
                    let transcript = try JSONDecoder().decode(ChunkTranscript.self, from: result.rawResponse)
                    try merger.append(transcript, segment: range)
                    var metadata: [String: Any] = ["start_seconds": range.startSeconds, "duration_seconds": range.durationSeconds]
                    if let requestID = result.requestID { metadata["request_id"] = requestID }
                    if completed > 0 { try output.write(contentsOf: Data(",".utf8)) }
                    let header = try JSONSerialization.data(withJSONObject: metadata, options: [.sortedKeys])
                    try output.write(contentsOf: header.dropLast())
                    try output.write(contentsOf: Data(",\"response\":".utf8))
                    try output.write(contentsOf: result.rawResponse)
                    try output.write(contentsOf: Data("}".utf8))
                }
                completed += 1
            } catch {
                try Task.checkCancellation()
                throw SottoError("Transcription stopped at part \(completed + 1): \(error.localizedDescription) Original audio is retained at \(file.path). Retrying starts from the beginning.")
            }
            try FileManager.default.removeItem(at: chunk)
        }
        let text = try merger.finish()
        try output.write(contentsOf: Data("],\"text\":".utf8))
        try output.write(contentsOf: JSONEncoder().encode(text))
        try output.write(contentsOf: Data("}".utf8))
        try output.close()
        // The mapping stays valid after unlinking the temporary file. Avoid loading
        // the complete envelope or retaining every decoded word dictionary in RAM.
        let raw = try Data(contentsOf: responseFile, options: .alwaysMapped)
        return (text, raw, nil)
    }

    private func transcribeUpload(file: URL, key: String, fields: [(String, String)], session: URLSession) async throws -> Response {
        try Task.checkCancellation()
        let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size > 0, size < Self.maximumAttachmentBytes else { throw SottoError("Audio upload must be nonempty and below Groq’s 25 MB attachment limit.") }
        let boundary = "Sotto-\(UUID().uuidString)"
        // Stream multipart to a temporary file; do not load an entire recording
        // into RAM. Upload file is deleted on success, failure, or cancellation.
        let body = FileManager.default.temporaryDirectory.appendingPathComponent("\(boundary).multipart")
        defer { try? FileManager.default.removeItem(at: body) }
        try Self.writeMultipart(audio: file, destination: body, boundary: boundary, fields: fields)
        var request = URLRequest(url: transcriptionEndpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        let (data, response) = try await session.upload(for: request, fromFile: body)
        guard let response = response as? HTTPURLResponse else { throw SottoError("Groq returned a non-HTTP response.") }
        guard response.statusCode == 200 else {
            let detail = String(decoding: data.prefix(2000), as: UTF8.self)
                .replacingOccurrences(of: key, with: "[redacted]")
            if response.statusCode == 429 {
                throw SottoError("Groq rate limit reached (HTTP 429). Audio-hour/day quotas apply even to split recordings. Wait for your quota to reset or check your plan at console.groq.com/settings/limits. \(detail)")
            }
            throw SottoError("Groq HTTP \(response.statusCode): \(detail)")
        }
        struct Payload: Decodable { let text: String }
        let decoded = try autoreleasepool { try JSONDecoder().decode(Payload.self, from: data) }
        return (decoded.text, data, response.value(forHTTPHeaderField: "x-request-id"))
    }

    static func writeMultipart(audio: URL, destination: URL, boundary: String, fields: [(String, String)]) throws {
        guard FileManager.default.createFile(atPath: destination.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw SottoError("Cannot create temporary upload at \(destination.path).")
        }
        let output = try FileHandle(forWritingTo: destination)
        defer { try? output.close() }
        func write(_ text: String) throws { try output.write(contentsOf: Data(text.utf8)) }
        for (name, value) in fields {
            try write("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n")
        }
        // Fixed filename avoids header injection from a user-selected path.
        let ext = audio.pathExtension.lowercased()
        let mime = ext == "wav" ? "audio/wav" : ext == "mp3" ? "audio/mpeg" : "audio/mp4"
        try write("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"recording.\(ext)\"\r\nContent-Type: \(mime)\r\n\r\n")
        let input = try FileHandle(forReadingFrom: audio)
        defer { try? input.close() }
        // Release Foundation's temporary buffers after each block, before an
        // entire upload's worth can accumulate on a Swift concurrency thread.
        while try autoreleasepool(invoking: {
            try Task.checkCancellation()
            guard let chunk = try input.read(upToCount: 65536), !chunk.isEmpty else { return false }
            try output.write(contentsOf: chunk)
            return true
        }) { }
        try write("\r\n--\(boundary)--\r\n")
    }
}
