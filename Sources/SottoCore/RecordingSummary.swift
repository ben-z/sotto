import SwiftUI

public struct RecordingSummary: View {
    public let note: RecordingRecord
    public init(note: RecordingRecord) { self.note = note }
    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(note.displayTitle).font(.headline).lineLimit(2)
            Text(timestamp).font(.subheadline).foregroundStyle(.secondary)
            Label(status, systemImage: note.status == "complete" ? "text.alignleft" : "waveform")
                .font(.caption).foregroundStyle(note.error == nil ? Color.secondary : Color.red)
        }.padding(.vertical, 5)
    }
    private var timestamp: String {
        let formatter = DateFormatter()
        formatter.timeZone = note.timeZoneIdentifier.flatMap(TimeZone.init(identifier:)) ?? .current
        formatter.setLocalizedDateFormatFromTemplate("MMM d yyyy jmm zzz")
        return formatter.string(from: note.startedAt)
    }
    private var status: String {
        switch note.status {
        case "recording": "Recording"
        case "transcribing": "Transcribing"
        case "queued": "Audio saved"
        case "complete": "Transcribed"
        case "interrupted": "Recording interrupted"
        case "cancelled": "Cancelled · Audio retained"
        default: "Transcription failed · Retry available"
        }
    }
}
