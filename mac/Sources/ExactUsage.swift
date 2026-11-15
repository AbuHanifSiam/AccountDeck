// AccountDeck — exact usage limits from Anthropic, with the user's permission.
//
// Claude Desktop only saves its usage every few hours, and Claude Code only reports it while
// it is replying, so file-based readings fall behind. With permission, AccountDeck reads the
// Claude Code login that Claude Code keeps in the macOS Keychain and asks Anthropic for the
// current usage of that Claude account: the same numbers as /usage in Claude Code.
//
// Rules:
//   - Off until the person says yes (a pop-up explains why; Skip keeps it off).
//   - When the login has expired, it is renewed the way Claude Code renews it and saved back
//     to the same Keychain item, so Claude Code keeps working with the new one. Before renewing,
//     AccountDeck checks that it may save to that item; if not, it doesn't renew.
//   - It is sent only to api.anthropic.com, held in memory for the request, never saved or shown.
//   - What is saved is a short status line for Customize ("Working", "No login found", ...).

import Foundation
import Security
import CryptoKit
import AppKit

enum ExactUsage {
    static let onKey = "exactUsageOn"          // Bool
    static let askedKey = "exactUsageAsked"    // Bool: the pop-up was answered
    static let statusKey = "exactUsageStatus"  // String shown in Customize

    static var enabled: Bool { UserDefaults.standard.bool(forKey: onKey) }

    static func setStatus(_ s: String) {
        DispatchQueue.main.async { UserDefaults.standard.set(s, forKey: statusKey) }
    }

    // MARK: asking

    /// The pop-up, once: why AccountDeck wants the login, with Allow and Skip.
    @MainActor
    static func askIfNeeded(hasClaudeCode: Bool) {
        let d = UserDefaults.standard
        guard hasClaudeCode, !d.bool(forKey: askedKey) else { return }
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Show exact usage limits?"
        alert.informativeText = """
        AccountDeck can show your real usage, straight from Anthropic, instead of Claude Desktop's occasional estimate.

        To do that it uses your Claude Code login. It's only sent to Anthropic and never shown.

        After you click Allow, macOS asks once for access to "Claude Code-credentials". Click Always Allow. That's the only question.

        You can turn this off any time in Customize Menu.
        """
        alert.addButton(withTitle: "Allow")
        alert.addButton(withTitle: "Skip")
        let allow = alert.runModal() == .alertFirstButtonReturn
        d.set(true, forKey: askedKey)
        d.set(allow, forKey: onKey)
        if !allow { d.set("Off", forKey: statusKey) }
    }

    // MARK: logins for Claude Desktop accounts

    /// A Claude Desktop account has no Claude Code login of its own. "Get exact usage" signs in
    /// once in a hidden Claude Code folder kept just for this, so its usage can be asked for too.
    static func linkDir(_ desktop: Account) -> String {
        FileManager.default.homeDirectoryForCurrentUser.path + "/.accountdeck/exact/" + desktop.id
    }

    static func hasLink(_ desktop: Account) -> Bool {
        FileManager.default.fileExists(atPath: linkDir(desktop) + "/.claude.json")
    }

    // MARK: the login

    /// Claude Code's Keychain item: "Claude Code-credentials" for the default config folder,
    /// with "-" + the first 8 hex digits of SHA-256(config folder) for any other.
    static func serviceNames(configDir: String, isDefault: Bool) -> [String] {
        if isDefault { return ["Claude Code-credentials"] }
        let hash = SHA256.hash(data: Data(configDir.utf8)).map { String(format: "%02x", $0) }.joined().prefix(8)
        return ["Claude Code-credentials-\(hash)"]
    }

    enum TokenResult { case token(String), expired, missing, denied }

    typealias Item = (ref: Any, data: Data)

