import AppKit
import WebKit

/// Borderless windows normally refuse keyboard focus, which would make the
/// ask box useless, so key status is granted explicitly.
final class KeyPanel: NSPanel {
    var onCancel: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func cancelOperation(_ sender: Any?) { onCancel?() }
}

/// The page draws everything; the web view is a transparent sheet of glass
/// over the desktop. The first click counts even when another app is in
/// front, because a bar that needs two clicks feels broken.
final class BarWebView: WKWebView {
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// The command bar: a pill at the top of the screen with a panel beneath it.
///
/// What is on screen lives in `ui/` (HTML, CSS and JS shared with the Windows
/// app). This class owns the window, the API calls, the recorder and the
/// config, and talks to the page in small JSON messages — see ui/app.js for
/// the list. Nothing here decides how anything looks.
final class PanelController: NSObject, NSWindowDelegate, WKScriptMessageHandler, WKNavigationDelegate {

    private let api: API
    private let recorder: Recorder
    private var config = BarConfig.fallback

    private var window: KeyPanel?
    private var web: BarWebView?
    private var loaded = false
    private var queued: [[String: Any]] = []
    private var pendingExpand = false     // asked for before the page was ready

    private var rows: [String: [[String: Any]]] = [:]   // section id → raw rows
    private var counts: [String: Int] = [:]
    private var countTimer: Timer?
    private var tickTimer: Timer?
    private var dragTimer: Timer?
    private var dragLast = NSPoint.zero
    private var onRight = true            // which edge it is parked against

    // The page reports its own size; the window follows. 600 is the panel
    // plus the room its shadow needs, and the height before the page loads.
    private var size = NSSize(width: 600, height: 86)

    init(api: API, recorder: Recorder) {
        self.api = api
        self.recorder = recorder
        super.init()
    }

    // MARK: - state

    private var panelConfig: PanelConfig { config.panel ?? PanelConfig() }

    private func section(_ id: String) -> PanelSection? {
        panelConfig.sections.first { $0.id == id }
    }

    var isVisible: Bool { window?.isVisible ?? false }

    func toggle() { isVisible ? hide() : show() }

    /// The bar comes back the way it went away: parked, one button wide, with
    /// the panel shut. Opening the panel is a click on the chevron and nothing
    /// else — summoning the bar and asking it a question are separate thoughts,
    /// and a panel that opened by itself was in the way of the first one.
    func show(expanding: Bool = false) {
        guard panelConfig.enabled else {
            toast("The bar is switched off in maestro-bar.json")
            return
        }
        if window == nil { buildWindow() }
        place()
        window?.orderFrontRegardless()
        if expanding { window?.makeKey() }
        startCounts()
        if loaded {
            sendState()
            send(["type": expanding ? "expand" : "fold"])
        } else {
            pendingExpand = expanding
        }
    }

    func hide() {
        countTimer?.invalidate()
        countTimer = nil
        window?.orderOut(nil)
    }

    func update(config: BarConfig) {
        self.config = config
        rows = [:]
        counts = [:]
        window?.sharingType = panelConfig.invisible ? .none : .readOnly
        if loaded { sendState() }
    }

    func recordingChanged() {
        tickTimer?.invalidate()
        tickTimer = nil
        if recorder.isRecording {
            let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.sendRecording() }
            tickTimer = t
            RunLoop.main.add(t, forMode: .common)
        }
        sendRecording()
    }

    // MARK: - the window

