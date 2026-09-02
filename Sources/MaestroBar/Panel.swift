import AppKit

/// Borderless windows normally refuse keyboard focus, which would make the
/// compose box useless, so key status is granted explicitly.
final class KeyPanel: NSPanel {
    var onCancel: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func cancelOperation(_ sender: Any?) { onCancel?() }
}

/// A thin strip of icons parked against the edge of the screen. Clicking an
/// icon opens a small flyout next to it; nothing else is on screen. The strip
/// can be dragged anywhere and snaps back to the nearer edge when released.
final class PanelController: NSObject, NSWindowDelegate {

    private let api: API
    private let recorder: Recorder
    private var config = BarConfig.fallback

    private var strip: KeyPanel?
    private var flyout: KeyPanel?
    private var openIndex: Int?
    private var onRight = true

    private var keepAlive: [Action] = []
    private var dots: [Int: NSView] = [:]
    private var counts: [Int: Int] = [:]
    private var recordButtons: [(NSButton, String)] = []
    private var countTimer: Timer?

    // flyout contents, rebuilt each time one opens
    private var rows: [[String: Any]] = []
    private var index = 0
    private var loading = false
    private var titleLabel = NSTextField(labelWithString: "")
    private var subtitleLabel = NSTextField(labelWithString: "")
    private var counterLabel = NSTextField(labelWithString: "")
    private var bodyView = NSTextView()
    private var input = NSTextField()
    private var micButton: NSButton?

    private let itemSize: CGFloat = 34

    init(api: API, recorder: Recorder) {
        self.api = api
        self.recorder = recorder
        super.init()
    }

    // MARK: - state

    private var panelConfig: PanelConfig { config.panel ?? PanelConfig() }

    private func section(_ i: Int) -> PanelSection? {
        let s = panelConfig.sections
        return (i >= 0 && i < s.count) ? s[i] : nil
    }

    private var current: [String: Any]? {
        (index >= 0 && index < rows.count) ? rows[index] : nil
    }

    var isVisible: Bool { strip?.isVisible ?? false }

    func toggle() { isVisible ? hide() : show() }

    func show() {
        guard panelConfig.enabled else {
            toast("The sidebar is switched off in maestro-bar.json")
            return
        }
        if strip == nil { buildStrip() }
        placeStrip()
        strip?.orderFrontRegardless()
        startCounts()
    }

    func hide() {
        closeFlyout()
        countTimer?.invalidate()
        countTimer = nil
        strip?.orderOut(nil)
    }

    func update(config: BarConfig) {
        self.config = config
        closeFlyout()
        counts = [:]
        if strip != nil {
            let wasVisible = strip?.isVisible ?? false
            strip?.orderOut(nil)
            strip = nil
            dots = [:]
            recordButtons = []
            if wasVisible { show() }
        }
    }

    func recordingChanged() {
        // Only the icon whose mode is actually running turns red.
        for (b, mode) in recordButtons {
            let live = recorder.isRecording && recorder.mode == mode
            b.contentTintColor = live ? .systemRed : .secondaryLabelColor
            if live { b.toolTip = "Stop recording" }
        }
        micButton?.contentTintColor = recorder.isRecording ? .systemRed : .secondaryLabelColor
    }

    // MARK: - the strip

