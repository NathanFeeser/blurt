import AppKit

/// A small non-activating panel that shows what the app is doing.
///
/// Dictation is modeless and invisible by nature — you hold a key while looking
/// at another app. Without feedback the two failure modes ("it isn't listening"
/// and "it's still thinking") are indistinguishable from each other and from a
/// crash. This is the cheapest fix for both.
@MainActor
final class RecordingOverlay {
    enum State {
        case recording
        /// Key released, still listening. Needs its own wording: without it,
        /// "Listening…" with no key held is indistinguishable from a stuck app.
        case handsFree
        case transcribing
        case error(String)
    }

    private var panel: NSPanel?
    private let label = NSTextField(labelWithString: "")
    private let meter = LevelView()

    func show(_ state: State) {
        let panel = panel ?? makePanel()
        self.panel = panel

        switch state {
        case .recording:
            label.stringValue = "Listening…"
            label.textColor = .labelColor
            meter.isHidden = false
        case .handsFree:
            label.stringValue = "Hands-free — tap to finish"
            label.textColor = .labelColor
            meter.isHidden = false
        case .transcribing:
            label.stringValue = "Transcribing…"
            label.textColor = .secondaryLabelColor
            meter.isHidden = true
        case .error(let message):
            label.stringValue = message
            label.textColor = .systemRed
            meter.isHidden = true
        }

        reposition(panel)
        // orderFrontRegardless: the panel must appear without stealing focus
        // from whatever the user is typing into.
        panel.orderFrontRegardless()
    }

    func update(level: Float) {
        meter.level = CGFloat(min(1, level * 4))  // speech rarely exceeds ~0.25 RMS
    }

    func hide() {
        panel?.orderOut(nil)
    }

    func flashError(_ message: String, seconds: TimeInterval = 3) {
        show(.error(message))
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(seconds))
            hide()
        }
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 220, height: 44),
            // .nonactivatingPanel is the load-bearing flag: without it, showing
            // the overlay pulls focus and the paste lands in the wrong app.
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        let background = NSVisualEffectView(frame: panel.contentView!.bounds)
        background.autoresizingMask = [.width, .height]
        background.material = .hudWindow
        background.blendingMode = .behindWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 12
        background.layer?.masksToBounds = true

        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.frame = NSRect(x: 14, y: 23, width: 192, height: 16)
        label.autoresizingMask = [.width]

        meter.frame = NSRect(x: 14, y: 12, width: 192, height: 6)
        meter.autoresizingMask = [.width]

        background.addSubview(label)
        background.addSubview(meter)
        panel.contentView = background
        return panel
    }

    private func reposition(_ panel: NSPanel) {
        // Bottom-centre of whichever screen has the mouse, so the overlay follows
        // the user across displays instead of pinning to the primary one.
        let mouse = NSEvent.mouseLocation
        let screen =
            NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        guard let frame = screen?.visibleFrame else { return }
        let size = panel.frame.size
        panel.setFrameOrigin(
            NSPoint(
                x: frame.midX - size.width / 2,
                y: frame.minY + 80
            ))
    }
}

/// A minimal level meter. Not a waveform — the only question it needs to answer
/// is "is the microphone hearing me at all".
private final class LevelView: NSView {
    var level: CGFloat = 0 {
        didSet { needsDisplay = true }
    }

    override func draw(_ dirtyRect: NSRect) {
        let track = NSBezierPath(roundedRect: bounds, xRadius: 3, yRadius: 3)
        NSColor.labelColor.withAlphaComponent(0.15).setFill()
        track.fill()

        guard level > 0.01 else { return }
        let filled = NSRect(
            x: 0, y: 0, width: max(6, bounds.width * level), height: bounds.height)
        let bar = NSBezierPath(roundedRect: filled, xRadius: 3, yRadius: 3)
        NSColor.controlAccentColor.setFill()
        bar.fill()
    }
}
