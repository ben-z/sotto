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

    func retaining(_ seconds: Range<Double>, following previous: Character? = nil) throws -> String {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return text }
        guard let words, !words.isEmpty else {
            throw SottoError("Groq omitted word timestamps needed to reconcile overlapping audio.")
        }
        let kept = words.indices.filter { seconds.contains((words[$0].start + words[$0].end) / 2) }
        guard let first = kept.first, let last = kept.last else { return "" }
        return try slice(first..<(last + 1), following: previous)
    }

    func slice(_ indices: Range<Int>, following previous: Character? = nil) throws -> String {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return text }
        guard let words, !words.isEmpty else {
            throw SottoError("Groq omitted word timestamps needed to reconcile overlapping audio.")
        }
        guard !indices.isEmpty else { return "" }
        let first = indices.lowerBound, last = indices.upperBound - 1
        if first == 0 && last == words.count - 1 { return text }

        var cursor = text.startIndex
        var lower = text.startIndex
        var upper = text.endIndex
        for (index, word) in words.enumerated() {
            let token = word.word.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !token.isEmpty, let match = text.range(of: token, range: cursor..<text.endIndex) else {
                throw SottoError("Groq word timestamps could not be matched to the transcript.")
            }
            if index == first && first > 0 {
                lower = match.lowerBound
                // Keep the separator before the first owned word when the earlier
                // response supplied none. Unspaced scripts have no gap to restore.
                if let previous, !previous.isWhitespace {
                    while lower > cursor {
                        let before = text.index(before: lower)
                        guard text[before].isWhitespace else { break }
                        lower = before
                    }
                }
            }
            if index == last + 1 { upper = match.lowerBound; break }
            cursor = match.upperBound
        }
        return String(text[lower..<upper])
    }
}

/// Keeps one pending response so adjacent overlap words can share a single seam.
/// Timestamps locate the overlap; matching words decide which response owns it.
struct ChunkTranscriptMerger {
    private struct Pending {
        let transcript: ChunkTranscript
        let segment: AudioChunks.Segment
        let first: Int
    }
    private var pending: Pending?
    private var text = ""

    mutating func append(_ transcript: ChunkTranscript, segment: AudioChunks.Segment) throws {
        // Validate metadata even if this chunk will be held until the next upload.
        _ = try transcript.retaining(segment.retainedSeconds)
        var first = 0
        if let previous = pending {
            let left = previous.transcript.words ?? []
            let right = transcript.words ?? []
            var end = left.firstIndex { ($0.start + $0.end) / 2 >= previous.segment.retainedSeconds.upperBound } ?? left.count
            first = right.firstIndex { ($0.start + $0.end) / 2 >= segment.retainedSeconds.lowerBound } ?? right.count
            if let seam = Self.seam(left: left, right: right, previous: previous.segment, current: segment) {
                end = seam.left + 1
                first = seam.right + 1
            }
            text += try previous.transcript.slice(previous.first..<max(previous.first, end), following: text.last)
        }
        pending = Pending(transcript: transcript, segment: segment, first: first)
    }

    mutating func finish() throws -> String {
        if let pending {
            text += try pending.transcript.slice(pending.first..<(pending.transcript.words?.count ?? 0), following: text.last)
        }
        pending = nil
        return text
    }

    private static func seam(left: [ChunkTranscript.Word], right: [ChunkTranscript.Word],
                             previous: AudioChunks.Segment, current: AudioChunks.Segment) -> (left: Int, right: Int)? {
        let offset = current.startSeconds - previous.startSeconds
        let overlap = previous.durationSeconds - offset
        guard overlap > 0 else { return nil }
        let lhs = left.indices.filter { left[$0].end >= offset && left[$0].start <= previous.durationSeconds }
        let rhs = right.indices.filter { right[$0].end >= 0 && right[$0].start <= overlap }
        guard !lhs.isEmpty, !rhs.isEmpty else { return nil }
        func token(_ word: ChunkTranscript.Word) -> String {
            let normalized = word.word.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters)).lowercased()
            return normalized.isEmpty ? word.word : normalized
        }
        // Order-preserving alignment protects genuine repeated words. Prefer more
        // shared words, then smaller timestamp differences when repetitions tie.
        struct Alignment {
            var pairs: [(Int, Int)] = []
            var drift = 0.0
            func better(than other: Self) -> Bool {
                pairs.count != other.pairs.count ? pairs.count > other.pairs.count : drift < other.drift
            }
        }
        var row = Array(repeating: Alignment(), count: rhs.count + 1)
        for i in lhs {
            var next = Array(repeating: Alignment(), count: rhs.count + 1)
            for (column, j) in rhs.enumerated() {
                let above = row[column + 1], before = next[column]
                var best = above.better(than: before) ? above : before
                let drift = abs((left[i].start + left[i].end) / 2 - offset - (right[j].start + right[j].end) / 2)
                if drift <= overlap / 2 && token(left[i]) == token(right[j]) {
                    var match = row[column]
                    match.pairs.append((i, j)); match.drift += drift
                    if match.better(than: best) { best = match }
                }
                next[column + 1] = best
            }
            row = next
        }
        let boundary = previous.retainedSeconds.upperBound
        return row.last?.pairs.min {
            abs((left[$0.0].start + left[$0.0].end) / 2 - boundary) < abs((left[$1.0].start + left[$1.0].end) / 2 - boundary)
        }.map { (left: $0.0, right: $0.1) }
    }
}