    /// The login, kept in memory once read, so macOS asks for Keychain access only once
    /// (and not every minute). Cleared when it expires.
    nonisolated(unsafe) static var cache: [String: (token: String, expires: Double)] = [:]
    static let lock = NSLock()
    static func cached(_ service: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        guard let c = cache[service], c.expires > Date().timeIntervalSince1970 + 60 else { return nil }
        return c.token
    }
    static func remember(_ service: String, _ token: String, _ expiresMs: Double?) {
        lock.lock(); defer { lock.unlock() }
        cache[service] = (token, (expiresMs ?? 0) / 1000 > 0 ? expiresMs! / 1000 : Date().timeIntervalSince1970 + 3600)
    }

    /// Keychain items with that name, newest first. Listing them doesn't open them, so it
    /// doesn't make macOS ask; only reading one does.
    static func refs(service: String) -> [Any] {
        let list: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                   kSecAttrService as String: service,
                                   kSecReturnAttributes as String: true,
                                   kSecReturnPersistentRef as String: true,
                                   kSecMatchLimit as String: kSecMatchLimitAll]
        var out: AnyObject?
        guard SecItemCopyMatching(list as CFDictionary, &out) == errSecSuccess,
              let found = out as? [[String: Any]] else { return [] }
        return found.sorted {
            (($0[kSecAttrModificationDate as String] as? Date) ?? .distantPast) > (($1[kSecAttrModificationDate as String] as? Date) ?? .distantPast)
        }.compactMap { $0[kSecValuePersistentRef as String] }
    }

    static func token(configDir: String, isDefault: Bool) async -> TokenResult {
        var denied = false, sawExpired = false
        for service in serviceNames(configDir: configDir, isDefault: isDefault) {
            if let t = cached(service) { return .token(t) }
            // Open the newest one first and stop at the first good login: one Keychain
            // question from macOS, not one per item.
            for ref in refs(service: service) {
                var d: AnyObject?
                let q: [String: Any] = [kSecValuePersistentRef as String: ref, kSecReturnData as String: true]
                let status = SecItemCopyMatching(q as CFDictionary, &d)
                if status == errSecAuthFailed || status == errSecUserCanceled || status == errSecInteractionNotAllowed { denied = true; break }
                guard status == errSecSuccess, let data = d as? Data,
                      let j = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                      let o = j["claudeAiOauth"] as? [String: Any],
                      let t = o["accessToken"] as? String, !t.isEmpty else { continue }
                let exp = (o["expiresAt"] as? NSNumber)?.doubleValue
                if let exp, exp / 1000 < Date().timeIntervalSince1970 + 60 {
                    if let (nt, nexp) = await renew(item: (ref, data), json: j, oauth: o) {
                        remember(service, nt, nexp); return .token(nt)
                    }
                    sawExpired = true; continue
                }
                remember(service, t, exp)
                return .token(t)
            }
        }
        if sawExpired { return .expired }
        // Claude Code on some setups keeps the login in a file; it is only read there.
        if let f = FileManager.default.contents(atPath: configDir + "/.credentials.json"),
           let j = (try? JSONSerialization.jsonObject(with: f)) as? [String: Any],
           let o = j["claudeAiOauth"] as? [String: Any], let t = o["accessToken"] as? String, !t.isEmpty {
            if let exp = (o["expiresAt"] as? NSNumber)?.doubleValue, exp / 1000 < Date().timeIntervalSince1970 + 60 { return .expired }
            return .token(t)
        }
        return denied ? .denied : .missing
    }

    /// Renews an expired login the way Claude Code does, and saves it back to its Keychain item.
    /// Nothing is renewed unless saving to that item works, so Claude Code is never left with a
    /// login that has been replaced.
    static func renew(item: Item, json: [String: Any], oauth: [String: Any]) async -> (String, Double?)? {
        guard let refresh = oauth["refreshToken"] as? String, !refresh.isEmpty else { return nil }
        // 1. May we save to this item? Write the same contents back: nothing changes.
        let ref: [String: Any] = [kSecValuePersistentRef as String: item.ref]
        guard SecItemUpdate(ref as CFDictionary, [kSecValueData as String: item.data] as CFDictionary) == errSecSuccess else { return nil }
        // 2. Renew.
        var req = URLRequest(url: URL(string: "https://console.anthropic.com/v1/oauth/token")!)
        req.httpMethod = "POST"
        req.timeoutInterval = 20
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: [
            "grant_type": "refresh_token", "refresh_token": refresh,
            "client_id": "9d1c250a-e61b-44d9-88ed-5944d1962f5e"])
        guard let (body, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let r = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any],
              let access = r["access_token"] as? String, !access.isEmpty else { return nil }
        // 3. Save it back, keeping everything else Claude Code stored.
        var o = oauth
        o["accessToken"] = access
        var newExp: Double?
        if let newRefresh = r["refresh_token"] as? String, !newRefresh.isEmpty { o["refreshToken"] = newRefresh }
        if let secs = (r["expires_in"] as? NSNumber)?.doubleValue {
            newExp = (Date().timeIntervalSince1970 + secs) * 1000
            o["expiresAt"] = Int64(newExp!)
        }
        var j = json; j["claudeAiOauth"] = o
        if let data = try? JSONSerialization.data(withJSONObject: j) {
            _ = SecItemUpdate(ref as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        }
        return (access, newExp)
    }

    // MARK: the request

    static func parseDate(_ s: String?) -> Date? {
        guard let s else { return nil }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }

    /// A reading, with the Claude account it belongs to (asked from Anthropic, because the
    /// login in the Keychain isn't always the account Claude Code's settings file names).
    enum Outcome { case usage(Usage, account: String), failed(String) }

    static func get(_ path: String, token t: String) async -> (Int, [String: Any]?) {
        var req = URLRequest(url: URL(string: "https://api.anthropic.com" + path)!)
        req.timeoutInterval = 15
        req.setValue("Bearer \(t)", forHTTPHeaderField: "Authorization")
        req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("AccountDeck", forHTTPHeaderField: "User-Agent")
        guard let (body, resp) = try? await URLSession.shared.data(for: req) else { return (0, nil) }
        return ((resp as? HTTPURLResponse)?.statusCode ?? 0, (try? JSONSerialization.jsonObject(with: body)) as? [String: Any])
    }

    static func fetch(configDir: String, isDefault: Bool) async -> Outcome {
        let t: String
        switch await token(configDir: configDir, isDefault: isDefault) {
        case .token(let s): t = s
        case .expired: return .failed("Couldn't renew the Claude Code login")
        case .missing: return .failed("No Claude Code login found")
        case .denied: return .failed("Keychain access was not allowed")
        }
        let (code, body) = await get("/api/oauth/usage", token: t)
        guard code == 200, let j = body else { return .failed(code == 0 ? "No connection to Anthropic" : "Anthropic answered \(code)") }
        let (pcode, profile) = await get("/api/oauth/profile", token: t)
        guard pcode == 200, let acc = (profile?["account"] as? [String: Any])?["uuid"] as? String else {
            return .failed("Couldn't tell which Claude account the login belongs to")
        }
        func window(_ key: String, _ name: String) -> (Double, Date?, String)? {
            guard let w = j[key] as? [String: Any], let p = (w["utilization"] as? NSNumber)?.doubleValue else { return nil }
            return (p, parseDate(w["resets_at"] as? String), name)
        }
        let five = window("five_hour", "5-hour"), week = window("seven_day", "Weekly")
        guard let main = five ?? week else { return .failed("Unexpected answer") }
        let other = five != nil ? week : nil
        return .usage(Usage(percent: main.0, resetsAt: main.1, window: main.2,
                            second: other.map { (percent: $0.0, resetsAt: $0.1, window: $0.2) }, asOf: Date()), account: acc)
    }
}