    private func buildWindow() {
        let w = KeyPanel(contentRect: NSRect(origin: .zero, size: size),
                         styleMask: [.borderless, .nonactivatingPanel],
                         backing: .buffered, defer: false)
        w.isFloatingPanel = true
        w.level = .floating
        w.hidesOnDeactivate = false
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = false                     // the page draws its own
        w.isMovableByWindowBackground = false   // the page drives the drag
        w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        w.delegate = self
        w.onCancel = { [weak self] in self?.send(["type": "escape"]) }
        // Left out of screen shares and of Maestro's own screen recordings,
        // the way Zoom's overlays are. Config can switch it off.
        w.sharingType = panelConfig.invisible ? .none : .readOnly

        let cfg = WKWebViewConfiguration()
        cfg.userContentController.add(self, name: "maestro")
        cfg.preferences.setValue(true, forKey: "developerExtrasEnabled")
        let web = BarWebView(frame: NSRect(origin: .zero, size: size), configuration: cfg)
        web.setValue(false, forKey: "drawsBackground")
        if #available(macOS 12.0, *) { web.underPageBackgroundColor = .clear }
        web.navigationDelegate = self
        web.autoresizingMask = [.width, .height]
        w.contentView = web

        if let url = PanelController.uiURL() {
            web.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        } else {
            NSLog("MaestroBar: ui/index.html not found; the bar has nothing to show")
        }
        self.web = web
        window = w
    }

    /// The page inside the app, or the working copy on this machine when the
    /// app runs from a checkout — so the UI can be edited without a rebuild.
    private static func uiURL() -> URL? {
        var candidates: [URL] = []
        if let r = Bundle.main.resourceURL { candidates.append(r.appendingPathComponent("ui/index.html")) }
        candidates.append(URL(fileURLWithPath: expand("~/Desktop/MaestroBar/ui/index.html")))
        return candidates.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// The screen the pointer is on, not the one with keyboard focus.
    ///
    /// NSScreen.main is whichever screen holds the focused window, so with two
    /// displays the bar was placed on one and then clamped to the other, and
    /// it hung off the edge. Where the pointer is is both stable and what
    /// someone means by "here".
    private func currentScreen() -> NSScreen? {
        let p = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(p) } ?? NSScreen.main
    }

    private func place() {
        guard let w = window else { return }
        let vf = currentScreen()?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        onRight = UserDefaults.standard.object(forKey: "barOnRight") as? Bool ?? true
        var origin = defaultOrigin(in: vf)
        // The anchor is the corner against the parked edge, not the left one:
        // the window is narrow while folded and wide while open, and only the
        // parked corner is the same point in both.
        if let saved = UserDefaults.standard.string(forKey: "barAnchor") {
            let a = NSPointFromString(saved)
            let onAScreen = NSScreen.screens.contains { $0.visibleFrame.insetBy(dx: -40, dy: -40).contains(a) }
            if onAScreen {
                origin = NSPoint(x: onRight ? a.x - size.width : a.x, y: a.y - size.height)
            }
        }
        w.setFrame(NSRect(origin: origin, size: size), display: true)
    }

    private func defaultOrigin(in vf: NSRect) -> NSPoint {
        // The right edge, level with the middle of the screen: where the strip
        // parked before this, and clear of what is being read.
        NSPoint(x: vf.maxX - size.width, y: vf.midY - size.height / 2)
    }

    /// The page measures itself and the window follows. The parked edge and
    /// the top stay put, so opening the panel grows it downwards and inwards
    /// rather than shifting the pill out from under the pointer.
    private func resize(to newSize: NSSize, stripCentre: CGFloat? = nil) {
        guard let w = window, newSize.height > 0, newSize.width > 0 else { return }
        let vf = (w.screen ?? currentScreen())?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let top = w.frame.maxY
        let right = w.frame.maxX
        size = newSize

        var x = onRight ? right - newSize.width : w.frame.minX
        // Until someone drags it, the strip sits level with the middle of the
        // screen — which is the strip's middle, not the window's: the window
        // is mostly panel once the panel is open.
        let placed = UserDefaults.standard.string(forKey: "barAnchor") != nil
        var y = (placed || stripCentre == nil)
            ? top - newSize.height
            : vf.midY + stripCentre! - newSize.height
        if newSize.width <= vf.width { x = min(max(x, vf.minX), vf.maxX - newSize.width) }
        if newSize.height <= vf.height { y = min(max(y, vf.minY), vf.maxY - newSize.height) }
        w.setFrame(NSRect(x: x, y: y, width: newSize.width, height: newSize.height), display: true)
    }

