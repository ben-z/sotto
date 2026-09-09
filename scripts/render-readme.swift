import AppKit
import SottoCore

/// Documentation only: renders the real native views without recording or network calls.
@main struct ReadmeImages {
    @MainActor static func main() throws {
        _ = NSApplication.shared
        NSApp.appearance = NSAppearance(named: .aqua)
        let output = URL(fileURLWithPath: "docs/images", isDirectory: true)
        func save(_ image: NSImage, _ name: String) throws {
            guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
                  let png = bitmap.representation(using: .png, properties: [:]) else { throw SottoError("Cannot render \(name)") }
            try png.write(to: output.appendingPathComponent(name))
        }
        let guide = NSImage(size: NSSize(width: 760, height: 300))
        guide.lockFocus()
        NSColor(srgbRed: 0.97, green: 0.96, blue: 0.94, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: 760, height: 300).fill()
        func text(_ value: String, x: Double, y: Double, size: Double = 14, bold: Bool = false) {
            (value as NSString).draw(at: NSPoint(x: x, y: y), withAttributes: [.font: NSFont.systemFont(ofSize: size, weight: bold ? .semibold : .regular), .foregroundColor: NSColor(calibratedWhite: 0.18, alpha: 1)])
        }
        text("Look at the top center of your display", x: 26, y: 257, size: 21, bold: true)
        text("Below the camera notch, if your Mac has one. The light never takes focus.", x: 26, y: 233)
        for (i, entry) in [(Session.State.preparing, "Preparing", "Microphone is starting", "Small amber light"), (.recording, "Recording", "Keep holding the shortcut", "Solid coral light + REC"), (.transcribing, "Transcribing", "Release; text is on its way", "Three blue segments")].enumerated() {
            let x = Double(i) * 246 + 26
            text(entry.1, x: x, y: 192, size: 17, bold: true)
            let light = RecordingLight(frame: NSRect(x: 0, y: 0, width: 64, height: 8)); light.state = entry.0
            NSGraphicsContext.saveGraphicsState()
            let transform = NSAffineTransform(); transform.translateX(by: x, yBy: 145); transform.scale(by: 3); transform.concat()
            light.draw(light.bounds)
            NSGraphicsContext.restoreGraphicsState()
            text(entry.3, x: x, y: 118)
            text(entry.2, x: x, y: 96, size: 12)
        }
        text("Enlarged 3× for clarity. At rest, the light disappears; the bird stays in the menu bar.", x: 26, y: 32, size: 13)
        guide.unlockFocus()
        try save(guide, "indicator-guide.png")

        let config = Configuration(recordingsDirectory: "~/Documents/Sotto")
        let settings = SettingsWindow(configuration: config, configurationURL: URL(fileURLWithPath: "/Users/you/Library/Application Support/Sotto/config.json"), onSave: { _ in throw SottoError("Documentation preview cannot save settings") }, onClose: {})
        settings.present(showStatus: false)
        settings.window?.makeFirstResponder(nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            guard let window = settings.window else { fatalError("Settings window missing") }
            let capture = Process()
            capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            capture.arguments = ["-x", "-o", "-l", String(window.windowNumber), output.appendingPathComponent("settings.png").path]
            do { try capture.run(); capture.waitUntilExit() } catch { fatalError("Screenshot failed: \(error)") }
            guard capture.terminationStatus == 0 else { fatalError("Screenshot capture failed") }
            settings.close()
            // Capture the real floating indicator over a harmless demo background.
            let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main!
            let backdrop = NSWindow(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            backdrop.backgroundColor = NSColor(srgbRed: 0.97, green: 0.96, blue: 0.94, alpha: 1)
            backdrop.isReleasedWhenClosed = false
            let note = NSTextField(labelWithString: "A small light. Your workspace stays yours.")
            note.font = .systemFont(ofSize: 18)
            note.textColor = .secondaryLabelColor
            note.alignment = .center
            note.frame = NSRect(x: screen.frame.width / 2 - 300, y: screen.frame.height - screen.safeAreaInsets.top - 95, width: 600, height: 30)
            backdrop.contentView?.addSubview(note)
            backdrop.orderFrontRegardless()
            let indicator = RecordingIndicator()
            indicator.update(.recording)
            let region = "\(Int(screen.frame.midX - 380)),\(Int(NSScreen.screens[0].frame.maxY - screen.frame.maxY + screen.safeAreaInsets.top)),760,140"
            func captureEdge(_ name: String) {
                let shot = Process(); shot.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                shot.arguments = ["-x", "-R", region, output.appendingPathComponent(name).path]
                do { try shot.run(); shot.waitUntilExit() } catch { fatalError("Indicator screenshot failed: \(error)") }
                guard shot.terminationStatus == 0 else { fatalError("Indicator screenshot capture failed") }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                captureEdge("recording.png")
                indicator.update(.transcribing)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    captureEdge("transcribing.png")
                    indicator.update(.idle); backdrop.close()
                    print("Rendered indicator guide and captured native Settings, recording, and transcription states")
                    NSApp.stop(nil)
                    NSApp.postEvent(NSEvent.otherEvent(with: .applicationDefined, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, subtype: 0, data1: 0, data2: 0)!, atStart: true)
                }
            }
        }
        NSApp.run()
    }
}
