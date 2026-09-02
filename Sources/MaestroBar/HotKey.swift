import AppKit
import Carbon.HIToolbox

// Carbon hot keys, deliberately: they work without the Accessibility permission
// that a global NSEvent monitor would demand.
final class HotKey {
    private var ref: EventHotKeyRef?
    private var id: UInt32 = 0

    private static var handlers: [UInt32: () -> Void] = [:]
    private static var nextID: UInt32 = 1
    private static var handlerInstalled = false

    static let keyCodes: [String: UInt32] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9,
        "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17,
        "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "9": 25, "7": 26, "8": 28, "0": 29,
        "o": 31, "u": 32, "i": 34, "p": 35, "l": 37, "j": 38, "k": 40, "n": 45, "m": 46,
        "space": 49, "return": 36, "escape": 53, "tab": 48,
        "f1": 122, "f2": 120, "f3": 99, "f4": 118, "f5": 96, "f6": 97, "f7": 98, "f8": 100
    ]

    /// spec is like ["ctrl","alt","R"]: modifiers first, key last.
    init?(spec: [String], handler: @escaping () -> Void) {
        guard let keyName = spec.last?.lowercased(),
              let code = HotKey.keyCodes[keyName] else { return nil }

        var mods: UInt32 = 0
        for m in spec.dropLast().map({ $0.lowercased() }) {
            switch m {
            case "cmd", "command": mods |= UInt32(cmdKey)
            case "alt", "opt", "option": mods |= UInt32(optionKey)
            case "ctrl", "control": mods |= UInt32(controlKey)
            case "shift": mods |= UInt32(shiftKey)
            default: break
            }
        }
        guard mods != 0 else { return nil }   // never take over a bare key

        HotKey.installHandlerOnce()
        id = HotKey.nextID
        HotKey.nextID += 1
        HotKey.handlers[id] = handler

        let hkID = EventHotKeyID(signature: OSType(0x6D617374), id: id)   // 'mast'
        let status = RegisterEventHotKey(code, mods, hkID, GetApplicationEventTarget(), 0, &ref)
        if status != noErr {
            HotKey.handlers[id] = nil
            return nil
        }
    }

    deinit {
        if let r = ref { UnregisterEventHotKey(r) }
        HotKey.handlers[id] = nil
    }

    private static func installHandlerOnce() {
        guard !handlerInstalled else { return }
        handlerInstalled = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            var hkID = EventHotKeyID()
            GetEventParameter(event,
                              EventParamName(kEventParamDirectObject),
                              EventParamType(typeEventHotKeyID),
                              nil,
                              MemoryLayout<EventHotKeyID>.size,
                              nil,
                              &hkID)
            if let h = HotKey.handlers[hkID.id] {
                DispatchQueue.main.async { h() }
            }
            return noErr
        }, 1, &spec, nil, nil)
    }
}
