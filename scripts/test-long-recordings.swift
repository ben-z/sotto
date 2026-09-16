import AVFoundation
import Foundation

// Compiled with the production core sources; no microphone, key, or network.
private final class UploadFixture: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var requests = 0
    nonisolated(unsafe) private static var failingRequest: Int?
    nonisolated(unsafe) private static var blockedRequest: Int?
    nonisolated(unsafe) private static var payloads: [String] = []
    static func reset(failingRequest: Int? = nil, blockedRequest: Int? = nil, payloads: [String] = []) {
        lock.withLock {
            requests = 0; self.failingRequest = failingRequest; self.blockedRequest = blockedRequest
            self.payloads = payloads
        }
    }
    static var count: Int { lock.withLock { requests } }
    static func payload(_ index: Int) -> String {
        if let custom = lock.withLock({ index <= payloads.count ? payloads[index - 1] : nil }) { return custom }
        return """
        {"text":" Part \(index). ","words":[{"word":"Part","start":10,"end":10.5},{"word":"\(index).","start":10.5,"end":11}]}
        """
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let (index, failing, blocked) = Self.lock.withLock {
            Self.requests += 1
            return (Self.requests, Self.requests == Self.failingRequest, Self.requests == Self.blockedRequest)
        }
        if blocked { return } // URLSession must cancel this pending upload.
        let response = HTTPURLResponse(url: request.url!, statusCode: failing ? 429 : 200,
            httpVersion: "HTTP/1.1", headerFields: ["x-request-id": "part-\(index)"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data((failing ? "quota fixture-key" : Self.payload(index)).utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { }
}

@main struct LongRecordingTests {
    static func expect(_ condition: Bool, _ message: String) throws {
        guard condition else { throw SottoError(message) }
    }

    static func temporaryUploads() throws -> Set<String> {
        Set(try FileManager.default.contentsOfDirectory(atPath: FileManager.default.temporaryDirectory.path)
            .filter { $0.hasPrefix("Sotto-chunks-") || ($0.hasPrefix("Sotto-") && $0.hasSuffix(".multipart")) })
    }

    static func writeAudio(to url: URL, seconds: Int) throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)!
        let file = try AVAudioFile(forWriting: url, settings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16000,
            AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false
        ])
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16000)!
        buffer.frameLength = 16000
        for second in 0..<seconds {
            // Distinct, exactly representable values reveal dropped or repeated frames.
            let value = Float((second % 100) + 1) / 256
            for frame in 0..<16000 { buffer.floatChannelData![0][frame] = value }
            try file.write(from: buffer)
        }
    }

    static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.wav")
        try writeAudio(to: source, seconds: 783) // Exceeds the 25 MB attachment limit.
        let compressed = try verifyChunking(source: source, directory: root)
        try verifyPauses(directory: root)
        try verifyContextPrompt()
        try await verifyDirectImports(directory: root)
        try await verifyUploads(source: source, compressed: compressed)
        print("Long recording checks passed: frame continuity, byte limits, sequential uploads, metadata, quota failure, cancellation, and cleanup.")
    }

    static func verifyChunking(source: URL, directory: URL) throws -> URL {
        // Verify decoded content across every boundary, byte bounds, and final tail.
        let chunks = try AudioChunks(file: source, maximumBytes: 100_096, maximumSeconds: 10)
        let part = directory.appendingPathComponent("part.wav")
        var frames: AVAudioFramePosition = 0
        while let range = try chunks.next(to: part) {
            try expect(abs(range.startSeconds - Double(frames) / 16000) < 0.00001, "Chunk offset gap")
            let audio = try AVAudioFile(forReading: part)
            let buffer = AVAudioPCMBuffer(pcmFormat: audio.processingFormat, frameCapacity: AVAudioFrameCount(audio.length))!
            try audio.read(into: buffer)
            for index in 0..<Int(buffer.frameLength) {
                let second = Int(frames + AVAudioFramePosition(index)) / 16000
                try expect(buffer.floatChannelData![0][index] == Float((second % 100) + 1) / 256, "Audio changed at chunk boundary")
            }
            frames += audio.length
            try expect((try part.resourceValues(forKeys: [.fileSizeKey]).fileSize!) < 100_096, "Chunk exceeds byte budget")
            try FileManager.default.removeItem(at: part)
        }
        try expect(frames == 783 * 16000, "Lost trailing audio")

        // Exercise the AAC decoder used by actual Sotto recordings as well as WAV.
        let compressed = directory.appendingPathComponent("short.m4a")
        do {
            let input = try AVAudioFile(forReading: source)
            let output = try AVAudioFile(forWriting: compressed, settings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 16000,
                AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 32000
            ])
            let buffer = AVAudioPCMBuffer(pcmFormat: input.processingFormat, frameCapacity: 80000)!
            try input.read(into: buffer)
            try output.write(from: buffer)
        }
        let compressedChunks = try AudioChunks(file: compressed, maximumSeconds: 2)
        var decodedFrames: AVAudioFramePosition = 0
        while let _ = try compressedChunks.next(to: part) {
            decodedFrames += try AVAudioFile(forReading: part).length
            try FileManager.default.removeItem(at: part)
        }
        try expect(decodedFrames == (try AVAudioFile(forReading: compressed).length), "AAC tail lost")

        // Apply the byte cap before converting a large duration to an integer frame count.
        let largeLimit = try AudioChunks(file: compressed, maximumSeconds: .greatestFiniteMagnitude)
        try expect(try largeLimit.next(to: part) != nil, "Large duration limit rejected valid audio")
        try expect(try AVAudioFile(forReading: part).length == decodedFrames, "Large duration limit lost audio")
        try FileManager.default.removeItem(at: part)
        return compressed
    }

    static func verifyPauses(directory: URL) throws {
        let source = directory.appendingPathComponent("pauses.wav")
        let part = directory.appendingPathComponent("pause-part.wav")
        let rate = 16000
        let format = AVAudioFormat(standardFormatWithSampleRate: Double(rate), channels: 2)!
        // Latest pause, too-short pause, silence through the limit, and speech on
        // just one channel. Compare every sample, including all subsequent chunks.
        for (pauses, noisyChannel, expectedEnd) in [
            ([1.6..<2.0, 2.4..<2.8], false, 2.6),
            ([2.4..<2.5], false, 3.0),
            ([0.0..<8.0], false, 3.0),
            ([2.4..<2.8], true, 3.0)
        ] {
            func sample(_ frame: Int, _ channel: Int) -> Float {
                let quiet = pauses.contains { $0.contains(Double(frame) / Double(rate)) }
                return quiet && !(noisyChannel && channel == 1) ? 0 : Float((frame + channel) % 100 + 1) / 256
            }
            do {
                let file = try AVAudioFile(forWriting: source, settings: [
                    AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: rate,
                    AVNumberOfChannelsKey: 2, AVLinearPCMBitDepthKey: 16,
                    AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false
                ])
                let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(rate))!
                buffer.frameLength = buffer.frameCapacity
                for second in 0..<8 {
                    for channel in 0..<2 {
                        for frame in 0..<rate { buffer.floatChannelData![channel][frame] = sample(second * rate + frame, channel) }
                    }
                    try file.write(from: buffer)
                }
            }
            let chunks = try AudioChunks(file: source, maximumSeconds: 3)
            var frames = 0
            while let segment = try chunks.next(to: part) {
                try expect(abs(segment.startSeconds - Double(frames) / Double(rate)) < 0.00001, "Pause splitting created a gap")
                if frames == 0 { try expect(abs(segment.durationSeconds - expectedEnd) < 0.011, "Wrong pause boundary") }
                let audio = try AVAudioFile(forReading: part)
                let buffer = AVAudioPCMBuffer(pcmFormat: audio.processingFormat, frameCapacity: AVAudioFrameCount(audio.length))!
                try audio.read(into: buffer)
                try expect(buffer.frameLength > 0 && audio.length <= 3 * rate, "Pause splitting did not progress within the limit")
                for channel in 0..<2 {
                    for frame in 0..<Int(buffer.frameLength) {
                        try expect(buffer.floatChannelData![channel][frame] == sample(frames + frame, channel), "Pause splitting altered audio")
                    }
                }
                frames += Int(buffer.frameLength)
                try FileManager.default.removeItem(at: part)
            }
            try expect(frames == 8 * rate, "Pause splitting lost final frames")
        }
    }

    static func verifyContextPrompt() throws {
        for text in ["", "CUDA", String(repeating: "context ", count: 200),
                     String(repeating: "你好 👨‍👩‍👧‍👦 é ", count: 100)] {
            let prompt = GroqClient.contextPrompt(text)
            try expect(prompt.utf8.count <= 224 && text.hasSuffix(prompt), "Context exceeded token bound or changed Unicode")
            if text.utf8.count <= 224 { try expect(prompt == text, "Short context changed") }
        }
    }

    static func verifyDirectImports(directory: URL) async throws {
        let settings = URLSessionConfiguration.ephemeral
        settings.protocolClasses = [UploadFixture.self]
        let client = GroqClient(transcriptionEndpoint: URL(string: "https://sotto.invalid/transcriptions")!, uploadConfiguration: settings)
        for (ext, bytes) in [("ogg", 24_000_001), ("webm", 24_999_999)] {
            let file = directory.appendingPathComponent("opaque.\(ext)")
            FileManager.default.createFile(atPath: file.path, contents: nil)
            let handle = try FileHandle(forWritingTo: file)
            try handle.truncate(atOffset: UInt64(bytes)); try handle.close()
            UploadFixture.reset()
            _ = try await client.transcribe(file: file, key: "fixture-key", model: "whisper-large-v3-turbo", language: nil, prompt: "")
            try expect(UploadFixture.count == 1, "Sub-25 MB import required local decoding")
        }
    }

    static func verifyUploads(source: URL, compressed: URL) async throws {
        let originalSize = try source.resourceValues(forKeys: [.fileSizeKey]).fileSize
        let uploadsBefore = try temporaryUploads()
        let settings = URLSessionConfiguration.ephemeral
        settings.protocolClasses = [UploadFixture.self]
        let client = GroqClient(transcriptionEndpoint: URL(string: "https://sotto.invalid/transcriptions")!, uploadConfiguration: settings)
        func transcribe(_ file: URL, trimWhitespace: Bool = true) async throws -> TranscriptionResult {
            try await client.transcribe(file: file, key: "fixture-key", model: "whisper-large-v3-turbo",
                                        language: "en", prompt: "", trimWhitespace: trimWhitespace)
        }
        UploadFixture.reset()
        let result = try await transcribe(source)
        try expect(UploadFixture.count == 2, "Expected two uploads")
        try expect(result.text == "Part 1.\n\nPart 2.", "Transcript order or trimming changed")
        let raw = try JSONSerialization.jsonObject(with: result.rawResponse) as! [String: Any]
        let responses = raw["chunks"] as! [[String: Any]]
        try expect(responses.count == 2 && responses[1]["start_seconds"] as? Double == 600, "Missing chunk offsets")
        try expect(responses[1]["duration_seconds"] as? Double == 183, "Missing final chunk")
        try expect(responses[0]["request_id"] as? String == "part-1", "Missing request IDs")
        try expect((responses[0]["response"] as? [String: Any])?["text"] as? String == " Part 1. ", "Raw response changed")
        try expect(try temporaryUploads() == uploadsBefore, "Temporary uploads leaked on success")

        // Full responses are paragraphs, without word metadata or word guessing.
        for (first, second, expected) in [
            ("Hello, splitword", "splitword again again.", "Hello, splitword\n\nsplitword again again."),
            ("Hello,\nworld", "Next.", "Hello,\nworld\n\nNext."),
            ("你好世界", "世界再见", "你好世界\n\n世界再见"),
            (" \n", "Next.", "Next."), ("First.", "", "First."), ("", " ", "")
        ] {
            let payloads: [[String: Any]] = [["text": first, "extra": ["unmodified": [1, 2, 3]]], ["text": second]]
            let encoded = try payloads.map { String(decoding: try JSONSerialization.data(withJSONObject: $0), as: UTF8.self) }
            UploadFixture.reset(payloads: encoded)
            let joined = try await transcribe(source)
            try expect(UploadFixture.count == 2 && joined.text == expected, "Paragraph content changed")
            let envelope = try JSONSerialization.jsonObject(with: joined.rawResponse) as! [String: Any]
            try expect(envelope["text"] as? String == expected, "Saved transcript differs from returned text")
            let parts = envelope["chunks"] as! [[String: Any]]
            try expect((parts[0]["response"] as? NSDictionary) == (payloads[0] as NSDictionary), "Spooling changed raw fields")
            // Access after the temporary response file has been unlinked.
            try expect(String(decoding: joined.rawResponse, as: UTF8.self).contains(encoded[0]), "Spooling changed raw bytes")
            try expect(try temporaryUploads() == uploadsBefore, "Response spool leaked")
        }
        UploadFixture.reset()
        let untrimmed = try await transcribe(source, trimWhitespace: false)
        try expect(untrimmed.text == " Part 1. \n\n Part 2. ", "Disabled whitespace trimming changed paragraph content")

        UploadFixture.reset()
        let short = try await transcribe(compressed, trimWhitespace: false)
        try expect(UploadFixture.count == 1 && short.text == " Part 1. ", "Single upload behavior changed")
        try expect(short.requestID == "part-1" && short.rawResponse == Data(UploadFixture.payload(1).utf8), "Single response metadata changed")

        UploadFixture.reset(failingRequest: 2)
        do {
            _ = try await transcribe(source)
            throw SottoError("Partial transcript reported as complete")
        } catch {
            let message = error.localizedDescription
            try expect(message.contains("HTTP 429") && message.contains("part 2") && message.contains("Retrying starts from the beginning"), "Missing actionable quota error")
            try expect(!message.contains("fixture-key"), "Credential leaked in error")
        }
        try expect(UploadFixture.count == 2, "Unexpected automatic retry")
        try expect(try temporaryUploads() == uploadsBefore, "Temporary uploads leaked on failure")
        try expect(try source.resourceValues(forKeys: [.fileSizeKey]).fileSize == originalSize, "Original audio changed")

        UploadFixture.reset()
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await transcribe(source)
        }
        do { _ = try await task.value; throw SottoError("Cancellation ignored") }
        catch is CancellationError { }
        try expect(UploadFixture.count == 0, "Cancelled transcription uploaded audio")
        try expect(try temporaryUploads() == uploadsBefore, "Temporary uploads leaked on cancellation")

        UploadFixture.reset(blockedRequest: 2)
        let inFlight = Task {
            try await transcribe(source)
        }
        let deadline = Date().addingTimeInterval(10)
        while UploadFixture.count < 2 && Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        inFlight.cancel()
        do { _ = try await inFlight.value; throw SottoError("In-flight cancellation ignored") }
        catch is CancellationError { }
        try expect(UploadFixture.count == 2, "Did not reach second upload before cancellation")
        try expect(try temporaryUploads() == uploadsBefore, "Temporary uploads leaked during cancelled upload")
    }
}
