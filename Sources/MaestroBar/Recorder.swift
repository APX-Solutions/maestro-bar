import AppKit
import CoreGraphics

// The app owns the recording process itself instead of shelling out to a script
// with a PID file in /tmp. That is the reason to go native: the menu bar shows
// the real state of the recorder, not a guess about a file on disk.
final class Recorder {
    private var process: Process?
    private var startedAt: Date?
    private var file: URL?
    private var client: String?
    private(set) var mode: String = "audio"
    private var config = BarConfig.fallback

    var onChange: (() -> Void)?
    /// A recording was handed to the after-record step — it is on its way.
    var onSent: (() -> Void)?

    var isRecording: Bool { process != nil }

    var elapsed: String {
        guard let s = startedAt else { return "" }
        let t = Int(Date().timeIntervalSince(s))
        return String(format: "%d:%02d", t / 60, t % 60)
    }

    func toggle(mode: String, client: String?, config: BarConfig) {
        // Only asked on the way in. Asking on the way out would put a dialog in
        // front of someone trying to stop, while the recording keeps rolling.
        if isRecording {
            stop()
        } else {
            start(mode: mode, client: client, config: config, pageURL: askPageURL())
        }
    }

    /// Where the bug is, asked once before capture starts.
    ///
    /// A screen recording shows the page but not dependably its address — the
    /// URL bar is small, often cropped, and the model reads what was SAID. This
    /// is the one fact a recording cannot carry, so it is asked for directly.
    ///
    /// Prefilled from the clipboard when it holds a URL, which it usually does:
    /// someone reporting a page bug copied the address on the way here. That
    /// makes the prompt a single Return.
    ///
    /// Skipping is a real answer. Skip, Escape, or an empty box all record with
    /// no URL — nothing here can stop a recording.
    private func askPageURL() -> String {
        let a = NSAlert()
        a.messageText = "Where is this?"
        a.informativeText = "Paste the page URL. Optional — press Skip if it does not apply."
        a.addButton(withTitle: "Record")
        a.addButton(withTitle: "Skip")

        let field = EditableTextField(frame: NSRect(x: 0, y: 0, width: 360, height: 24))
        field.placeholderString = "https://…"
        let clip = (NSPasteboard.general.string(forType: .string) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = clip.lowercased()
        if (lower.hasPrefix("http://") || lower.hasPrefix("https://")), clip.count <= 2000 {
            field.stringValue = clip
        }
        a.accessoryView = field
        a.window.initialFirstResponder = field

        // The bar is an accessory app with no windows of its own, so the alert
        // can open behind whatever is in front. Without this it looks like the
        // record button did nothing.
        NSApp.activate(ignoringOtherApps: true)
        guard a.runModal() == .alertFirstButtonReturn else { return "" }
        return field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The app's own copy first, then Homebrew's.
    ///
    /// Audio needs ffmpeg (screen capture does not — that is `screencapture`).
    /// It used to come only from Homebrew, which meant anyone who installed by
    /// dragging the app out of the DMG never got one: the recorder then failed
    /// silently and produced a file with nothing in it. Shipping a copy inside
    /// the bundle makes audio work on a machine that has never seen Homebrew.
    ///
    /// Homebrew stays in the list behind it. A developer running from a local
    /// build has no bundled binary, and someone who deliberately installed a
    /// newer ffmpeg should still be able to fall back to it.
    static func ffmpegPath() -> String? {
        var candidates: [String] = []
        if let bundled = Bundle.main.url(forAuxiliaryExecutable: "ffmpeg")?.path {
            candidates.append(bundled)
        }
        // Resources/ as well: a plain file copied in by the build script does
        // not register as an auxiliary executable.
        if let res = Bundle.main.resourceURL?.appendingPathComponent("ffmpeg").path {
            candidates.append(res)
        }
        candidates += ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg", "/usr/bin/ffmpeg"]
        for p in candidates where FileManager.default.isExecutableFile(atPath: p) {
            return p
        }
        return nil
    }

    func start(mode: String, client: String?, config: BarConfig,
               pageURL: String = "") {
        guard !isRecording else { return }
        if mode != "screen", Recorder.ffmpegPath() == nil {
            // The app ships its own ffmpeg, so reaching here means the copy
            // inside the bundle is missing — a broken build or a stripped app,
            // not something the user did. Say so, and still give them the way
            // out rather than leaving them stuck.
            alert("This copy of Maestro Bar is missing ffmpeg",
                  "Audio recording needs it; screen recording does not. The app "
                  + "normally carries its own copy, so this build is incomplete "
                  + "— reinstall from the latest DMG. To fix it right now, "
                  + "install ffmpeg with Homebrew and try again.",
                  copy: "brew install ffmpeg")
            return
        }
        // Screen Recording, asked for properly and BEFORE recording.
        //
        // CGPreflightScreenCaptureAccess reports the status without prompting;
        // CGRequestScreenCaptureAccess shows the real system prompt, but only
        // the FIRST time a given app asks — once a decision exists it returns
        // silently, which is why a plain retry loop would look like a dead
        // button forever. So: ask once, and if the answer is still no, take
        // them to the exact settings pane instead of describing it.
        //
        // macOS applies this permission only to a newly launched process, so
        // the restart instruction is not boilerplate — granting it while this
        // app runs genuinely changes nothing until it is reopened.
        if mode == "screen", !CGPreflightScreenCaptureAccess() {
            if !CGRequestScreenCaptureAccess() {
                alert("Maestro Bar needs permission to record the screen",
                      "Turn on Maestro Bar under Screen & System Audio "
                      + "Recording, then QUIT AND REOPEN Maestro Bar — macOS "
                      + "only gives this permission to an app when it starts, "
                      + "so it will not work until you reopen it.",
                      openSettings: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
                return
            }
            // Granted just now: this process still cannot use it.
            alert("Permission granted — reopen Maestro Bar",
                  "macOS applies screen recording only when an app starts, so "
                  + "quit Maestro Bar and open it again. Then the recording "
                  + "will work.")
            return
        }

        self.config = config
        self.client = client
        self.mode = mode

        let dir = expand(config.outDir)
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)

        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd_HHmmss"
        var name = fmt.string(from: Date())
        if let c = client, !c.isEmpty { name += "-" + Recorder.slug(c) }
        let out = URL(fileURLWithPath: dir)
            .appendingPathComponent(name + "." + (mode == "screen" ? "mov" : "m4a"))
        file = out

        // Written now, while the answer is in hand, rather than after the
        // recording ends: a crash mid-capture still leaves the page beside the
        // media, and send.sh reads it there on the first try or on a retry days
        // later. Removed first, so a skipped prompt cannot inherit the URL of
        // the previous recording.
        let side = URL(fileURLWithPath: out.path + ".url")
        try? FileManager.default.removeItem(at: side)
        if !pageURL.isEmpty {
            try? pageURL.write(to: side, atomically: true, encoding: .utf8)
        }

        // exec replaces the shell with the recorder, so the interrupt below
        // reaches ffmpeg itself. A login shell is used so Homebrew is on PATH.
        let cmd: String
        if mode == "screen" {
            cmd = "exec screencapture -v -g -k \(shellQuote(out.path))"
        } else {
            cmd = "exec \(Recorder.ffmpegPath() ?? "ffmpeg") -hide_banner -loglevel error"
                + " -f avfoundation -i \(shellQuote(":" + config.audioDevice))"
                + " -ac 1 -ar 16000 -c:a aac -b:a 64k -y \(shellQuote(out.path))"
        }

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-lc", cmd]
        p.standardInput = Pipe()          // ffmpeg reads stdin; keep it open and quiet
        p.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async { self?.finish() }
        }
        do {
            try p.run()
        } catch {
            toast("Could not start the recorder: \(error.localizedDescription)")
            file = nil
            return
        }
        process = p
        startedAt = Date()
        onChange?()
    }

    func stop() {
        guard let p = process else { return }
        p.interrupt()                     // ffmpeg and screencapture both finalise on SIGINT
        DispatchQueue.global().asyncAfter(deadline: .now() + 6) {
            if p.isRunning { p.terminate() }
        }
    }

    private func finish() {
        let recorded = file
        let tag = client
        let cfg = config
        process = nil
        startedAt = nil
        file = nil
        client = nil
        onChange?()

        // No file at all is not "nothing happened" — it is the recorder being
        // refused, and staying quiet about it is why screen recording looked
        // broken for days with no error to go on.
        //
        // screencapture writes nothing when Screen Recording is denied. The
        // trap is that macOS applies that permission only to a NEWLY launched
        // process: granting it while the app is running changes nothing until
        // the app is quit and reopened, so the grant looks done and every
        // click still fails. Microphone does not behave this way, which is why
        // audio worked throughout.
        guard let f = recorded, FileManager.default.fileExists(atPath: f.path) else {
            if mode == "screen" {
                alert("Screen recording was blocked",
                      "macOS did not let the recorder capture the screen, so no "
                      + "file was written.\n\nOpen System Settings > Privacy & "
                      + "Security > Screen & System Audio Recording and switch "
                      + "Maestro Bar on. Then QUIT AND REOPEN this app — macOS "
                      + "only applies that permission to a newly launched app, "
                      + "so granting it while the app runs changes nothing.",
                      openSettings: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
            } else {
                toast("The recorder wrote no file. Check the input device in the config.")
            }
            return
        }
        let attrs = try? FileManager.default.attributesOfItem(atPath: f.path)
        if ((attrs?[.size] as? Int) ?? 0) < 4096 {
            toast("The recording is empty. Check the input device in the config.")
            return
        }

        if let after = cfg.afterRecord, !after.cmd.isEmpty {
            let cmd = after.cmd
                .replacingOccurrences(of: "{scripts}", with: shellQuote(scriptsDir()))
                .replacingOccurrences(of: "{file}", with: shellQuote(f.path))
                .replacingOccurrences(of: "{client}", with: shellQuote(tag ?? ""))
            if after.notify { toast("Saved \(f.lastPathComponent), processing now") }
            runShell(cmd)
            onSent?()
        } else {
            toast("Saved \(f.lastPathComponent)")
        }
    }

    private static func slug(_ s: String) -> String {
        let allowed = CharacterSet.alphanumerics
        let mapped = String(s.lowercased().unicodeScalars.map {
            allowed.contains($0) ? Character($0) : "-"
        })
        return mapped.split(separator: "-", omittingEmptySubsequences: true).joined(separator: "-")
    }
}
