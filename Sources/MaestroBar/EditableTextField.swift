import AppKit

/// Text fields that accept Cmd+V.
///
/// The standard editing shortcuts are not built into NSTextField. They are key
/// equivalents on the Edit menu, and this app is an accessory (LSUIElement)
/// with no menu bar to carry one — so Cmd+V reached nothing and every field in
/// the app could only be typed into. For a token or a URL that is exactly
/// backwards: those are values nobody types, and the dialogs asking for them
/// both say "paste".
///
/// The action is sent to nil so it travels the responder chain and arrives at
/// the field editor, which is the object that actually performs the edit.
private func performEditingShortcut(_ event: NSEvent, from view: NSView) -> Bool {
    guard event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
          let key = event.charactersIgnoringModifiers?.lowercased() else { return false }
    let action: Selector
    switch key {
    case "v": action = #selector(NSText.paste(_:))
    case "c": action = #selector(NSText.copy(_:))
    case "x": action = #selector(NSText.cut(_:))
    case "a": action = #selector(NSText.selectAll(_:))
    case "z": action = Selector(("undo:"))
    default: return false
    }
    return NSApp.sendAction(action, to: nil, from: view)
}

final class EditableTextField: NSTextField {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        performEditingShortcut(event, from: self) || super.performKeyEquivalent(with: event)
    }
}

/// The token field. Secure, and still pasteable — the token is 43 random
/// characters and copying it out of a message is the only sane way in.
final class EditableSecureTextField: NSSecureTextField {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        performEditingShortcut(event, from: self) || super.performKeyEquivalent(with: event)
    }
}
