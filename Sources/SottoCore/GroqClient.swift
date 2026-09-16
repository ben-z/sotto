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
    private let transcriptionEndpoint: URL
    private let uploadConfiguration: URLSessionConfiguration
    public init() {
        transcriptionEndpoint = URL(string: "https://api.groq.com/openai/v1/audio/transcriptions")!
        uploadConfiguration = .ephemeral
    }

    // Internal test seam: production callers always use Groq's HTTPS endpoint.
    init(transcriptionEndpoint: URL, uploadConfiguration: URLSessionConfiguration = .ephemeral) {
        self.transcriptionEndpoint = transcriptionEndpoint
        self.uploadConfiguration = uploadConfiguration
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
        if size >= AudioChunks.maximumUploadBytes {
            return try await transcribeChunks(file: file, key: key, model: model, language: language, prompt: prompt, trimWhitespace: trimWhitespace)
        }
        return try await transcribeUpload(file: file, key: key, model: model, language: language, prompt: prompt).trimmingWhitespace(trimWhitespace)
    }

    private func transcribeChunks(file: URL, key: String, model: String, language: String?, prompt: String, trimWhitespace: Bool) async throws -> TranscriptionResult {
        let start = ContinuousClock.now
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Sotto-chunks-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let chunk = directory.appendingPathComponent("chunk.wav")
        let reader = try AudioChunks(file: file)
        var texts: [String] = []
        var responses: [[String: Any]] = []
        while let range = try reader.next(to: chunk) {
            do {
                let result = try await transcribeUpload(file: chunk, key: key, model: model, language: language, prompt: prompt)
                texts.append(result.text)
                var response: [String: Any] = ["start_seconds": range.startSeconds, "duration_seconds": range.durationSeconds,
                    "response": try JSONSerialization.jsonObject(with: result.rawResponse)]
                if let requestID = result.requestID { response["request_id"] = requestID }
                responses.append(response)
            } catch {
                try Task.checkCancellation()
                throw SottoError("Transcription stopped at part \(responses.count + 1): \(error.localizedDescription) Original audio is retained at \(file.path). Retrying starts from the beginning.")
            }
            try FileManager.default.removeItem(at: chunk)
        }
        try Task.checkCancellation()
        let text = texts.filter { !$0.isEmpty }.joined(separator: "\n")
        // Preserve each unmodified API response and its offset in a Sotto envelope.
        let raw = try JSONSerialization.data(withJSONObject: ["text": text, "chunks": responses], options: [.sortedKeys])
        let elapsed = start.duration(to: .now).components
        let milliseconds = Int(elapsed.seconds * 1000 + elapsed.attoseconds / 1_000_000_000_000_000)
        return TranscriptionResult(text: text, rawResponse: raw, milliseconds: milliseconds, requestID: nil).trimmingWhitespace(trimWhitespace)
    }

    private func transcribeUpload(file: URL, key: String, model: String, language: String?, prompt: String) async throws -> TranscriptionResult {
        try Task.checkCancellation()
        let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size > 0, size < 25_000_000 else { throw SottoError("Audio upload must be nonempty and below Groq’s 25 MB attachment limit.") }
        let boundary = "Sotto-\(UUID().uuidString)"
        // Stream multipart to a temporary file; do not load an entire recording
        // into RAM. Upload file is deleted on success, failure, or cancellation.
        let body = FileManager.default.temporaryDirectory.appendingPathComponent("\(boundary).multipart")
        defer { try? FileManager.default.removeItem(at: body) }
        var fields = [("model", model), ("response_format", "verbose_json"), ("temperature", "0")]
        if let language { fields.append(("language", language)) }
        if !prompt.isEmpty { fields.append(("prompt", prompt)) }
        try Self.writeMultipart(audio: file, destination: body, boundary: boundary, fields: fields)
        var request = URLRequest(url: transcriptionEndpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        let configuration = uploadConfiguration.copy() as! URLSessionConfiguration
        configuration.timeoutIntervalForRequest = 120
        configuration.timeoutIntervalForResource = 180
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let start = ContinuousClock.now
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
        struct Response: Decodable { let text: String }
        let decoded = try JSONDecoder().decode(Response.self, from: data)
        let elapsed = start.duration(to: .now).components
        let milliseconds = Int(elapsed.seconds * 1000 + elapsed.attoseconds / 1_000_000_000_000_000)
        return TranscriptionResult(text: decoded.text, rawResponse: data, milliseconds: milliseconds, requestID: response.value(forHTTPHeaderField: "x-request-id"))
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
        while let chunk = try input.read(upToCount: 65536), !chunk.isEmpty {
            try Task.checkCancellation()
            try output.write(contentsOf: chunk)
        }
        try write("\r\n--\(boundary)--\r\n")
    }
}
