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

    func validate() throws {
        guard text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !(words ?? []).isEmpty else {
            throw SottoError("Groq omitted word timestamps needed to reconcile overlapping audio.")
        }
    }

    func slice(_ indices: Range<Int>, following previous: Character? = nil) throws -> String {
        let selected = try selectedText(indices, following: previous)
        // Reconcile every selected boundary, including complete responses and
        // slices beginning at word zero. Keep the preceding separator if present.
        return previous?.isWhitespace == true ? String(selected.drop(while: \.isWhitespace)) : selected
    }

    private func selectedText(_ indices: Range<Int>, following previous: Character?) throws -> String {
        try validate()
        guard let words, !words.isEmpty else { return text }
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

/// Keeps one pending response to reconcile neighboring overlap words.
/// Shared words appear once; unmatched words keep their nominal ownership.
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
        try transcript.validate()
        var first = 0
        if let previous = pending {
            let left = previous.transcript.words ?? []
            let right = transcript.words ?? []
            let offset = segment.startSeconds - previous.segment.startSeconds
            let overlap = previous.segment.durationSeconds - offset
            let leftStart = max(previous.first, left.firstIndex { $0.end >= offset } ?? left.count)
            first = right.firstIndex { $0.start > overlap } ?? right.count
            let pairs = Self.align(left: left, right: right, lhs: leftStart..<left.count, rhs: 0..<first,
                                   offset: offset, overlap: overlap)
            var pieces: [(left: Bool, range: Range<Int>)] = []
            if previous.first < leftStart { pieces.append((true, previous.first..<leftStart)) }
            func choose(left: Bool, index: Int) {
                if let last = pieces.last, last.left == left, last.range.upperBound == index {
                    pieces[pieces.count - 1].range = last.range.lowerBound..<(index + 1)
                } else {
                    pieces.append((left, index..<(index + 1)))
                }
            }
            func leftOwns(_ index: Int) -> Bool {
                (left[index].start + left[index].end) / 2 < previous.segment.retainedSeconds.upperBound
            }
            var i = leftStart, j = 0
            // Alignment anchors remove duplicates without discarding the unmatched
            // words between them. The sentinel also flushes both unmatched tails.
            for (leftIndex, rightIndex) in pairs + [(left.count, first)] {
                while i < leftIndex {
                    if leftOwns(i) { choose(left: true, index: i) }
                    i += 1
                }
                while j < rightIndex {
                    if (right[j].start + right[j].end) / 2 >= segment.retainedSeconds.lowerBound {
                        choose(left: false, index: j)
                    }
                    j += 1
                }
                if leftIndex < left.count && rightIndex < first {
                    // One shared word survives even if timestamp drift puts both
                    // copies outside their nominal ownership intervals.
                    if leftOwns(leftIndex) { choose(left: true, index: leftIndex) }
                    else { choose(left: false, index: rightIndex) }
                    i += 1; j += 1
                }
            }
            for piece in pieces {
                let source = piece.left ? previous.transcript : transcript
                text += try source.slice(piece.range, following: text.last)
            }
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

    private static func align(left: [ChunkTranscript.Word], right: [ChunkTranscript.Word],
                              lhs: Range<Int>, rhs: Range<Int>, offset: Double, overlap: Double) -> [(Int, Int)] {
        guard overlap > 0, !lhs.isEmpty, !rhs.isEmpty else { return [] }
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
        return row.last?.pairs ?? []
    }
}
