import Foundation

public enum Prompt {
    // A conservative UTF-8 byte budget avoids shipping a tokenizer just to stay
    // below Whisper's 224-token limit. Current context has priority over history.
    public static func build(contextTerms: [String], byteLimit: Int = 200) -> String {
        var seen = Set<String>()
        var result = ""
        for word in contextTerms {
            let term = word.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !term.isEmpty, seen.insert(term.lowercased()).inserted else { continue }
            let next = result.isEmpty ? term : result + ", " + term
            if next.utf8.count <= byteLimit { result = next }
        }
        return result
    }

    public static func technicalTerms(from text: String) -> [String] {
        // Deliberately simple: no OCR, embeddings, LLM, or always-on observer.
        let tokens = text.prefix(12000).split { !($0.isLetter || $0.isNumber || "_+.#/-".contains($0)) }
        var seen = Set<String>()
        return tokens.compactMap { token in
            let term = String(token).trimmingCharacters(in: CharacterSet(charactersIn: ".-/"))
            let capitals = term.filter(\.isUppercase).count
            guard (2...60).contains(term.count), capitals >= 2 || term.contains("_") || term.contains("++") || term.contains("#") else { return nil }
            return seen.insert(term.lowercased()).inserted ? term : nil
        }.prefix(40).map { $0 }
    }
}
