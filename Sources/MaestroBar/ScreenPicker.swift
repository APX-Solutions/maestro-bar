import AppKit
import CoreGraphics

/// Which display a screen recording takes, asked every time there is more than
/// one.
///
/// `screencapture -v` with no `-D` records the MAIN display — the one with the
/// menu bar — wherever the work actually is, so with two screens it sometimes
/// recorded the wrong one. Now each screen dims and says "Record this screen";
/// a click on one picks it. Esc or a right-click is "never mind".
///
/// The answer is the number `screencapture -D` takes: 1-based, in
/// CGGetActiveDisplayList order, looked up by display ID rather than assumed to
/// match NSScreen.screens, which is ordered by a different rule.
final class ScreenPicker {
    private static var current: ScreenPicker?

    private var windows: [PickerWindow] = []
    private var done: ((Int?) -> Void)?

    /// `done` gets the `-D` number, or nil when the person cancelled.
    static func pick(_ done: @escaping (Int?) -> Void) {
        current?.finish(nil)
        let p = ScreenPicker()
        current = p
        p.done = done
        p.show()
    }

    private func show() {
        for (i, screen) in NSScreen.screens.enumerated() {
            let w = PickerWindow(contentRect: screen.frame, styleMask: .borderless,
                                 backing: .buffered, defer: false)
            w.level = .screenSaver
            w.isOpaque = false
            w.backgroundColor = .clear
            w.hasShadow = false
            w.isReleasedWhenClosed = false
            w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
            w.setFrame(screen.frame, display: false)
            w.contentView = PickerView(number: i + 1)
            w.onPick = { [weak self] in self?.finish(screencaptureDisplay(for: screen) ?? 1) }
            w.onCancel = { [weak self] in self?.finish(nil) }
            windows.append(w)
            w.orderFrontRegardless()
        }
        // A menu-bar app is not active by default, and an inactive app gets no
        // keys: without this Esc would go to whatever was in front.
        NSApp.activate(ignoringOtherApps: true)
        windows.first?.makeKey()
    }

    private func finish(_ display: Int?) {
        guard let d = done else { return }
        done = nil
        windows.forEach { $0.orderOut(nil) }
        windows.removeAll()
        ScreenPicker.current = nil
        d(display)
    }
}

/// The `-D` number for a screen: its position, 1-based, in the active display
/// list, which is the order screencapture counts in.
func screencaptureDisplay(for screen: NSScreen) -> Int? {
    guard let id = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")]
                    as? NSNumber)?.uint32Value else { return nil }
    var count: UInt32 = 0
    guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return nil }
    var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
    guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return nil }
    return ids.firstIndex(of: id).map { $0 + 1 }
}

/// One screen's overlay. Borderless windows cannot take keys unless told they
/// can, and Esc has to reach one of them — as KeyPanel does for the bar.
private final class PickerWindow: NSWindow {
    var onPick: (() -> Void)?
    var onCancel: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override func mouseDown(with event: NSEvent) { onPick?() }
    override func rightMouseDown(with event: NSEvent) { onCancel?() }
    override func cancelOperation(_ sender: Any?) { onCancel?() }
}

/// Dimmed, with the label in the middle. Brighter with an outline while the
/// pointer is on it, so it is plain which screen a click takes.
private final class PickerView: NSView {
    private let number: Int
    private var hover = false

    init(number: Int) {
        self.number = number
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) { hover = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hover = false; needsDisplay = true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
    // The first click picks, even when another app was in front a moment ago.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(hover ? 0.28 : 0.6).setFill()
        bounds.fill()
        if hover {
            let ring = NSBezierPath(rect: bounds.insetBy(dx: 3, dy: 3))
            ring.lineWidth = 6
            NSColor.systemBlue.setStroke()
            ring.stroke()
        }

        let box = NSRect(x: bounds.midX - 210, y: bounds.midY - 75, width: 420, height: 150)
        NSColor(calibratedRed: 0.11, green: 0.12, blue: 0.14, alpha: 0.92).setFill()
        NSBezierPath(roundedRect: box, xRadius: 16, yRadius: 16).fill()

        let centred = NSMutableParagraphStyle()
        centred.alignment = .center
        let title = NSAttributedString(string: "Record this screen", attributes: [
            .font: NSFont.systemFont(ofSize: 30, weight: .bold),
            .foregroundColor: NSColor.white,
            .paragraphStyle: centred,
        ])
        let sub = NSAttributedString(string: "Display \(number)  ·  Esc to cancel", attributes: [
            .font: NSFont.systemFont(ofSize: 18),
            .foregroundColor: NSColor.white.withAlphaComponent(0.67),
            .paragraphStyle: centred,
        ])
        title.draw(in: NSRect(x: box.minX, y: box.midY + 2, width: box.width, height: 40))
        sub.draw(in: NSRect(x: box.minX, y: box.midY - 44, width: box.width, height: 26))
    }
}
