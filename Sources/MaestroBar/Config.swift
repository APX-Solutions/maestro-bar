import Foundation

// The menu is data, not code. Everything the bar shows and does comes from a
// JSON file, so the app only needs rebuilding when a new *kind* of item appears.
//
// Decoding is written by hand rather than synthesised: a synthesised decoder
// treats every non-optional field as required, so one missing key in the JSON
// would leave the bar empty. Here a missing key just keeps its default.

struct Badge {
    var enabled: Bool = false
    var path: String = "/overview/counts"
    var field: String = "review"
    var refreshSeconds: Double = 60
}

extension Badge: Decodable {
    enum K: String, CodingKey { case enabled, path, field, refreshSeconds = "refresh_seconds" }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        self.init()
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? enabled
        path = try c.decodeIfPresent(String.self, forKey: .path) ?? path
        field = try c.decodeIfPresent(String.self, forKey: .field) ?? field
        refreshSeconds = try c.decodeIfPresent(Double.self, forKey: .refreshSeconds) ?? refreshSeconds
    }
}

struct AfterRecord {
    // {file} and {client} are substituted before the command runs.
    var cmd: String = ""
    var notify: Bool = true
}

extension AfterRecord: Decodable {
    enum K: String, CodingKey { case cmd, notify }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        self.init()
        cmd = try c.decodeIfPresent(String.self, forKey: .cmd) ?? cmd
        notify = try c.decodeIfPresent(Bool.self, forKey: .notify) ?? notify
    }
}

struct Item: Decodable {
    var type: String                 // record | clients | shell | open | post | separator
    var label: String?
    var mode: String?                // record: audio | screen
    var hotkey: [String]?            // e.g. ["ctrl","alt","R"]
    var cmd: String?                 // shell
    var url: String?                 // open
    var path: String?                // post
    var body: [String: String]?      // post
    var toast: String?
}

struct BarConfig {
    var titleIdle: String = "M"
    var api: String = ""
    var tokenService: String = "maestro-token"   // Keychain generic-password service
    var audioDevice: String = "0"                // ffmpeg avfoundation input index
    var outDir: String = "~/Recordings"
    var clientsPath: String = "/sales/clients"
    var badge: Badge? = nil
    var afterRecord: AfterRecord? = nil
    var panel: PanelConfig? = nil
    var items: [Item] = []
}

extension BarConfig: Decodable {
    enum K: String, CodingKey {
        case titleIdle = "title_idle"
        case api
        case tokenService = "token_service"
        case audioDevice = "audio_device"
        case outDir = "out_dir"
        case clientsPath = "clients_path"
        case badge
        case afterRecord = "after_record"
        case panel
        case sidebar
        case items
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        self.init()
        titleIdle = try c.decodeIfPresent(String.self, forKey: .titleIdle) ?? titleIdle
        api = try c.decodeIfPresent(String.self, forKey: .api) ?? api
        tokenService = try c.decodeIfPresent(String.self, forKey: .tokenService) ?? tokenService
        audioDevice = try c.decodeIfPresent(String.self, forKey: .audioDevice) ?? audioDevice
        outDir = try c.decodeIfPresent(String.self, forKey: .outDir) ?? outDir
        clientsPath = try c.decodeIfPresent(String.self, forKey: .clientsPath) ?? clientsPath
        badge = try c.decodeIfPresent(Badge.self, forKey: .badge)
        afterRecord = try c.decodeIfPresent(AfterRecord.self, forKey: .afterRecord)
        panel = try c.decodeIfPresent(PanelConfig.self, forKey: .sidebar)
             ?? c.decodeIfPresent(PanelConfig.self, forKey: .panel)
        items = try c.decodeIfPresent([Item].self, forKey: .items) ?? items
    }
}

extension BarConfig {
    static var fallback: BarConfig {
        var c = BarConfig()
        c.items = [
            Item(type: "record", label: "Record audio", mode: "audio"),
            Item(type: "separator"),
            Item(type: "shell", label: "Open recordings", cmd: "open ~/Recordings")
        ]
        return c
    }

    // Searched in order. The first one that exists wins.
    static let searchPaths = [
        "~/.config/maestro/bar.json",
        "~/Desktop/MaestroBar/maestro-bar.json",
        "~/Desktop/rec/maestro-bar.json"
    ]

