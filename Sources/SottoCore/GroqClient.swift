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
    public init() {}

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
        case 401: throw SottoError("Key rejected by Groq (HTTP 401). Replace the saved API key.")
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
        let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size > 0, size < 25_000_000 else { throw SottoError("Audio must be nonempty and below 25 MB; original is retained at \(file.path).") }
        guard !key.isEmpty else { throw SottoError("Groq API key is empty.") }
        let boundary = "Sotto-\(UUID().uuidString)"
        // Stream multipart to a temporary file; do not load an entire recording
        // into RAM. Upload file is deleted on success, failure, or cancellation.
        let body = FileManager.default.temporaryDirectory.appendingPathComponent("\(boundary).multipart")
        defer { try? FileManager.default.removeItem(at: body) }
        var fields = [("model", model), ("response_format", "verbose_json"), ("temperature", "0")]
        if let language { fields.append(("language", language)) }
        if !prompt.isEmpty { fields.append(("prompt", prompt)) }
        try Self.writeMultipart(audio: file, destination: body, boundary: boundary, fields: fields)
        var request = URLRequest(url: URL(string: "https://api.groq.com/openai/v1/audio/transcriptions")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        let configuration = URLSessionConfiguration.ephemeral
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
            throw SottoError("Groq HTTP \(response.statusCode): \(detail)")
        }
        struct Response: Decodable { let text: String }
        let decoded = try JSONDecoder().decode(Response.self, from: data)
        let elapsed = start.duration(to: .now).components
        let milliseconds = Int(elapsed.seconds * 1000 + elapsed.attoseconds / 1_000_000_000_000_000)
        return TranscriptionResult(text: decoded.text, rawResponse: data, milliseconds: milliseconds, requestID: response.value(forHTTPHeaderField: "x-request-id")).trimmingWhitespace(trimWhitespace)
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
        while let chunk = try input.read(upToCount: 65536), !chunk.isEmpty { try output.write(contentsOf: chunk) }
        try write("\r\n--\(boundary)--\r\n")
    }
}