    /// Dropped anywhere, the bar returns to the nearer edge — the placement
    /// it has always had, and the one that leaves the middle of the screen
    /// free.
    private func snap() {
        guard let w = window else { return }
        let vf = (w.screen ?? currentScreen())?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        var f = w.frame
        onRight = (vf.maxX - f.maxX) <= (f.minX - vf.minX)
        f.origin.x = onRight ? vf.maxX - f.width : vf.minX
        f.origin.y = min(max(f.minY, vf.minY), max(vf.minY, vf.maxY - f.height))
        w.setFrame(f, display: true, animate: true)
        UserDefaults.standard.set(onRight, forKey: "barOnRight")
        UserDefaults.standard.set(NSStringFromPoint(NSPoint(x: onRight ? f.maxX : f.minX, y: f.maxY)),
                                  forKey: "barAnchor")
        send(["type": "edge", "edge": onRight ? "right" : "left"])
    }

    /// The page cannot move the window, so a press on the grip starts this:
    /// the window follows the mouse until the button is released.
    private func startDrag() {
        dragTimer?.invalidate()
        dragLast = NSEvent.mouseLocation
        let t = Timer(timeInterval: 1.0 / 90.0, repeats: true) { [weak self] _ in
            guard let self = self, let w = self.window else { return }
            let p = NSEvent.mouseLocation
            let d = NSPoint(x: p.x - self.dragLast.x, y: p.y - self.dragLast.y)
            self.dragLast = p
            if d.x != 0 || d.y != 0 {
                w.setFrameOrigin(NSPoint(x: w.frame.minX + d.x, y: w.frame.minY + d.y))
            }
            if NSEvent.pressedMouseButtons & 1 == 0 {
                self.dragTimer?.invalidate()
                self.dragTimer = nil
                self.snap()
            }
        }
        dragTimer = t
        RunLoop.main.add(t, forMode: .common)
    }

    // MARK: - talking to the page

    private func send(_ msg: [String: Any]) {
        guard loaded, let web = web,
              let data = try? JSONSerialization.data(withJSONObject: msg),
              let json = String(data: data, encoding: .utf8) else {
            queued.append(msg)
            return
        }
        web.evaluateJavaScript("window.maestro && window.maestro.receive(\(json))", completionHandler: nil)
    }

    private func sendState() {
        let p = panelConfig
        let sections: [[String: Any]] = p.sections.map { s in
            var d: [String: Any] = [
                "id": s.id, "title": s.title, "symbol": s.symbol,
                "hasList": !s.list.isEmpty,
                "actions": s.actions.map { ["label": $0.label, "symbol": $0.symbol] }
            ]
            if let c = s.compose {
                d["compose"] = ["placeholder": c.placeholder, "record": c.record]
            }
            return d
        }
        var msg: [String: Any] = [
            "type": "state",
            "platform": "mac",
            "hotkey": PanelController.pretty(p.hotkey),
            "api": !config.api.isEmpty,
            "edge": onRight ? "right" : "left",
            "sections": sections,
            "records": p.records.map { ["mode": $0.mode, "label": $0.label] },
            "counts": counts,
            "recording": recordingDict()
        ]
        if !p.askPath.isEmpty, !config.api.isEmpty {
            msg["ask"] = ["placeholder": p.askPlaceholder]
        }
        send(msg)
    }

    private func recordingDict() -> [String: Any] {
        ["active": recorder.isRecording, "mode": recorder.mode, "elapsed": recorder.elapsed]
    }

    private func sendRecording() {
        var d = recordingDict()
        d["type"] = "recording"
        send(d)
    }

    private static func pretty(_ spec: [String]) -> String {
        spec.map { k -> String in
            switch k.lowercased() {
            case "cmd", "command": return "⌘"
            case "alt", "opt", "option": return "⌥"
            case "ctrl", "control": return "⌃"
            case "shift": return "⇧"
            default: return k.uppercased()
            }
        }.joined()
    }

