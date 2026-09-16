import AVFoundation
import Foundation

/// A contiguous partition of decoded audio. One buffer and one upload file at a
/// time; every frame is exported once and the original is never modified.
final class AudioChunks {
    struct Segment {
        let startSeconds: Double
        let durationSeconds: Double
    }
    static let maximumUploadBytes = 24_000_000 // Headroom below Groq's 25 MB attachment limit.
    private let input: AVAudioFile
    private let framesPerChunk: AVAudioFramePosition
    private let buffer: AVAudioPCMBuffer
    private let outputFormat: AVAudioFormat
    private var nextFrame: AVAudioFramePosition = 0

    init(file: URL, maximumBytes: Int = maximumUploadBytes, maximumSeconds: Double = 600) throws {
        input = try AVAudioFile(forReading: file, commonFormat: .pcmFormatFloat32, interleaved: false)
        let format = input.processingFormat
        let bytesPerFrame = Int(format.channelCount) * 2 // PCM16 WAV
        let headerBytes = 8192 // AVAudioFile pads WAV headers beyond the PCM payload.
        guard maximumBytes > headerBytes, bytesPerFrame > 0, maximumSeconds.isFinite, maximumSeconds > 0 else {
            throw SottoError("Invalid audio chunk limits.")
        }
        let byteLimitedFrames = (maximumBytes - headerBytes) / bytesPerFrame
        framesPerChunk = AVAudioFramePosition(min(Double(byteLimitedFrames), maximumSeconds * format.sampleRate))
        guard input.length > 0, framesPerChunk > 0 else { throw SottoError("Audio contains no readable frames.") }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16_384),
              let outputFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: format.sampleRate,
                                               channels: format.channelCount, interleaved: true) else {
            throw SottoError("Could not prepare the audio chunk format and buffer.")
        }
        self.buffer = buffer
        self.outputFormat = outputFormat
    }

    func next(to destination: URL) throws -> Segment? {
        try Task.checkCancellation()
        let start = nextFrame
        guard start < input.length else { return nil }
        let limit = start + min(framesPerChunk, input.length - start)
        let end = limit == input.length ? limit : try pauseBoundary(start: start, limit: limit)
        input.framePosition = start
        let format = input.processingFormat
        let output = try AVAudioFile(forWriting: destination, settings: outputFormat.settings,
                                     commonFormat: format.commonFormat, interleaved: format.isInterleaved)
        while input.framePosition < end {
            try read(until: end, frames: buffer.frameCapacity)
            try output.write(from: buffer)
        }
        nextFrame = end
        return Segment(startSeconds: Double(start) / format.sampleRate,
                       durationSeconds: Double(end - start) / format.sampleRate)
    }

    /// Prefer the latest >=200 ms quiet interval in the last five seconds. Never
    /// search before halfway through a chunk, so even tiny limits make progress.
    /// This is a conservative pause hint, not speech detection or an ASR guarantee.
    private func pauseBoundary(start: AVAudioFramePosition, limit: AVAudioFramePosition) throws -> AVAudioFramePosition {
        let rate = input.processingFormat.sampleRate
        input.framePosition = max(start + (limit - start) / 2, limit - AVAudioFramePosition(rate * 5))
        let window = AVAudioFrameCount(min(Double(buffer.frameCapacity), max(1, rate * 0.02)))
        let minimumQuiet = AVAudioFramePosition(rate * 0.2)
        var quietStart = input.framePosition
        var boundary = limit
        while input.framePosition < limit {
            let position = input.framePosition
            try read(until: limit, frames: window)
            let quiet = (0..<Int(buffer.format.channelCount)).allSatisfy { channel in
                UnsafeBufferPointer(start: buffer.floatChannelData![channel], count: Int(buffer.frameLength))
                    .allSatisfy { abs($0) < 0.001 } // Below -60 dBFS on every channel.
            }
            if !quiet {
                if position - quietStart >= minimumQuiet { boundary = quietStart + (position - quietStart) / 2 }
                quietStart = input.framePosition
            }
        }
        // A quiet interval reaching the cap needs no earlier cut.
        return limit - quietStart >= minimumQuiet ? limit : boundary
    }

    private func read(until end: AVAudioFramePosition, frames: AVAudioFrameCount) throws {
        try Task.checkCancellation()
        try input.read(into: buffer, frameCount: AVAudioFrameCount(min(end - input.framePosition, AVAudioFramePosition(frames))))
        guard buffer.frameLength > 0 else { throw SottoError("Audio ended before the recording was fully read.") }
    }
}
