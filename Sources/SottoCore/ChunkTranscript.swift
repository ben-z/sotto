import Foundation

/// Uses word timestamps to discard only overlapping context, keeping the original
/// transcript's punctuation and spacing instead of rebuilding it from word tokens.
struct ChunkTranscript: Decodable {
    struct Word: Decodable {
        let word: String
        let start: Double
        let end: Double
    }
    let text: String
    let words: [Word]?

    func retaining(_ seconds: Range<Double>) throws -> String {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return text }
        guard let words, !words.isEmpty else {
            throw SottoError("Groq omitted word timestamps needed to reconcile overlapping audio.")
        }
        let kept = words.indices.filter { seconds.contains((words[$0].start + words[$0].end) / 2) }
        guard let first = kept.first, let last = kept.last else { return "" }
        if first == 0 && last == words.count - 1 { return text }

        var cursor = text.startIndex
        var lower = text.startIndex
        var upper = text.endIndex
        for (index, word) in words.enumerated() {
            let token = word.word.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !token.isEmpty, let match = text.range(of: token, range: cursor..<text.endIndex) else {
                throw SottoError("Groq word timestamps could not be matched to the transcript.")
            }
            if index == first && first > 0 { lower = match.lowerBound }
            if index == last + 1 { upper = match.lowerBound; break }
            cursor = match.upperBound
        }
        return String(text[lower..<upper])
    }
}