    /// An outcome is shown where the click was when the bar is up, and as a
    /// notification when it is not.
    private func say(_ text: String) {
        if isVisible && loaded { send(["type": "toast", "text": text]) } else { toast(text) }
    }

    // MARK: - messages from the page

    func userContentController(_ c: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let m = message.body as? [String: Any], let type = m["type"] as? String else { return }
        switch type {
        case "ready":
            loaded = true
            sendState()
            if pendingExpand { send(["type": "expand"]); pendingExpand = false }
            let pending = queued
            queued = []
            pending.forEach { send($0) }
        case "size":
            if let w = m["width"] as? Double, let h = m["height"] as? Double {
                resize(to: NSSize(width: w, height: h),
                       stripCentre: (m["centre"] as? Double).map { CGFloat($0) })
            }
        case "drag": startDrag()
        case "hide": hide()
        case "focus": window?.makeKey()
        case "open":
            if let id = m["section"] as? String { load(id) }
        case "action":
            if let id = m["section"] as? String, let i = m["index"] as? Int {
                perform(section: id, action: i, rowID: m["id"] as? String)
            }
        case "compose":
            if let id = m["section"] as? String, let text = m["text"] as? String {
                compose(section: id, text: text, rowID: m["id"] as? String)
            }
        case "ask":
            if let text = m["text"] as? String { ask(text) }
        case "record":
            if let mode = m["mode"] as? String {
                recorder.toggle(mode: mode, client: nil, config: config)
            }
        case "open_url":
            // Citations, and nothing else: the page never asks for a bare URL.
            let target = (m["url"] as? String) ?? ""
            if !target.isEmpty, let u = URL(string: target) { NSWorkspace.shared.open(u) }
        case "copy":
            if let text = m["text"] as? String {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            }
        default: break
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        NSLog("MaestroBar: the bar page failed to load: %@", error.localizedDescription)
    }

    // MARK: - counts

    private func startCounts() {
        countTimer?.invalidate()
        let t = Timer(timeInterval: max(20, panelConfig.refreshSeconds), repeats: true) {
            [weak self] _ in self?.refreshCounts()
        }
        countTimer = t
        RunLoop.main.add(t, forMode: .common)
        refreshCounts()
    }

    private func refreshCounts() {
        guard !config.api.isEmpty else { return }
        for s in panelConfig.sections where !s.list.isEmpty {
            api.get(s.list) { [weak self] json, code in
                guard let self = self else { return }
                self.counts[s.id] = (code == 200) ? API.rows(json).count : 0
                self.send(["type": "counts", "counts": self.counts])
            }
        }
    }

    // MARK: - data

    private func load(_ id: String) {
        guard let s = section(id), !s.list.isEmpty else { return }
        guard !config.api.isEmpty else {
            send(["type": "rows", "section": id, "rows": []])
            return
        }
        api.get(s.list) { [weak self] json, code in
            guard let self = self else { return }
            let raw = (code == 200) ? API.rows(json) : []
            self.rows[id] = raw
            self.counts[id] = raw.count
            self.send(["type": "rows", "section": id, "rows": raw.map { self.card($0, s) }])
        }
    }

    /// One row, reduced to the lines the card shows. The mapping comes from
    /// the section's `fields`, so a new endpoint is a config change.
    private func card(_ row: [String: Any], _ s: PanelSection) -> [String: Any] {
        [
            "id": rowID(row) ?? "",
            "title": PanelController.text(row, s.fields.title) ?? "Untitled",
            "subtitle": PanelController.text(row, s.fields.subtitle) ?? "",
            "body": PanelController.text(row, s.fields.body) ?? ""
        ]
    }

    private static func text(_ row: [String: Any], _ keys: [String]) -> String? {
        for k in keys {
            if let s = row[k] as? String,
               !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return s }
            if let n = row[k] as? Int { return String(n) }
        }
        return nil
    }

