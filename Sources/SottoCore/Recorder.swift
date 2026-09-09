import AVFoundation
import Foundation

@MainActor
public final class Recorder: NSObject, AVAudioRecorderDelegate {
    private var recorder: AVAudioRecorder?
    public var onUnexpectedStop: ((String?) -> Void)?
    public override init() { super.init() }

    public static func requestPermission() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }

    public func start(at url: URL, bitRate: Int) throws {
        guard recorder == nil else { throw SottoError("Already recording.") }
        #if os(iOS)
        try AVAudioSession.sharedInstance().setCategory(.record, mode: .default)
        try AVAudioSession.sharedInstance().setActive(true)
        #endif
        let value = try AVAudioRecorder(url: url, settings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 16000,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: bitRate,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
        ])
        value.delegate = self
        guard value.record() else { throw SottoError("Microphone recording could not start at \(url.path).") }
        recorder = value
    }

    public func stop() throws -> Double {
        guard let value = recorder else { throw SottoError("No active recording.") }
        let duration = value.currentTime
        value.delegate = nil
        value.stop()
        recorder = nil
        #if os(iOS)
        try AVAudioSession.sharedInstance().setActive(false)
        #endif
        return duration
    }

    nonisolated public func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        Task { @MainActor in self.onUnexpectedStop?(flag ? nil : "Audio recording ended unsuccessfully.") }
    }

    nonisolated public func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: (any Error)?) {
        let message = error?.localizedDescription ?? "Audio encoder failed."
        Task { @MainActor in self.onUnexpectedStop?(message) }
    }
}
