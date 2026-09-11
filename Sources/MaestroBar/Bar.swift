import AppKit

/// Menu items carry their own action, so the menu can be rebuilt from
/// configuration without inventing a selector for every possible command.
/// NSMenuItem holds its target weakly, so the action object is kept alive
/// by the item's representedObject.
final class Action: NSObject {
    private let run: () -> Void
    init(_ run: @escaping () -> Void) { self.run = run }
    // A copy of the closure is taken first: an action may rebuild the very
    // menu or panel that owns it, and the owner must not be freed mid call.
    @objc func fire() {
        let r = run
        r()
    }
}

func menuItem(_ title: String, key: String = "", _ run: @escaping () -> Void) -> NSMenuItem {
    let action = Action(run)
    let item = NSMenuItem(title: title, action: #selector(Action.fire), keyEquivalent: key)
    item.target = action
    item.representedObject = action
    return item
}

/// A plain alert. `copy` adds a button that puts a command on the clipboard,
/// for the one case the app cannot fix itself: installing ffmpeg.
func alert(_ title: String, _ body: String, copy: String? = nil,
           openSettings: String? = nil) {
    let a = NSAlert()
    a.messageText = title
    a.informativeText = body
    // The action button first, so return triggers the useful thing rather
    // than dismissing. Telling someone where a setting lives and making them
    // walk there is a worse answer than taking them to it.
    if openSettings != nil { a.addButton(withTitle: "Open Settings") }
    a.addButton(withTitle: "OK")
    if copy != nil { a.addButton(withTitle: "Copy command") }
    NSApp.activate(ignoringOtherApps: true)
    let r = a.runModal()
    if let pane = openSettings, r == .alertFirstButtonReturn {
        NSWorkspace.shared.open(URL(string: pane)!)
        return
    }
    let copyButton: NSApplication.ModalResponse =
        openSettings == nil ? .alertSecondButtonReturn : .alertThirdButtonReturn
    if r == copyButton, let c = copy {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(c, forType: .string)
    }
}

/// The token is typed into a secure field and written straight to the keychain.
/// It never reaches a file, a shell command, or the process list.
func askForToken(service: String) {
    let a = NSAlert()
    a.messageText = "Maestro API token"
    a.informativeText = "Paste the token you were given. It is kept in your "
        + "login keychain, never in a file."
    let field = EditableSecureTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
    a.accessoryView = field
    a.addButton(withTitle: "Save")
    a.addButton(withTitle: "Cancel")
    NSApp.activate(ignoringOtherApps: true)
    a.window.initialFirstResponder = field
    guard a.runModal() == .alertFirstButtonReturn else { return }
    let value = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !value.isEmpty else { return }
    toast(Keychain.write(service: service, value: value)
          ? "Token saved" : "Could not save the token")
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private var config = BarConfig.fallback
    private var configSource = ""
    private let recorder = Recorder()
    private var api = API(base: "", tokenService: "maestro-token")
    private lazy var panel = PanelController(api: api, recorder: recorder)

    private var hotkeys: [HotKey] = []
    private var badgeTimer: Timer?
    private var tickTimer: Timer?
    private var badgeCount: Int?
    private var clients: [Client] = []
    private var clientsRequested = false

    func applicationDidFinishLaunching(_ note: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false      // the delegate decides what is clickable
        statusItem.menu = menu

        recorder.onChange = { [weak self] in self?.stateChanged() }
        BarConfig.installDefaultIfMissing()
        // Runs before the config is read, so an upgraded install picks up the
        // corrected command on this launch rather than the next one.
        BarConfig.migrateStaleAfterRecord()
        reload()
        // The panel is the reason for the hot key; open it once on first launch
        // so the permission prompts and the layout are seen straight away.
        if config.panel?.enabled ?? false, !UserDefaults.standard.bool(forKey: "seenSidebar") {
            UserDefaults.standard.set(true, forKey: "seenSidebar")
            panel.show(expanding: false)
        }
        // Puts the bar on screen at launch, for trying a build without
        // reaching for the hot key: MAESTRO_SHOW=1 parks it the way a normal
        // start does, MAESTRO_SHOW=open the way the hot key does.
        switch ProcessInfo.processInfo.environment["MAESTRO_SHOW"] {
        case "1": panel.show(expanding: false)
        case "open": panel.show(expanding: true)
        default: break
        }
    }

    // MARK: - configuration

    private func reload() {
        let (c, src) = BarConfig.load()
        config = c
        configSource = src
        api.update(base: c.api, tokenService: c.tokenService)

        panel.update(config: c)

        hotkeys.removeAll()                // releasing a HotKey unregisters it
        if let pc = c.panel, pc.enabled {
            if let hk = HotKey(spec: pc.hotkey, handler: { [weak self] in self?.panel.toggle() }) {
                hotkeys.append(hk)
            } else {
                NSLog("MaestroBar: could not register panel hotkey %@", pc.hotkey.joined(separator: "+"))
            }
        }
        for item in c.items where item.type == "record" {
            guard let spec = item.hotkey, let mode = item.mode else { continue }
            if let hk = HotKey(spec: spec, handler: { [weak self] in
                guard let self = self else { return }
                self.recorder.toggle(mode: mode, client: nil, config: self.config)
            }) {
                hotkeys.append(hk)
            } else {
                NSLog("MaestroBar: could not register hotkey %@", spec.joined(separator: "+"))
            }
        }

        badgeTimer?.invalidate()
        badgeTimer = nil
        badgeCount = nil
        if let b = c.badge, b.enabled, !c.api.isEmpty {
            let t = Timer(timeInterval: max(10, b.refreshSeconds), repeats: true) { [weak self] _ in
                self?.refreshBadge()
            }
            badgeTimer = t
            RunLoop.main.add(t, forMode: .common)
            refreshBadge()
        }

        clients = []
        clientsRequested = false
        if c.items.contains(where: { $0.type == "clients" }) { loadClients() }
        paint()
    }

    private func refreshBadge() {
        guard let b = config.badge, b.enabled else { return }
        api.get(b.path) { [weak self] json, code in
            guard let self = self else { return }
            self.badgeCount = (code == 200) ? API.int(json, field: b.field) : nil
            self.paint()
        }
    }

    private func loadClients() {
        guard !config.api.isEmpty else { return }
        clientsRequested = true
        api.get(config.clientsPath) { [weak self] json, code in
            guard let self = self else { return }
            if code == 200 { self.clients = API.clients(json) }
        }
    }

    // MARK: - the title in the menu bar

    private func stateChanged() {
        tickTimer?.invalidate()
        tickTimer = nil
        if recorder.isRecording {
            let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.paint() }
            tickTimer = t
            RunLoop.main.add(t, forMode: .common)
        }
        panel.recordingChanged()
        paint()
    }

    private func paint() {
        guard let button = statusItem.button else { return }
        let font = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        if recorder.isRecording {
            button.attributedTitle = NSAttributedString(
                string: "● " + recorder.elapsed,
                attributes: [.font: font, .foregroundColor: NSColor.systemRed])
        } else {
            let text = (badgeCount ?? 0) > 0 ? "\(config.titleIdle) \(badgeCount!)" : config.titleIdle
            button.attributedTitle = NSAttributedString(
                string: text,
                attributes: [.font: font, .foregroundColor: NSColor.labelColor])
        }
    }

    /// One place that answers "why is this not working", so nobody has to
    /// guess which of four things is missing.
    private func checkSetup() {
        var lines: [String] = []
        lines.append("Config: \(configSource)")
        lines.append("API: \(config.api.isEmpty ? "not set" : config.api)")
        lines.append("Token: \(Keychain.read(service: config.tokenService) == nil ? "missing" : "in the keychain")")
        lines.append("Audio recording: \(Recorder.ffmpegPath() == nil ? "needs ffmpeg" : "ready")")
        let sd = scriptsDir()
        let hasPush = FileManager.default.isExecutableFile(atPath: sd + "/push.sh")
        lines.append("Transcribe and push: \(hasPush ? "ready" : "scripts not found at \(sd)")")
        lines.append("Recordings: \(expand(config.outDir))")
        alert("Maestro Bar", lines.joined(separator: "\n"))
    }

    // MARK: - the menu, rebuilt from configuration every time it opens

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let busy = recorder.isRecording

        if busy {
            menu.addItem(menuItem("Stop recording   \(recorder.elapsed)") { [weak self] in
                guard let self = self else { return }
                self.recorder.stop()
            })
            menu.addItem(.separator())
        }

        for item in config.items {
            switch item.type {

            case "separator":
                menu.addItem(.separator())

            case "record":
                let mode = item.mode ?? "audio"
                let mi = menuItem(item.label ?? "Record") { [weak self] in
                    guard let self = self else { return }
                    self.recorder.toggle(mode: mode, client: nil, config: self.config)
                }
                if let spec = item.hotkey { mi.toolTip = spec.joined(separator: " + ") }
                mi.isEnabled = !busy
                menu.addItem(mi)

            case "clients":
                let parent = NSMenuItem(title: item.label ?? "Record for client",
                                        action: nil, keyEquivalent: "")
                let sub = NSMenu()
                sub.autoenablesItems = false
                if clients.isEmpty {
                    let note = NSMenuItem(
                        title: config.api.isEmpty ? "No API configured" : "Loading…",
                        action: nil, keyEquivalent: "")
                    note.isEnabled = false
                    sub.addItem(note)
                    if !clientsRequested { loadClients() }
                } else {
                    let mode = item.mode ?? "audio"
                    for c in clients {
                        let ci = menuItem(c.name) { [weak self] in
                            guard let self = self else { return }
                            self.recorder.start(mode: mode, client: c.name, config: self.config)
                        }
                        ci.isEnabled = !busy
                        sub.addItem(ci)
                    }
                    sub.addItem(.separator())
                    sub.addItem(menuItem("Refresh list") { [weak self] in self?.loadClients() })
                }
                parent.submenu = sub
                parent.isEnabled = !busy
                menu.addItem(parent)

            case "panel":
                let mi = menuItem(item.label ?? "Open panel") { [weak self] in self?.panel.show() }
                if let pc = config.panel { mi.toolTip = pc.hotkey.joined(separator: " + ") }
                mi.isEnabled = config.panel?.enabled ?? false
                menu.addItem(mi)

            case "shell":
                guard let cmd = item.cmd else { break }
                menu.addItem(menuItem(item.label ?? cmd) {
                    runShell(cmd)
                    if let t = item.toast { toast(t) }
                })

            case "open":
                guard let u = item.url, let url = URL(string: u) else { break }
                menu.addItem(menuItem(item.label ?? u) { NSWorkspace.shared.open(url) })

            case "post":
                guard let path = item.path else { break }
                let mi = menuItem(item.label ?? path) { [weak self] in
                    self?.api.post(path, body: item.body) { _, code in
                        if (200..<300).contains(code) {
                            toast(item.toast ?? "Done")
                        } else {
                            toast("Request failed (\(code))")
                        }
                    }
                }
                mi.isEnabled = !config.api.isEmpty
                menu.addItem(mi)

            default:
                let unknown = NSMenuItem(title: "Unknown item type: \(item.type)",
                                         action: nil, keyEquivalent: "")
                unknown.isEnabled = false
                menu.addItem(unknown)
            }
        }

        menu.addItem(.separator())
        menu.addItem(menuItem(Keychain.read(service: config.tokenService) == nil
                              ? "Set API token…" : "Replace API token…") { [weak self] in
            askForToken(service: self?.config.tokenService ?? "maestro-token")
            self?.reload()
        })
        menu.addItem(menuItem("Check setup") { [weak self] in self?.checkSetup() })
        menu.addItem(menuItem("Reload config") { [weak self] in
            self?.reload()
            toast("Config reloaded")
        })
        let src = NSMenuItem(title: configSource, action: nil, keyEquivalent: "")
        src.isEnabled = false
        menu.addItem(src)
        menu.addItem(menuItem("Quit", key: "q") { [weak self] in
            self?.recorder.stop()
            NSApp.terminate(nil)
        })
    }
}
