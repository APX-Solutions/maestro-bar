import Foundation
import Security

// The API token, in the two places it can live.
//
// The login keychain is the nicer one:
//   security add-generic-password -s maestro-token -a "$USER" -w 'TOKEN'
//
// But it challenges the app whenever the app's code identity changes — a
// re-sign, a rebuild, a reinstall — and the dialog it raises cannot always be
// typed into. scripts/send.sh has read ~/.maestro/token first for exactly that
// reason, and says so; the app did not, so a machine whose keychain had stopped
// answering kept uploading recordings while every list in the bar came back
// empty. Nothing looks broken in that state: a 401 with no Authorization header
// is indistinguishable from an empty queue.
//
// So: write BOTH, read the file first, same order as send.sh and as the
// Windows twin.
enum Keychain {
    /// mode 600, and the only copy that survives a re-signed app.
    static var tokenFile: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".maestro/token")
    }

    private static func readFile() -> String? {
        guard let s = try? String(contentsOf: tokenFile, encoding: .utf8) else { return nil }
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }

    @discardableResult
    private static func writeFile(_ value: String) -> Bool {
        let f = tokenFile
        let dirPerms: [FileAttributeKey: Any] = [.posixPermissions: NSNumber(value: 0o700)]
        let filePerms: [FileAttributeKey: Any] = [.posixPermissions: NSNumber(value: 0o600)]
        do {
            try FileManager.default.createDirectory(
                at: f.deletingLastPathComponent(), withIntermediateDirectories: true,
                attributes: dirPerms)
            try value.write(to: f, atomically: true, encoding: .utf8)
            // Set AFTER the write: `atomically` replaces the file, which means
            // a fresh inode with default permissions. A token readable by every
            // process on the machine is worse than one awkward to reach.
            try FileManager.default.setAttributes(filePerms, ofItemAtPath: f.path)
            return true
        } catch {
            return false
        }
    }

    /// Saved to BOTH stores. True when at least one took it — a keychain that
    /// refuses must not mean the token went nowhere, which is how someone ends
    /// up being told "saved" and then shown an empty bar.
    @discardableResult
    static func write(service: String, value: String) -> Bool {
        let wroteFile = writeFile(value)
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service
        ]
        SecItemDelete(base as CFDictionary)      // replace, never duplicate
        var add = base
        add[kSecAttrAccount as String] = NSUserName()
        add[kSecValueData as String] = Data(value.utf8)
        let wroteVault = SecItemAdd(add as CFDictionary, nil) == errSecSuccess
        return wroteFile || wroteVault
    }

    /// Where the token that is actually being used came from, for "Check setup".
    static func source(service: String) -> String {
        if readFile() != nil { return "~/.maestro/token" }
        if readKeychain(service: service) != nil { return "the keychain" }
        return "missing"
    }

    /// The file first — see the note above. Uploads already read it in this
    /// order, and the two must not disagree about who you are.
    static func read(service: String) -> String? {
        readFile() ?? readKeychain(service: service)
    }

    private static func readKeychain(service: String) -> String? {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data,
              let s = String(data: data, encoding: .utf8) else { return nil }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
