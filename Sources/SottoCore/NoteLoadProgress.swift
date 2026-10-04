import Foundation

public enum NoteLoadProgress: Equatable, Sendable {
    case opening
    case reading(loaded: Int, total: Int)
    case recovering(recovered: Int, total: Int)
}

public struct NoteLoadFailure: LocalizedError, Sendable {
    public enum Operation: String, Sendable {
        case openFolder = "Open notes folder"
        case readNote = "Read note"
        case recoverNote = "Recover interrupted note"
        case saveFolder = "Save folder selection"
    }

    public let operation: Operation
    public let url: URL
    public let underlying: any Error

    public init(operation: Operation, url: URL, underlying: any Error) {
        self.operation = operation
        self.url = url
        self.underlying = underlying
    }

    public var errorDescription: String? {
        switch operation {
        case .openFolder: "The notes folder couldn’t be opened."
        case .readNote: "Cannot read \(url.lastPathComponent): \(underlying.localizedDescription)"
        case .recoverNote: "The interrupted status couldn’t be saved for \(url.lastPathComponent)."
        case .saveFolder: "The folder selection couldn’t be saved."
        }
    }

    public var technicalDetails: String {
        var lines = ["Operation: \(operation.rawValue)", "Path: \(url.path)"]
        if underlying is DecodingError { lines.append(String(reflecting: underlying)) }
        var error: NSError? = underlying as NSError
        var seen = Set<ObjectIdentifier>()
        while let current = error, seen.insert(ObjectIdentifier(current)).inserted {
            lines.append("\(current.domain) (\(current.code)): \(current.localizedDescription)")
            if let reason = current.localizedFailureReason, !current.localizedDescription.contains(reason) { lines.append(reason) }
            if let suggestion = current.localizedRecoverySuggestion { lines.append(suggestion) }
            error = current.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return lines.joined(separator: "\n")
    }
}