    private func buildStrip() {
        let p = panelConfig
        let w = CGFloat(p.width)
        let count = p.sections.count + p.records.count
        let height = 14 + 6 + CGFloat(count) * itemSize + CGFloat(max(0, count - 1)) * 4 + 10

        let window = KeyPanel(contentRect: NSRect(x: 0, y: 0, width: w, height: height),
                              styleMask: [.borderless, .nonactivatingPanel],
                              backing: .buffered, defer: false)
        window.isFloatingPanel = true
        window.level = .floating
        window.hidesOnDeactivate = false
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.isMovableByWindowBackground = true
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.delegate = self
        window.onCancel = { [weak self] in self?.hide() }

        let blur = NSVisualEffectView()
        blur.material = .hudWindow
        blur.blendingMode = .behindWindow
        blur.state = .active
        blur.wantsLayer = true
        blur.layer?.cornerRadius = 12
        blur.layer?.masksToBounds = true
        window.contentView = blur

        // a grip, so it is obvious the strip can be dragged
        let grip = NSView()
        grip.translatesAutoresizingMaskIntoConstraints = false
        grip.wantsLayer = true
        grip.layer?.backgroundColor = NSColor.tertiaryLabelColor.cgColor
        grip.layer?.cornerRadius = 1.5

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.spacing = 4
        stack.alignment = .centerX
        stack.translatesAutoresizingMaskIntoConstraints = false

        keepAlive.removeAll()
        dots = [:]

        for (i, s) in p.sections.enumerated() {
            let holder = iconHolder(symbol: s.symbol, tip: s.title, index: i) { [weak self] in
                self?.toggleFlyout(i)
            }
            stack.addArrangedSubview(holder)
        }
        recordButtons = []
        for r in p.records {
            let holder = iconHolder(symbol: r.symbol, tip: r.label, index: nil) { [weak self] in
                guard let self = self else { return }
                self.recorder.toggle(mode: r.mode, client: nil, config: self.config)
            }
            if let b = holder.subviews.compactMap({ $0 as? NSButton }).first {
                recordButtons.append((b, r.mode))
            }
            stack.addArrangedSubview(holder)
        }

        blur.addSubview(grip)
        blur.addSubview(stack)
        NSLayoutConstraint.activate([
            grip.topAnchor.constraint(equalTo: blur.topAnchor, constant: 6),
            grip.centerXAnchor.constraint(equalTo: blur.centerXAnchor),
            grip.widthAnchor.constraint(equalToConstant: 16),
            grip.heightAnchor.constraint(equalToConstant: 3),

            stack.topAnchor.constraint(equalTo: grip.bottomAnchor, constant: 6),
            stack.centerXAnchor.constraint(equalTo: blur.centerXAnchor)
        ])

        strip = window
        recordingChanged()
        refreshCounts()
    }

    /// One icon, with a dot in the corner when its list has something in it.
    private func iconHolder(symbol: String, tip: String, index i: Int?,
                            run: @escaping () -> Void) -> NSView {
        let holder = NSView()
        holder.translatesAutoresizingMaskIntoConstraints = false

        let b = button(symbol: symbol, fallback: String(tip.prefix(1)), tip: tip, run: run)
        b.imageScaling = .scaleProportionallyUpOrDown
        holder.addSubview(b)

        let dot = NSView()
        dot.translatesAutoresizingMaskIntoConstraints = false
        dot.wantsLayer = true
        dot.layer?.backgroundColor = NSColor.systemRed.cgColor
        dot.layer?.cornerRadius = 3.5
        dot.isHidden = true
        holder.addSubview(dot)
        if let i = i { dots[i] = dot }

        NSLayoutConstraint.activate([
            holder.widthAnchor.constraint(equalToConstant: itemSize),
            holder.heightAnchor.constraint(equalToConstant: itemSize),
            b.centerXAnchor.constraint(equalTo: holder.centerXAnchor),
            b.centerYAnchor.constraint(equalTo: holder.centerYAnchor),
            b.widthAnchor.constraint(equalToConstant: 26),
            b.heightAnchor.constraint(equalToConstant: 26),
            dot.widthAnchor.constraint(equalToConstant: 7),
            dot.heightAnchor.constraint(equalToConstant: 7),
            dot.trailingAnchor.constraint(equalTo: holder.trailingAnchor, constant: -2),
            dot.topAnchor.constraint(equalTo: holder.topAnchor, constant: 2)
        ])
        return holder
    }

    private func placeStrip() {
        guard let w = strip else { return }
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        if let saved = UserDefaults.standard.string(forKey: "stripOrigin") {
            let pt = NSPointFromString(saved)
            if NSScreen.screens.contains(where: { $0.visibleFrame.insetBy(dx: -2, dy: -2).contains(pt) }) {
                w.setFrameOrigin(pt)
                onRight = pt.x > screen.midX
                return
            }
        }
        onRight = panelConfig.edge != "left"
        let x = onRight ? screen.maxX - w.frame.width - 8 : screen.minX + 8
        let y = screen.midY - w.frame.height / 2
        w.setFrameOrigin(NSPoint(x: x, y: y))
    }

    /// Dropped anywhere, the strip returns to the nearer edge.
    func windowDidMove(_ note: Notification) {
        guard let w = note.object as? NSWindow, w === strip else { return }
        NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(snap), object: nil)
        perform(#selector(snap), with: nil, afterDelay: 0.35)
    }

    @objc private func snap() {
        guard let w = strip else { return }
        let vf = (w.screen ?? NSScreen.main)?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        var f = w.frame
        let toLeft = abs(f.minX - vf.minX)
        let toRight = abs(vf.maxX - f.maxX)
        onRight = toRight <= toLeft
        f.origin.x = onRight ? vf.maxX - f.width - 8 : vf.minX + 8
        f.origin.y = min(max(f.minY, vf.minY + 8), vf.maxY - f.height - 8)
        w.setFrame(f, display: true, animate: true)
        UserDefaults.standard.set(NSStringFromPoint(f.origin), forKey: "stripOrigin")
        placeFlyout()
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
        for (i, s) in panelConfig.sections.enumerated() where !s.list.isEmpty {
            api.get(s.list) { [weak self] json, code in
                guard let self = self else { return }
                let n = (code == 200) ? API.rows(json).count : 0
                self.counts[i] = n
                self.dots[i]?.isHidden = (n == 0)
            }
        }
    }