    private func rowID(_ row: [String: Any]) -> String? {
        for k in ["id", "gmail_id", "action_id", "task_id", "uuid", "key"] {
            if let s = row[k] as? String { return s }
            if let n = row[k] as? Int { return String(n) }
        }
        return nil
    }

    private func row(in sectionID: String, id: String?) -> [String: Any]? {
        guard let id = id else { return nil }
        return rows[sectionID]?.first { rowID($0) == id }
    }

    private func substitute(_ path: String, _ row: [String: Any]) -> String {
        var out = path
        if let id = rowID(row) { out = out.replacingOccurrences(of: "{id}", with: id) }
        for (k, v) in row {
            if let s = v as? String { out = out.replacingOccurrences(of: "{\(k)}", with: s) }
            if let n = v as? Int { out = out.replacingOccurrences(of: "{\(k)}", with: String(n)) }
        }
        return out
    }

    private func perform(section id: String, action i: Int, rowID rid: String?) {
        guard let s = section(id), i >= 0, i < s.actions.count,
              let row = row(in: id, id: rid) else { return }
        let a = s.actions[i]
        guard !a.path.isEmpty else { return }
        // The page has already dropped the card. Keep the cache in step so a
        // second action cannot address a card that is gone.
        if a.advance {
            rows[id]?.removeAll { rowID($0) == rid }
            counts[id] = rows[id]?.count ?? 0
        }
        api.call(a.method, substitute(a.path, row), body: a.body) { [weak self] _, code in
            guard let self = self else { return }
            if (200..<300).contains(code) {
                if !a.toast.isEmpty { self.say(a.toast) }
            } else {
                self.say("\(a.label) failed (\(code))")
                self.load(id)   // the truth comes back from the server
            }
        }
    }

    private func compose(section id: String, text: String, rowID rid: String?) {
        guard let s = section(id), let c = s.compose else { return }
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }

        // Not every destination exists as an endpoint yet. Appending to a file
        // keeps the box useful now, and only the config changes later.
        if c.path.isEmpty {
            guard !c.file.isEmpty else { return }
            let line = "\n## \(ISO8601DateFormatter().string(from: Date()))\n\(clean)\n"
            let path = expand(c.file)
            if let h = FileHandle(forWritingAtPath: path) {
                h.seekToEndOfFile()
                h.write(Data(line.utf8))
                try? h.close()
            } else {
                try? line.write(toFile: path, atomically: true, encoding: .utf8)
            }
            if !c.toast.isEmpty { say(c.toast) }
            return
        }

        var body = [c.field: clean]
        body["section"] = s.id
        var path = c.path
        if let row = row(in: id, id: rid) {
            path = substitute(path, row)
            if let rowid = rowID(row) { body["item_id"] = rowid }
        }
        if path.contains("{") {
            say("That box needs a card open")
            return
        }
        api.post(path, body: body) { [weak self] _, code in
            if (200..<300).contains(code) {
                if !c.toast.isEmpty { self?.say(c.toast) }
            } else {
                self?.say("Could not send (\(code))")
            }
        }
    }

    /// The Ask box goes to the company brain, which answers with citations.
    private func ask(_ text: String) {
        let path = panelConfig.askPath
        guard !path.isEmpty, !config.api.isEmpty else {
            send(["type": "answer_error", "text": "No API is configured."])
            return
        }
        api.post(path, body: ["query": text]) { [weak self] json, code in
            guard let self = self else { return }
            guard (200..<300).contains(code), let d = json as? [String: Any] else {
                let why = code == 0 ? "Maestro did not answer. Check the connection."
                                    : "The brain answered \(code)."
                self.send(["type": "answer_error", "text": why])
                return
            }
            let answer = (d["answer"] as? String) ?? ""
            let cites = (d["citations"] as? [[String: Any]]) ?? []
            self.send(["type": "answer", "text": answer, "citations": cites])
        }
    }
}
