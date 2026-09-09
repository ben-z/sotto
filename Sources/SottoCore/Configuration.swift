import Foundation

public struct SottoError: LocalizedError, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

public struct Configuration: Codable, Sendable, Equatable {
    public var recordingsDirectory: String
    public var model = "whisper-large-v3-turbo"
    public var language: String? = nil
    public var trimWhitespace = true
    public var paste = false
    public var hotkeyKeyCode: UInt32 = 49 // Space
    public var hotkeyModifiers: UInt32 = 6144 // Control + Option (Carbon masks)
    public var hotkeyMode = "toggle" // or hold
    public var maxRecordingSeconds: Double = 1800
    public var audioBitRate = 32000

    public init(recordingsDirectory: String) { self.recordingsDirectory = recordingsDirectory }

    private enum CodingKeys: String, CodingKey {
        case recordingsDirectory, model, language, paste, hotkeyKeyCode, hotkeyModifiers, hotkeyMode, maxRecordingSeconds, audioBitRate, trimWhitespace
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        recordingsDirectory = try values.decode(String.self, forKey: .recordingsDirectory)
        model = try values.decode(String.self, forKey: .model)
        language = try values.decodeIfPresent(String.self, forKey: .language)
        paste = try values.decode(Bool.self, forKey: .paste)
        hotkeyKeyCode = try values.decode(UInt32.self, forKey: .hotkeyKeyCode)
        hotkeyModifiers = try values.decode(UInt32.self, forKey: .hotkeyModifiers)
        hotkeyMode = try values.decode(String.self, forKey: .hotkeyMode)
        maxRecordingSeconds = try values.decode(Double.self, forKey: .maxRecordingSeconds)
        audioBitRate = try values.decode(Int.self, forKey: .audioBitRate)
        trimWhitespace = try values.decodeIfPresent(Bool.self, forKey: .trimWhitespace) ?? true
    }

    public func validate() throws {
        guard recordingsDirectory.hasPrefix("/") || recordingsDirectory.hasPrefix("~/") else {
            throw SottoError("recordingsDirectory must be an absolute path or start with ~/.")
        }
        guard ["whisper-large-v3-turbo", "whisper-large-v3"].contains(model) else {
            throw SottoError("Unsupported model: \(model). Use whisper-large-v3-turbo or whisper-large-v3.")
        }
        guard ["toggle", "hold"].contains(hotkeyMode), hotkeyModifiers != 0, hotkeyKeyCode <= 127 else {
            throw SottoError("Invalid hotkey configuration. Use toggle/hold, a key code in 0...127, and nonzero Carbon modifier flags.")
        }
        guard (1...3600).contains(maxRecordingSeconds), (16000...128000).contains(audioBitRate) else {
            throw SottoError("Invalid limits: recording 1...3600 seconds, bitrate 16000...128000.")
        }
        if let language, language.count != 2 || !language.allSatisfy({ $0.isASCII && $0.isLowercase }) {
            throw SottoError("language must be a two-letter lowercase ISO code, or null for detection.")
        }
    }

    public var recordingsURL: URL {
        URL(fileURLWithPath: NSString(string: recordingsDirectory).expandingTildeInPath, isDirectory: true)
    }

    public static func load(from url: URL) throws -> Self {
        let value = try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
        try value.validate()
        return value
    }

    public static func loadOrCreate(from url: URL, recordingsDirectory: String) throws -> Self {
        do { return try load(from: url) }
        catch CocoaError.fileReadNoSuchFile {
            let configuration = Self(recordingsDirectory: recordingsDirectory)
            try configuration.save(to: url)
            return configuration
        }
    }

    public func save(to url: URL) throws {
        try validate()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONFile.write(self, to: url)
    }
}

public enum JSONFile {
    public static func write<T: Encodable>(_ value: T, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(value).write(to: url, options: .atomic)
    }
}