    // MARK: - the flyout

    private func toggleFlyout(_ i: Int) {
        if openIndex == i {
            closeFlyout()
        } else {
            closeFlyout()
            openFlyout(i)
        }
    }

    private func closeFlyout() {
        flyout?.orderOut(nil)
        flyout = nil
        openIndex = nil
        micButton = nil
        rows = []
        index = 0
    }

    private func openFlyout(_ i: Int) {
        guard let s = section(i) else { return }
        openIndex = i
        rows = []
        index = 0
        loading = !s.list.isEmpty

        let width = CGFloat(panelConfig.flyoutWidth)
        let height: CGFloat = s.list.isEmpty ? 96 : (s.compose != nil ? 240 : 205)

        let window = KeyPanel(contentRect: NSRect(x: 0, y: 0, width: width, height: height),
                              styleMask: [.borderless, .nonactivatingPanel],
                              backing: .buffered, defer: false)
        window.isFloatingPanel = true
        window.level = .floating
        window.hidesOnDeactivate = false
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.onCancel = { [weak self] in self?.closeFlyout() }

        let blur = NSVisualEffectView()
        blur.material = .hudWindow
        blur.blendingMode = .behindWindow
        blur.state = .active
        blur.wantsLayer = true
        blur.layer?.cornerRadius = 12
        blur.layer?.masksToBounds = true
        window.contentView = blur

        let content = s.list.isEmpty ? composeView(s) : cardView(s, width: width)
        content.translatesAutoresizingMaskIntoConstraints = false
        blur.addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: blur.topAnchor, constant: 10),
            content.bottomAnchor.constraint(equalTo: blur.bottomAnchor, constant: -10),
            content.leadingAnchor.constraint(equalTo: blur.leadingAnchor, constant: 12),
            content.trailingAnchor.constraint(equalTo: blur.trailingAnchor, constant: -12)
        ])

        flyout = window
        placeFlyout()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        if s.compose != nil || s.list.isEmpty { window.makeFirstResponder(input) }
        recordingChanged()
        render()
        if !s.list.isEmpty { load(s) }
    }

    private func placeFlyout() {
        guard let f = flyout, let s = strip else { return }
        let vf = (s.screen ?? NSScreen.main)?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let x = onRight ? s.frame.minX - f.frame.width - 8 : s.frame.maxX + 8
        var y = s.frame.maxY - f.frame.height
        y = min(max(y, vf.minY + 8), vf.maxY - f.frame.height - 8)
        f.setFrameOrigin(NSPoint(x: min(max(x, vf.minX + 8), vf.maxX - f.frame.width - 8), y: y))
    }

    private func composeView(_ s: PanelSection) -> NSView {
        let c = s.compose ?? PanelCompose()

        input = NSTextField()
        input.isBezeled = false
        input.drawsBackground = false
        input.focusRingType = .none
        input.font = .systemFont(ofSize: 12)
        input.placeholderString = c.placeholder
        let enter = Action { [weak self] in self?.send() }
        keepAlive.append(enter)
        input.target = enter
        input.action = #selector(Action.fire)

        let buttons = NSStackView()
        buttons.orientation = .horizontal
        buttons.spacing = 6
        let spacer = NSView()
        spacer.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        buttons.addArrangedSubview(spacer)
        if c.record {
            let mic = button(symbol: "mic", fallback: "mic", tip: "Record") { [weak self] in
                guard let self = self else { return }
                self.recorder.toggle(mode: "audio", client: nil, config: self.config)
            }
            micButton = mic
            buttons.addArrangedSubview(mic)
        }
        buttons.addArrangedSubview(button(symbol: "arrow.up.circle.fill",
                                          fallback: "Send", tip: "Send") {
            [weak self] in self?.send()
        })

        let head = NSTextField(labelWithString: s.title)
        head.font = .systemFont(ofSize: 11, weight: .medium)
        head.textColor = .secondaryLabelColor

        let stack = NSStackView(views: [head, input, buttons])
        stack.orientation = .vertical
        stack.spacing = 6
        stack.alignment = .leading
        NSLayoutConstraint.activate([
            input.trailingAnchor.constraint(equalTo: stack.trailingAnchor),
            buttons.trailingAnchor.constraint(equalTo: stack.trailingAnchor)
        ])
        return stack
    }

    private func cardView(_ s: PanelSection, width: CGFloat) -> NSView {
        titleLabel = NSTextField(labelWithString: "")
        titleLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.maximumNumberOfLines = 2
        titleLabel.preferredMaxLayoutWidth = width - 24

        subtitleLabel = NSTextField(labelWithString: "")
        subtitleLabel.font = .systemFont(ofSize: 10)
        subtitleLabel.textColor = .secondaryLabelColor
        subtitleLabel.lineBreakMode = .byTruncatingTail
        subtitleLabel.maximumNumberOfLines = 1

        counterLabel = NSTextField(labelWithString: "")
        counterLabel.font = .systemFont(ofSize: 10)
        counterLabel.textColor = .tertiaryLabelColor

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        bodyView = NSTextView()
        bodyView.isEditable = false
        bodyView.isSelectable = true
        bodyView.drawsBackground = false
        bodyView.font = .systemFont(ofSize: 11)
        bodyView.textColor = .labelColor
        bodyView.textContainerInset = NSSize(width: 0, height: 2)
        bodyView.isVerticallyResizable = true
        bodyView.isHorizontallyResizable = false
        bodyView.autoresizingMask = [.width]
        bodyView.frame = NSRect(x: 0, y: 0, width: width - 24, height: 80)
        bodyView.minSize = NSSize(width: 0, height: 0)
        bodyView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                  height: CGFloat.greatestFiniteMagnitude)
        bodyView.textContainer?.widthTracksTextView = true
        bodyView.textContainer?.containerSize = NSSize(width: 0,
                                                       height: CGFloat.greatestFiniteMagnitude)
        scroll.documentView = bodyView
        scroll.setContentHuggingPriority(.defaultLow, for: .vertical)

        let bar = NSStackView()
        bar.orientation = .horizontal
        bar.spacing = 2
        bar.alignment = .centerY
        bar.addArrangedSubview(button(symbol: "chevron.left", fallback: "<", tip: "Previous") {
            [weak self] in self?.step(-1)
        })
        let actions = s.actions
        if let first = actions.first {
            let b = button(symbol: first.symbol.isEmpty ? "checkmark" : first.symbol,
                           fallback: first.label, tip: first.label) { [weak self] in
                self?.perform(first)
            }
            b.contentTintColor = .labelColor
            bar.addArrangedSubview(b)
        }
        if actions.count > 1 {
            let rest = Array(actions.dropFirst())
            bar.addArrangedSubview(button(symbol: "ellipsis", fallback: "...", tip: "More") {
                [weak self] in
                let menu = NSMenu()
                menu.autoenablesItems = false
                for a in rest { menu.addItem(menuItem(a.label) { [weak self] in self?.perform(a) }) }
                menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
            })
        }
        bar.addArrangedSubview(button(symbol: "chevron.right", fallback: ">", tip: "Next") {
            [weak self] in self?.step(1)
        })
        let spacer = NSView()
        spacer.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        bar.addArrangedSubview(spacer)
        bar.addArrangedSubview(counterLabel)

        var views: [NSView] = [titleLabel, subtitleLabel, scroll, bar]

        // A section may carry its own compose box, as Review does: what is
        // typed there is an instruction about the card, not a reply to anyone.
        if let c = s.compose {
            input = NSTextField()
            input.isBezeled = false
            input.drawsBackground = false
            input.focusRingType = .none
            input.font = .systemFont(ofSize: 11)
            input.placeholderString = c.placeholder
            let enter = Action { [weak self] in self?.send() }
            keepAlive.append(enter)
            input.target = enter
            input.action = #selector(Action.fire)
            views.append(input)
        }

        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.spacing = 5
        stack.alignment = .leading
        NSLayoutConstraint.activate([
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: stack.trailingAnchor),
            subtitleLabel.trailingAnchor.constraint(lessThanOrEqualTo: stack.trailingAnchor),
            scroll.leadingAnchor.constraint(equalTo: stack.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: stack.trailingAnchor),
            bar.leadingAnchor.constraint(equalTo: stack.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: stack.trailingAnchor),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 60)
        ])
        if s.compose != nil {
            NSLayoutConstraint.activate([
                input.leadingAnchor.constraint(equalTo: stack.leadingAnchor),
                input.trailingAnchor.constraint(equalTo: stack.trailingAnchor)
            ])
        }
        return stack
    }

    private func button(symbol: String, fallback: String, tip: String,
                        run: @escaping () -> Void) -> NSButton {
        let a = Action(run)
        keepAlive.append(a)
        let b = NSButton(title: fallback, target: a, action: #selector(Action.fire))
        b.translatesAutoresizingMaskIntoConstraints = false
        if !symbol.isEmpty,
           let img = NSImage(systemSymbolName: symbol, accessibilityDescription: tip) {
            b.image = img
            b.imagePosition = .imageOnly
            b.title = ""
        }
        b.isBordered = false
        b.bezelStyle = .texturedRounded
        b.toolTip = tip
        b.contentTintColor = .secondaryLabelColor
        b.font = .systemFont(ofSize: 11)
        return b
    }

    // MARK: - data

    private func load(_ s: PanelSection) {
        guard !config.api.isEmpty else { loading = false; render(); return }
        api.get(s.list) { [weak self] json, code in
            guard let self = self else { return }
            self.loading = false
            self.rows = (code == 200) ? API.rows(json) : []
            self.index = 0
            if let i = self.openIndex {
                self.counts[i] = self.rows.count
                self.dots[i]?.isHidden = self.rows.isEmpty
            }
            self.render()
        }
    }

    private func step(_ delta: Int) {
        guard !rows.isEmpty else { return }
        index = max(0, min(rows.count - 1, index + delta))
        render()
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

    private func substitute(_ path: String, _ row: [String: Any]) -> String {
        var out = path
        if let id = rowID(row) { out = out.replacingOccurrences(of: "{id}", with: id) }
        for (k, v) in row {
            if let s = v as? String { out = out.replacingOccurrences(of: "{\(k)}", with: s) }
            if let n = v as? Int { out = out.replacingOccurrences(of: "{\(k)}", with: String(n)) }
        }
        return out
    }

    private func perform(_ a: PanelAction) {
        guard let row = current, !a.path.isEmpty else { return }
        api.call(a.method, substitute(a.path, row), body: a.body) { [weak self] _, code in
            guard let self = self else { return }
            if (200..<300).contains(code) {
                if !a.toast.isEmpty { toast(a.toast) }
            } else {
                toast("\(a.label) failed (\(code))")
                if let i = self.openIndex, let s = self.section(i) { self.load(s) }
            }
        }
        if a.advance {
            // Optimistic: the card leaves at once and a failure reloads the
            // list. Waiting for the round trip makes triage feel broken.
            rows.remove(at: index)
            if index >= rows.count { index = max(0, rows.count - 1) }
            if let i = openIndex {
                counts[i] = rows.count
                dots[i]?.isHidden = rows.isEmpty
            }
            render()
        }
    }

    private func send() {
        guard let i = openIndex, let s = section(i), let c = s.compose else { return }
        let text = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        // Not every destination exists as an endpoint yet. Appending to a file
        // keeps the box useful now, and only the config changes later.
        if c.path.isEmpty {
            guard !c.file.isEmpty else { return }
            input.stringValue = ""
            let line = "\n## \(ISO8601DateFormatter().string(from: Date()))\n\(text)\n"
            let path = expand(c.file)
            if let h = FileHandle(forWritingAtPath: path) {
                h.seekToEndOfFile()
                h.write(Data(line.utf8))
                try? h.close()
            } else {
                try? line.write(toFile: path, atomically: true, encoding: .utf8)
            }
            if !c.toast.isEmpty { toast(c.toast) }
            return
        }

        var body = [c.field: text]
        body["section"] = s.id
        var path = c.path
        if let row = current {
            path = substitute(path, row)
            if let id = rowID(row) { body["item_id"] = id }
        }
        if path.contains("{") {
            toast("That box needs a card open")
            return
        }
        input.stringValue = ""
        api.post(path, body: body) { _, code in
            if (200..<300).contains(code) {
                if !c.toast.isEmpty { toast(c.toast) }
            } else {
                toast("Could not send (\(code))")
            }
        }
    }

    private func render() {
        guard let i = openIndex, let s = section(i), !s.list.isEmpty else { return }
        if let row = current {
            titleLabel.stringValue = PanelController.text(row, s.fields.title) ?? "Untitled"
            subtitleLabel.stringValue = PanelController.text(row, s.fields.subtitle) ?? ""
            bodyView.string = PanelController.text(row, s.fields.body) ?? ""
            counterLabel.stringValue = "\(index + 1) of \(rows.count)"
        } else {
            titleLabel.stringValue = loading ? "Loading" : "Nothing waiting"
            subtitleLabel.stringValue = ""
            bodyView.string = config.api.isEmpty ? "No API is configured." : ""
            counterLabel.stringValue = ""
        }
        subtitleLabel.isHidden = subtitleLabel.stringValue.isEmpty
    }
}
