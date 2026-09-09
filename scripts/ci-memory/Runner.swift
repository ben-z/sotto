import Foundation

/// Test-only optimized host for the exact production core sources. Never packaged.
@main
struct MemoryWorkload {
    static func phase(_ name: String, cycle: Int = 0) {
        print("{\"phase\":\"\(name)\",\"cycle\":\(cycle)}")
        fflush(stdout)
    }

    static func transcribe(_ name: String, directory: URL, archive: Archive, client: GroqClient) async throws {
        var record = try archive.newRecord(model: "whisper-large-v3-turbo", language: "en", prompt: "", contextTerms: [])
        record.audioFile = record.id + ".wav"
        try FileManager.default.copyItem(at: directory.appendingPathComponent(name + ".wav"), to: archive.audioURL(record))
        let result = try await client.transcribe(file: archive.audioURL(record), key: "benchmark-fixture-key",
            model: record.model, language: record.language, prompt: "")
        guard result.text == "Sotto benchmark fixture." else { throw SottoError("Unexpected fixture response") }
        try archive.complete(&record, with: result)
        guard record.status == "complete" else { throw SottoError("Archive did not complete") }
    }

    static func main() async throws {
        let args = CommandLine.arguments
        guard args.count == 3, let endpoint = URL(string: args[2]), endpoint.host == "127.0.0.1" else {
            throw SottoError("Expected benchmark fixture directory and loopback endpoint")
        }
        let directory = URL(fileURLWithPath: args[1], isDirectory: true)
        let archive = try Archive(directory: directory.appendingPathComponent("archive"))
        let client = GroqClient(transcriptionEndpoint: endpoint)
        phase("warmup")
        for name in ["short", "long"] {
            try await transcribe(name, directory: directory, archive: archive, client: client)
        }
        phase("idle_before")
        try await Task.sleep(for: .seconds(5))
        for cycle in 1...3 {
            for name in ["short", "long"] {
                phase("\(name)_upload", cycle: cycle)
                try await transcribe(name, directory: directory, archive: archive, client: client)
            }
        }
        phase("idle_after")
        try await Task.sleep(for: .seconds(5))
    }
}
