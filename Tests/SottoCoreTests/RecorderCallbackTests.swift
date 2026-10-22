import AVFoundation
import Foundation
import Testing
@testable import SottoCore

@MainActor @Test func callbacksFromAnInactiveRecorderAreIgnored() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    defer { try! FileManager.default.removeItem(at: directory) }
    let native = try AVAudioRecorder(url: directory.appendingPathComponent("inactive.m4a"), settings: [
        AVFormatIDKey: kAudioFormatMPEG4AAC,
        AVSampleRateKey: 16000,
        AVNumberOfChannelsKey: 1,
    ])
    var callbacks = 0
    weak var pending: Recorder?
    do {
        let recorder = Recorder()
        pending = recorder
        recorder.onUnexpectedStop = { _ in callbacks += 1 }
        recorder.audioRecorderDidFinishRecording(native, successfully: true)
        recorder.audioRecorderDidFinishRecording(native, successfully: false)
        recorder.audioRecorderEncodeErrorDidOccur(native, error: SottoError("Delayed encoder failure"))
    }
    // Callback tasks retain their receiver until their main-actor handlers finish.
    while pending != nil { await Task.yield() }
    #expect(callbacks == 0)
}
