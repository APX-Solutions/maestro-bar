import Foundation

// Configuration for the sidebar. Same principle as the menu: which icons the
// strip carries, what each one opens, and which endpoints they touch are data.

struct PanelAction {
    var label: String = "OK"
    var symbol: String = ""          // SF Symbol name, optional
    var path: String = ""            // {id} and {any_field} are substituted
    var method: String = "POST"
    var advance: Bool = true         // drop the card and move to the next one
    var toast: String = ""
    var body: [String: String]? = nil
}

extension PanelAction: Decodable {
    enum K: String, CodingKey { case label, symbol, path, method, advance, toast, body }
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: K.self)
        self.init()
        label = try c.decodeIfPresent(String.self, forKey: .label) ?? label
        symbol = try c.decodeIfPresent(String.self, forKey: .symbol) ?? symbol
        path = try c.decodeIfPresent(String.self, forKey: .path) ?? path
        method = try c.decodeIfPresent(String.self, forKey: .method) ?? method
        advance = try c.decodeIfPresent(Bool.self, forKey: .advance) ?? advance
        toast = try c.decodeIfPresent(String.self, forKey: .toast) ?? toast
        body = try c.decodeIfPresent([String: String].self, forKey: .body)
    }
}

/// Which keys of a row to read for each line of the card. The defaults cover
/// the shapes the API already returns, so most sections need no mapping.
struct PanelFields {
    var title: [String] = ["title", "subject", "name", "headline", "kind"]
    var subtitle: [String] = ["subtitle", "client_name", "company", "from_addr", "source", "status"]
    var body: [String] = ["draft_body", "body", "detail", "description", "text", "summary", "preview"]
}

extension PanelFields: Decodable {
    enum K: String, CodingKey { case title, subtitle, body }
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: K.self)
        self.init()
        title = try c.decodeIfPresent([String].self, forKey: .title) ?? title
        subtitle = try c.decodeIfPresent([String].self, forKey: .subtitle) ?? subtitle
        body = try c.decodeIfPresent([String].self, forKey: .body) ?? body
    }
}

struct PanelCompose {
    var path: String = ""                // API endpoint, or empty to use `file`
    var file: String = ""                // append here when there is no endpoint yet
    var field: String = "text"           // JSON key the typed text goes into
    var placeholder: String = "Start typing"
    var record: Bool = true              // show the microphone button
    var toast: String = "Sent"
}

extension PanelCompose: Decodable {
    enum K: String, CodingKey { case path, file, field, placeholder, record, toast }
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: K.self)
        self.init()
        path = try c.decodeIfPresent(String.self, forKey: .path) ?? path
        file = try c.decodeIfPresent(String.self, forKey: .file) ?? file
        field = try c.decodeIfPresent(String.self, forKey: .field) ?? field
        placeholder = try c.decodeIfPresent(String.self, forKey: .placeholder) ?? placeholder
        record = try c.decodeIfPresent(Bool.self, forKey: .record) ?? record
        toast = try c.decodeIfPresent(String.self, forKey: .toast) ?? toast
    }
}

/// One icon on the strip. A section with no `list` is a compose only flyout.
struct PanelSection {
    var id: String = ""
    var title: String = ""
    var symbol: String = "tray"
    var list: String = ""
    var fields: PanelFields = PanelFields()
    var actions: [PanelAction] = []
    var compose: PanelCompose? = nil
    var live: Double = 0                 // seconds between fetches while a card is live; 0 = never
    var watch: Bool = false              // where a recording that was just sent shows up
}

extension PanelSection: Decodable {
    enum K: String, CodingKey {
        case id, title, symbol, list, fields, actions, compose
        case live = "live_seconds"
        case watch = "watch_recordings"
    }
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: K.self)
        self.init()
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? id
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? title
        symbol = try c.decodeIfPresent(String.self, forKey: .symbol) ?? symbol
        list = try c.decodeIfPresent(String.self, forKey: .list) ?? list
        fields = try c.decodeIfPresent(PanelFields.self, forKey: .fields) ?? fields
        actions = try c.decodeIfPresent([PanelAction].self, forKey: .actions) ?? actions
        compose = try c.decodeIfPresent(PanelCompose.self, forKey: .compose)
        live = try c.decodeIfPresent(Double.self, forKey: .live) ?? live
        watch = try c.decodeIfPresent(Bool.self, forKey: .watch) ?? watch
    }
}

/// The record icon on the strip, which is not a section: it has no flyout.
struct RecordButton {
    var symbol: String = "record.circle"
    var mode: String = "audio"
    var label: String = "Record"
}

extension RecordButton: Decodable {
    enum K: String, CodingKey { case symbol, mode, label }
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: K.self)
        self.init()
        symbol = try c.decodeIfPresent(String.self, forKey: .symbol) ?? symbol
        mode = try c.decodeIfPresent(String.self, forKey: .mode) ?? mode
        label = try c.decodeIfPresent(String.self, forKey: .label) ?? label
    }
}

struct PanelConfig {
    var enabled: Bool = true
    var hotkey: [String] = ["ctrl", "alt", "M"]
    var edge: String = "right"           // right | left, where the strip parks
    var width: Double = 44               // the strip itself
    var flyoutWidth: Double = 330        // what opens beside it
    var refreshSeconds: Double = 90      // how often the counts are refreshed
    var sections: [PanelSection] = []
    var records: [RecordButton] = []     // one icon each
    var askPath: String = "/brain/ask"   // the Ask box; empty switches it off
    var askPlaceholder: String = "Ask about clients, meetings, decisions"
    var invisible: Bool = false          // true leaves it out of screen shares
}

extension PanelConfig: Decodable {
    enum K: String, CodingKey {
        case enabled, hotkey, edge, width, sections, record
        case flyoutWidth = "flyout_width"
        case refreshSeconds = "refresh_seconds"
        case askPath = "ask_path"
        case askPlaceholder = "ask_placeholder"
        case invisible
    }
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: K.self)
        self.init()
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? enabled
        hotkey = try c.decodeIfPresent([String].self, forKey: .hotkey) ?? hotkey
        edge = try c.decodeIfPresent(String.self, forKey: .edge) ?? edge
        width = try c.decodeIfPresent(Double.self, forKey: .width) ?? width
        flyoutWidth = try c.decodeIfPresent(Double.self, forKey: .flyoutWidth) ?? flyoutWidth
        refreshSeconds = try c.decodeIfPresent(Double.self, forKey: .refreshSeconds) ?? refreshSeconds
        sections = try c.decodeIfPresent([PanelSection].self, forKey: .sections) ?? sections
        askPath = try c.decodeIfPresent(String.self, forKey: .askPath) ?? askPath
        askPlaceholder = try c.decodeIfPresent(String.self, forKey: .askPlaceholder) ?? askPlaceholder
        invisible = try c.decodeIfPresent(Bool.self, forKey: .invisible) ?? invisible
        // "record" takes one object or a list of them, so a second recorder is
        // a line of JSON rather than a schema change.
        if let many = try? c.decode([RecordButton].self, forKey: .record) {
            records = many
        } else if let one = try? c.decode(RecordButton.self, forKey: .record) {
            records = [one]
        }
    }
}