    /// First launch on a fresh Mac: give the user a config of their own to
    /// edit, copied out of the bundle, so the app is never configured by a
    /// file they cannot find.
    static func installDefaultIfMissing() {
        let dst = expand("~/.config/maestro/bar.json")
        guard !FileManager.default.fileExists(atPath: dst),
              let src = Bundle.main.url(forResource: "maestro-bar", withExtension: "json")
        else { return }
        try? FileManager.default.createDirectory(
            atPath: (dst as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true)
        try? FileManager.default.copyItem(atPath: src.path, toPath: dst)
    }

    /// Repoint a config still calling push.sh at send.sh.
    ///
    /// installDefaultIfMissing deliberately never overwrites an existing
    /// config — it is the user's file. The consequence nobody planned for is
    /// that an early install keeps its `after_record` forever, and the early
    /// one ran push.sh: transcribe locally with faster_whisper, then post the
    /// TEXT to /meetings/ingest.
    ///
    /// That is broken in two ways at once. faster_whisper is a Python package
    /// almost nobody has, so the transcript comes out empty and the recording
    /// is never sent — the user sees "Transcript came out empty" and no reason
    /// why. And even when it works it posts text only, throwing away the screen
    /// recording, which is the whole point of recording a screen.
    ///
    /// No reinstall could fix it, so it is fixed here, once, in place. Only
    /// that exact swap is made: a config someone edited on purpose keeps
    /// whatever they set.
    static func migrateStaleAfterRecord() {
        let path = expand("~/.config/maestro/bar.json")
        guard let data = FileManager.default.contents(atPath: path),
              var json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              var after = json["after_record"] as? [String: Any],
              let cmd = after["cmd"] as? String,
              cmd.contains("push.sh")
        else { return }

        after["cmd"] = cmd.replacingOccurrences(of: "push.sh", with: "send.sh")
        json["after_record"] = after

        // Keep a copy: this rewrites a file the user owns, and being able to
        // put it back matters more than the two kilobytes.
        try? FileManager.default.removeItem(atPath: path + ".bak")
        try? FileManager.default.copyItem(atPath: path, toPath: path + ".bak")

        guard let out = try? JSONSerialization.data(
                withJSONObject: json, options: [.prettyPrinted, .sortedKeys]) else { return }
        try? out.write(to: URL(fileURLWithPath: path))
        NSLog("MaestroBar: migrated after_record from push.sh to send.sh")
    }

    static func load() -> (BarConfig, String) {
        for p in searchPaths {
            guard let data = FileManager.default.contents(atPath: expand(p)) else { continue }
            do {
                return (try JSONDecoder().decode(BarConfig.self, from: data), p)
            } catch {
                NSLog("MaestroBar: %@ failed to parse: %@", p, String(describing: error))
                return (BarConfig.fallback, "\(p) is invalid, using defaults")
            }
        }
        if let src = Bundle.main.url(forResource: "maestro-bar", withExtension: "json"),
           let data = FileManager.default.contents(atPath: src.path),
           let c = try? JSONDecoder().decode(BarConfig.self, from: data) {
            return (c, "the copy inside the app")
        }
        return (BarConfig.fallback, "no config file found")
    }
}

func expand(_ p: String) -> String { (p as NSString).expandingTildeInPath }

/// Where the recording scripts live. Inside the app bundle for someone who was
/// handed the app, or in ~/.maestro/bin for a machine that ran the installer.
func scriptsDir() -> String {
    if let r = Bundle.main.resourceURL?.appendingPathComponent("scripts"),
       FileManager.default.fileExists(atPath: r.path) {
        return r.path
    }
    return expand("~/.maestro/bin")
}

func shellQuote(_ s: String) -> String {
    "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

@discardableResult
func runShell(_ command: String) -> Process? {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/zsh")
    p.arguments = ["-lc", command]
    do { try p.run() } catch {
        NSLog("MaestroBar: shell failed: %@", "\(error)")
        return nil
    }
    return p
}

func toast(_ text: String, title: String = "Maestro") {
    let script = "display notification \(shellQuote(text)) with title \(shellQuote(title))"
    runShell("osascript -e \(shellQuote(script))")
}
