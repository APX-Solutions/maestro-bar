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

/// The token is typed into a secure field and written to both stores it can
/// live in. It never reaches a shell command or the process list.
///
/// Both, because either one can refuse. The keychain challenges the app
/// whenever its code identity changes — a re-sign, a rebuild, a reinstall —
/// and install.sh writes only the file. API.token() already reads both; saving
/// to only one is how someone is told "Token saved" and then shown a bar that
/// answers 401 to everything.
func askForToken(service: String) {
    let a = NSAlert()
    a.messageText = "Maestro API token"
    a.informativeText = "Paste the token you were given. It is kept in your "
        + "login keychain and in ~/.maestro/token, which is what uploads read "
        + "and what survives the app being re-signed."
    let field = EditableSecureTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
    a.accessoryView = field
    a.addButton(withTitle: "Save")
    a.addButton(withTitle: "Cancel")
    NSApp.activate(ignoringOtherApps: true)
    a.window.initialFirstResponder = field
    guard a.runModal() == .alertFirstButtonReturn else { return }
    let value = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !value.isEmpty else { return }
    let vault = Keychain.write(service: service, value: value)
    let file = API.writeTokenFile(value)
    toast(vault || file ? "Token saved"
          : "Could not save the token — check permissions on ~/.maestro")
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
    private var watchTimer: Timer?
    /// Per section: row id → the status it had last time we looked. What makes
    /// "your session is done" possible, and what keeps it from being said twice.
    private var seenStatus: [String: [String: String]] = [:]
    private var screenWatch: Timer?
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
        recorder.onSent = { [weak self] in self?.panel.recordingSent() }
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
        askForScreenIfNeeded()
        // Puts the bar on screen at launch, for trying a build without
        // reaching for the hot key: MAESTRO_SHOW=1 parks it the way a normal
        // start does, =open the way the chevron does, =ask the way pressing
        // record does.
        switch ProcessInfo.processInfo.environment["MAESTRO_SHOW"] {
        case "1": panel.show(expanding: false)
        case "open": panel.show(expanding: true)
        case "ask": panel.requestRecording(mode: "screen")
        default: break
        }
    }

    // MARK: - screen recording, asked for at a sensible moment

    /// Every update is a different app to macOS. The bundle is signed ad hoc,
    /// so its identity changes with the code, and `update.sh` clears the old
    /// grant on purpose: a stale one shows as ON in System Settings while
    /// capture still fails, which is the worst of both.
    ///
    /// The cost of that honesty is one grant per update. This makes it happen
    /// at the only predictable moment — once, at launch, right after the
    /// update — instead of ambushing someone the first time they reach for a
    /// recording. It also puts the app in the Settings list straight away,
    /// which is where people go looking when it is missing.
    private func askForScreenIfNeeded() {
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0"
        let key = "screenAskedForBuild"
        guard UserDefaults.standard.string(forKey: key) != build else { return }
        UserDefaults.standard.set(build, forKey: key)     // once per build, never a nag
        guard !CGPreflightScreenCaptureAccess() else { return }
        _ = CGRequestScreenCaptureAccess()
        watchForScreenGrant()
    }

    /// macOS applies the grant only to a newly launched process, so the app
    /// restarts itself the moment it lands. That step used to be a line in a
    /// README, which is to say it used to not happen.
    private func watchForScreenGrant() {
        screenWatch?.invalidate()
        let giveUp = Date().addingTimeInterval(180)
        let t = Timer(timeInterval: 2, repeats: true) { [weak self] timer in
            guard let self = self else { timer.invalidate(); return }
            if Date() > giveUp { timer.invalidate(); self.screenWatch = nil; return }
            guard CGPreflightScreenCaptureAccess() else { return }
            timer.invalidate()
            self.screenWatch = nil
            // Never mid-recording: restarting would throw the file away.
            guard !self.recorder.isRecording else { return }
            toast("Screen recording allowed. Restarting Maestro Bar to apply it.")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { self.relaunch() }
        }
        screenWatch = t
        RunLoop.main.add(t, forMode: .common)
    }

    private func relaunch() {
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: cfg) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
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
                self.panel.requestRecording(mode: mode)
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

        watchTimer?.invalidate()
        watchTimer = nil
        // Dropped with the timer: the next poll re-baselines rather than
        // announcing every session that finished while the config was edited.
        seenStatus = [:]
        if (c.panel?.sections ?? []).contains(where: { $0.notifyOnStatus }), !c.api.isEmpty {
            let every = max(20, c.panel?.refreshSeconds ?? 90)
            let t = Timer(timeInterval: every, repeats: true) { [weak self] _ in
                self?.watchStatuses()
            }
            watchTimer = t
            RunLoop.main.add(t, forMode: .common)
            watchStatuses()
        }

        clients = []
        clientsRequested = false
        if c.items.contains(where: { $0.type == "clients" }) { loadClients() }
        paint()
    }

    // What a status means when it arrives, and how to say it. Only endings are
    // worth interrupting someone for: a job moving queued → running is the
    // machine getting to it, which nobody asked to be told about.
    private static let endings: [String: (String, String)] = [
        "opened_pr":  ("Ready to look at", "opened a pull request"),
        "no_changes": ("Nothing to change", "the agent found nothing to do"),
        "failed":     ("Failed", "the run did not finish"),
        "timed_out":  ("Timed out", "the run ran out of time"),
    ]

    /// Poll the sections that asked to be watched, and say so when one of their
    /// rows reaches an end state.
    ///
    /// Runs from `reload`, not from the panel: the panel stops its own polling
    /// when it is hidden, and a notification that only arrives while you are
    /// already looking at the bar is not a notification. A run takes minutes
    /// and nobody watches a toolbar for minutes.
    private func watchStatuses() {
        guard !config.api.isEmpty else { return }
        for s in (config.panel?.sections ?? []) where s.notifyOnStatus && !s.list.isEmpty {
            api.get(s.list) { [weak self] json, code in
                // A failed request is left alone rather than treated as "no
                // rows": a dropped connection is not a finished job.
                guard let self = self, code == 200 else { return }
                self.noteStatuses(section: s.id, rows: API.rows(json))
            }
        }
    }

    /// Compared against what was seen LAST poll, not against a list of things
    /// already announced: the first poll after a launch would otherwise
    /// announce every finished session at once, which is how a useful
    /// notification becomes one people switch off.
    private func noteStatuses(section: String, rows: [[String: Any]]) {
        var now: [String: String] = [:]
        for r in rows {
            guard let id = API.rowID(r) else { continue }
            now[id] = (r["status"] as? String) ?? ""
        }
        let before = seenStatus[section]
        seenStatus[section] = now
        guard let was = before else { return }   // first sight: baseline only
        for (id, status) in now {
            guard let old = was[id], old != status,
                  let (head, what) = AppDelegate.endings[status],
                  AppDelegate.endings[old] == nil            // already ended: a correction
            else { continue }
            let title = rows.first { API.rowID($0) == id }
                .flatMap { $0["title"] as? String } ?? "A session"
            toast(what, title: "\(head) — \(title.prefix(60))")
        }
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
        // First, because it is the answer to "is the fix in?" — and because
        // every other line here is worth doubting if the code is not the code
        // you think it is. build.sh stamps this from the commit count and the
        // sha, so it cannot drift from what was built; a trailing + means the
        // tree had uncommitted changes.
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
        lines.append("Version: \(version ?? "unknown")")
        lines.append("Config: \(configSource)")
        lines.append("API: \(config.api.isEmpty ? "not set" : config.api)")
        // WHICH store answered, not just whether one did: API.token() reads the
        // keychain and then the file, and knowing which is what tells you why
        // a re-signed app suddenly went quiet.
        let tokenWhere: String
        if Keychain.read(service: config.tokenService) != nil { tokenWhere = "the keychain" }
        else if API.token(service: config.tokenService) != nil { tokenWhere = "~/.maestro/token" }
        else { tokenWhere = "MISSING" }
        lines.append("Token: \(tokenWhere)")
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
                    self.panel.requestRecording(mode: mode)
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
