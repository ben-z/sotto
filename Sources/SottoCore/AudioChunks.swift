import AVFoundation
import Foundation

/// Decodes oversized recordings a buffer at a time. Only one upload chunk is
/// kept on disk; the original recording is never modified.
final class AudioChunks {
    static let maximumUploadBytes = 24_000_000 // Headroom below Groq's 25 MB attachment limit.
    private let input: AVAudioFile
    private let framesPerChunk: AVAudioFramePosition
    private let buffer: AVAudioPCMBuffer

    init(file: URL, maximumBytes: Int = maximumUploadBytes, maximumSeconds: Double = 600) throws {
        input = try AVAudioFile(forReading: file)
        let format = input.processingFormat
        let bytesPerFrame = Int(format.channelCount) * 2 // PCM16 WAV
        guard maximumBytes > 8192, bytesPerFrame > 0, maximumSeconds.isFinite, maximumSeconds > 0 else {
            throw SottoError("Invalid audio chunk limits.")
        }
        // AVAudioFile pads WAV headers; reserve space beyond the PCM payload.
        framesPerChunk = min(AVAudioFramePosition((maximumBytes - 8192) / bytesPerFrame),
                             AVAudioFramePosition(maximumSeconds * format.sampleRate))
        guard input.length > 0, framesPerChunk > 0 else { throw SottoError("Audio contains no readable frames.") }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16_384) else {
            throw SottoError("Could not allocate an audio chunk buffer.")
        }
        self.buffer = buffer
    }

    /// Contiguous frame ranges preserve all audio, including the final partial chunk.
    func next(to destination: URL) throws -> (startSeconds: Double, durationSeconds: Double)? {
        try Task.checkCancellation()
        let start = input.framePosition
        guard start < input.length else { return nil }
        let count = min(framesPerChunk, input.length - start)
        let format = input.processingFormat
        let output = try AVAudioFile(forWriting: destination, settings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: format.channelCount,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ], commonFormat: format.commonFormat, interleaved: format.isInterleaved)
        let end = start + count
        while input.framePosition < end {
            try Task.checkCancellation()
            try input.read(into: buffer, frameCount: AVAudioFrameCount(min(end - input.framePosition, AVAudioFramePosition(buffer.frameCapacity))))
            guard buffer.frameLength > 0 else { throw SottoError("Audio ended before the recording was fully read.") }
            try output.write(from: buffer)
        }
        return (Double(start) / format.sampleRate, Double(count) / format.sampleRate)
    }
}
