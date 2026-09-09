import AppKit

/// Copy SottoGlyphTemplate.png and SottoGlyphTemplate@2x.png into Contents/Resources/SottoStatus.
/// Construct once on launch. Missing artwork is an explicit startup error.
@MainActor
final class SottoStatusArtwork {
    enum State: String, CaseIterable {
        case idle, preparing, recording, transcribing, error

        var description: String {
            switch self {
            case .idle: "Ready — hold Control–Command–S to record"
            case .preparing: "Preparing microphone"
            case .recording: "Recording — release the shortcut to finish"
            case .transcribing: "Transcribing"
            case .error: "Needs attention — open Sotto for details"
            }
        }
    }

    struct MissingArtwork: LocalizedError {
        let path: String
        var errorDescription: String? { "Required Sotto status artwork is missing or invalid: \(path)" }
    }

    private let glyph: NSImage

    init(resourceDirectory: URL) throws {
        let image = NSImage(size: NSSize(width: 18, height: 18))
        for scale in 1...2 {
            let suffix = scale == 1 ? "" : "@2x"
            let url = resourceDirectory.appendingPathComponent("SottoGlyphTemplate\(suffix).png")
            guard let data = try? Data(contentsOf: url), let rep = NSBitmapImageRep(data: data),
                  rep.pixelsWide == 18 * scale, rep.pixelsHigh == 18 * scale else {
                throw MissingArtwork(path: url.path)
            }
            rep.size = image.size
            image.addRepresentation(rep)
        }
        image.isTemplate = true
        glyph = image
    }

    func image(for _: State) -> NSImage { glyph }

    func apply(_ state: State, to item: NSStatusItem) {
        guard let button = item.button else { preconditionFailure("Sotto status item has no button") }
        item.length = NSStatusItem.variableLength
        button.image = image(for: state)
        button.imagePosition = .imageOnly
        button.title = ""
        button.contentTintColor = nil // Let AppKit handle selected, light, dark, and disabled appearances.
        button.toolTip = "Sotto — \(state.description)"
        button.setAccessibilityLabel("Sotto")
        button.setAccessibilityValue(state.description)
    }
}
