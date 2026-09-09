import AppKit
import SottoCore

/// A display-edge status light, drawn only when the session changes state.
@MainActor
final class RecordingIndicator {
    private let panel: NSPanel
    private let light = RecordingLight(frame: NSRect(x: 0, y: 0, width: 64, height: 8))

    init() {
        panel = NSPanel(contentRect: light.bounds, styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: true)
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.contentView = light
    }

    func update(_ state: Session.State) {
        guard state == .preparing || state == .recording || state == .transcribing else {
            panel.orderOut(nil)
            return
        }
        light.state = state
        panel.setAccessibilityLabel("Sotto: \(state.rawValue)")
        // Position once per recording; no cursor tracking or screen polling.
        // safeAreaInsets keeps the light below a physical camera notch. Using
        // frame rather than visibleFrame avoids moving with an auto-hidden Dock.
        if !panel.isVisible {
            let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
            if let screen {
                panel.setFrameOrigin(NSPoint(x: screen.frame.midX - panel.frame.width / 2,
                                             y: screen.frame.maxY - screen.safeAreaInsets.top - panel.frame.height))
            }
        }
        panel.orderFrontRegardless()
    }
}

@MainActor
final class RecordingLight: NSView {
    var state: Session.State = .preparing { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        // A hairline surround preserves contrast against light/dark content.
        // Only 60 x 6 points are painted; the rest is transparent.
        let surround = NSBezierPath(roundedRect: NSRect(x: 2, y: 1, width: 60, height: 6), xRadius: 3, yRadius: 3)
        NSColor(calibratedWhite: 0.06, alpha: 0.88).setFill()
        surround.fill()
        NSColor(calibratedWhite: 1, alpha: 0.22).setStroke()
        surround.lineWidth = 0.5
        surround.stroke()

        switch state {
        case .recording:
            // Continuous light = microphone is open.
            NSColor(srgbRed: 1, green: 0.35, blue: 0.31, alpha: 1).setFill()
            capsule(x: 5, width: 54)
        case .transcribing:
            // Broken light = recording stopped and the request is running.
            NSColor(srgbRed: 0.42, green: 0.73, blue: 1, alpha: 1).setFill()
            for x in [11.0, 27.0, 43.0] { capsule(x: x, width: 10) }
        default:
            NSColor(srgbRed: 1, green: 0.76, blue: 0.35, alpha: 1).setFill()
            capsule(x: 27, width: 10)
        }
    }

    private func capsule(x: Double, width: Double) {
        NSBezierPath(roundedRect: NSRect(x: x, y: 2.5, width: width, height: 3), xRadius: 1.5, yRadius: 1.5).fill()
    }
}
