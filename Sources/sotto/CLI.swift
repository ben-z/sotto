import AppKit
import SottoCore

enum Paths {
    static let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Sotto", isDirectory: true)
    static let config = support.appendingPathComponent("config.json")
    static let status = support.appendingPathComponent("status.json")
}

@main
struct CLI {
    @MainActor static func main() async {
        umask(0o077)
        do {
            let args = Array(CommandLine.arguments.dropFirst())
            switch args.first ?? "run" {
            case "init":
                guard args.count == 1 || args.count == 2 else { throw SottoError("Usage: sotto init [absolute-recordings-directory]") }
                guard !FileManager.default.fileExists(atPath: Paths.config.path) else { throw SottoError("Configuration already exists: \(Paths.config.path)") }
                let defaultPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Sotto").path
                try Configuration(recordingsDirectory: args.count == 2 ? args[1] : defaultPath).save(to: Paths.config)
                print(Paths.config.path)
            case "config":
                guard args.count == 1 else { throw SottoError("Usage: sotto config (prints configuration path; edit JSON and restart)") }
                _ = try Configuration.load(from: Paths.config)
                print(Paths.config.path)
            case "key":
                if args == ["key", "check"] {
                    let config = try Configuration.load(from: Paths.config)
                    try await GroqClient().verifyKey(GroqKeychain.read(), model: config.model)
                    print("Groq accepted the Keychain credential and lists \(config.model). No audio was sent; transcription/quota was not tested.")
                    return
                }
                guard args == ["key", "set"] || args == ["key", "set", "--stdin"] else { throw SottoError("Usage: sotto key set [--stdin]") }
                let value: String
                if args.last == "--stdin" {
                    guard let line = readLine() else { throw SottoError("No key on stdin.") }; value = line
                } else {
                    guard let input = getpass("Groq API key (hidden): ") else { throw SottoError("Cannot read hidden input. Use --stdin for a pipe.") }; value = String(cString: input)
                }
                try GroqKeychain.save(value); print("Groq API key saved to Keychain.")
            case "doctor":
                let config = try Configuration.load(from: Paths.config)
                _ = try Archive(directory: config.recordingsURL)
                _ = try GroqKeychain.read()
                if config.paste, !AXIsProcessTrusted() { throw SottoError("Accessibility permission required by configuration is missing.") }
                print("Configuration, archive destination, and Keychain OK. Microphone is requested on first recording. No API request was made.")
            case "status":
                let running = NSRunningApplication.runningApplications(withBundleIdentifier: "dev.sotto.app")
                print("Agent PIDs: \(running.map(\.processIdentifier))")
                print(try String(contentsOf: Paths.status, encoding: .utf8))
            case "toggle", "cancel", "quit":
                let apps = NSRunningApplication.runningApplications(withBundleIdentifier: "dev.sotto.app")
                guard apps.count == 1, let pid = apps.first?.processIdentifier else { throw SottoError("Expected exactly one running Sotto.app. Run scripts/launch.sh first.") }
                let number = args[0] == "toggle" ? SIGUSR1 : args[0] == "cancel" ? SIGUSR2 : SIGTERM
                guard kill(pid, number) == 0 else { throw SottoError("Could not signal Sotto: \(String(cString: strerror(errno)))") }
            case "transcribe":
                guard args.count == 2 else { throw SottoError("Usage: sotto transcribe /path/to/recording.m4a (saves a fresh attempt beside configured recordings)") }
                let config = try Configuration.load(from: Paths.config)
                let key = try GroqKeychain.read()
                let archive = try Archive(directory: config.recordingsURL)
                let input = URL(fileURLWithPath: NSString(string: args[1]).expandingTildeInPath)
                guard ["m4a", "wav", "mp3", "flac", "ogg", "webm", "mp4"].contains(input.pathExtension.lowercased()) else { throw SottoError("Unsupported audio extension.") }
                var record = try archive.newRecord(model: config.model, language: config.language, prompt: "", contextTerms: [])
                record.audioFile = "\(record.id).\(input.pathExtension.lowercased())"
                do {
                    try FileManager.default.copyItem(at: input, to: archive.audioURL(record))
                    record.status = "transcribing"; record.audioBytes = try input.resourceValues(forKeys: [.fileSizeKey]).fileSize
                    try archive.save(record)
                    let result = try await GroqClient().transcribe(file: archive.audioURL(record), key: key, model: record.model, language: record.language, prompt: record.prompt, trimWhitespace: config.trimWhitespace)
                    try archive.complete(&record, with: result)
                    print(result.text)
                    fputs("Saved \(record.id); \(result.milliseconds) ms\n", stderr)
                } catch {
                    record.status = "failed"; record.error = error.localizedDescription
                    try archive.save(record)
                    throw error
                }
            case "run":
                guard args.count <= 1 else { throw SottoError("Usage: sotto run") }
                let defaultDirectory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Sotto").path
                let config = try Configuration.loadOrCreate(from: Paths.config, recordingsDirectory: defaultDirectory)
                let app = NSApplication.shared
                app.setActivationPolicy(.accessory)
                let agent = try Agent(configuration: config)
                app.delegate = agent
                withExtendedLifetime(agent) { app.run() }
            case "help", "--help", "-h":
                print("""
                Sotto — small voice notes, your Groq key.
                init [directory]   Create configuration; all audio is retained here
                config             Print config.json path; edit then restart
                key set [--stdin]  Store key in macOS Keychain (never in config)
                key check          Verify authentication/model listing with Groq
                doctor             Validate required local prerequisites
                status             Running PID and last state/error
                toggle             Start/stop the running agent
                cancel             Cancel; retain the recording
                quit               Stop the agent safely
                transcribe FILE    Transcribe/retry a file; retain audio and diagnostics
                run                Run the background agent (prefer scripts/launch.sh)
                Default hotkey: Control+Option+Space; menu icon shows state.
                """)
            default: throw SottoError("Unknown command. Run `sotto help`.")
            }
        } catch {
            fputs("Sotto: \(error.localizedDescription)\n", stderr)
            if CommandLine.arguments.count == 1 { showStartupError(error) }
            exit(1)
        }
    }
    @MainActor static func showStartupError(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = "Sotto could not start"
        alert.informativeText = error.localizedDescription
        alert.addButton(withTitle: "Quit")
        alert.addButton(withTitle: "Show Configuration")
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        app.activate()
        if alert.runModal() == .alertSecondButtonReturn {
            NSWorkspace.shared.activateFileViewerSelecting([Paths.config])
        }
    }

}
