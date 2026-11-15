// AccountDeck — a menu bar app that switches between your Claude Code, Codex and ChatGPT accounts.
//
// How switching works:
//  • Claude Code: each account has its own config folder. The active one is exported as
//    CLAUDE_CONFIG_DIR through ~/.accountdeck/env.sh (the default account leaves it unset).
//  • Codex: same idea with CODEX_HOME.
//  • ChatGPT: each account gets its own isolated browser profile, opened on chatgpt.com.
// A small hook in ~/.zshrc re-reads env.sh before every prompt, so a switch applies to the
// next command in every open Terminal window.

import SwiftUI
import AppKit
import ServiceManagement

// MARK: - Model

enum Service: String, Codable, CaseIterable, Identifiable {
    case desktop, claude, codex, chatgpt
    var id: String { rawValue }

    var title: String {
        switch self {
        case .desktop: return "Claude Desktop"
        case .claude: return "Claude Code"
        case .codex: return "Codex"
        case .chatgpt: return "ChatGPT"
        }
    }
    var whereItRuns: String {
        switch self {
        case .desktop: return "App"
        case .claude, .codex: return "Terminal"
        case .chatgpt: return "Browser"
        }
    }
    var hue: Color {
        switch self {
        case .desktop: return Color(red: 0.85, green: 0.47, blue: 0.34)  // clay
        case .claude: return Color(red: 0.62, green: 0.42, blue: 0.32)   // dark clay
        case .codex: return Color(red: 0.18, green: 0.48, blue: 0.96)    // blue
        case .chatgpt: return Color(red: 0.06, green: 0.64, blue: 0.50)  // green
        }
    }
    var envVar: String? {
        switch self {
        case .claude: return "CLAUDE_CONFIG_DIR"
        case .codex: return "CODEX_HOME"
        case .desktop, .chatgpt: return nil
        }
    }
}

struct Account: Codable, Identifiable, Hashable {
    var id: String
    var service: Service
    var name: String
    var isDefault: Bool
    var dir: String
}

struct SavedState: Codable {
    var accounts: [Account] = []
    var active: [String: String] = [:]   // service raw value -> account id
}

enum Screen: Equatable { case list, add, customize }

/// What the main menu shows, chosen on the Customize screen. Stored in UserDefaults.
enum MenuLayout {
    static let orderKey = "menuServiceOrder"
    static let hiddenKey = "menuHiddenServices"
    static let compactKey = "menuCompactRows"
    static let footerKey = "menuUsageOnRows"
    static let limitKey = "menuLimitWindow"   // "auto", "5h" or "weekly"   // usage badge on menu rows
    static let defaultOrder = Service.allCases.map(\.rawValue).joined(separator: ",")

    static func order(_ raw: String) -> [Service] {
        var out = raw.split(separator: ",").compactMap { Service(rawValue: String($0)) }
        for s in Service.allCases where !out.contains(s) { out.append(s) }
        return out
    }
    static func hidden(_ raw: String) -> Set<Service> {
        Set(raw.split(separator: ",").compactMap { Service(rawValue: String($0)) })
    }
    static func encode(_ list: [Service]) -> String { list.map(\.rawValue).joined(separator: ",") }
}

/// A question shown inside the menu (pop-up alerts don't show reliably from a menu bar panel).
struct Confirm: Identifiable {
    let id = UUID()
    var title: String
    var message: String
    var button: String
    var hue: Color
    var destructive = false
    var action: () -> Void
}

@MainActor
final class AppModel: ObservableObject {
    @Published var accounts: [Account] = [] {
        didSet { if accounts != oldValue { UsageStore.shared.watch(accounts) } }
    }
    @Published var active: [String: String] = [:]
    @Published var details: [String: String] = [:]      // account id -> email / status
    @Published var signedIn: [String: Bool] = [:]
    @Published var shellLinked = false
    @Published var screen: Screen = .list
    @Published var toast: String?
    @Published var switching = false
    @Published var confirm: Confirm?
    @Published var carryChat: Bool = (UserDefaults.standard.object(forKey: "carryChat") as? Bool) ?? true {
        didSet { UserDefaults.standard.set(carryChat, forKey: "carryChat") }
    }
    @Published var renaming: Account?
    @Published var launchAtLogin = SMAppService.mainApp.status == .enabled

    let fm = FileManager.default
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    var root: String { home + "/.accountdeck" }
    var statePath: String { root + "/state.json" }
    var envPath: String { root + "/env.sh" }
    var zshrcPath: String { home + "/.zshrc" }
    static let hookMarker = "# >>> AccountDeck >>>"

    init() {
        try? fm.createDirectory(atPath: root, withIntermediateDirectories: true)
        load()
        ensureDefaults()
        save()
        writeEnv()
        refresh()
        UsageStore.shared.refresh(accounts, force: true)   // starts the live file watch
    }

    // MARK: persistence

    func load() {
        guard let data = fm.contents(atPath: statePath),
              let s = try? JSONDecoder().decode(SavedState.self, from: data) else { return }
        accounts = s.accounts
        active = s.active
    }

    func save() {
        let s = SavedState(accounts: accounts, active: active)
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? enc.encode(s) { fm.createFile(atPath: statePath, contents: data) }
    }

    /// The accounts you already use become the "Main" account of each tool.
    func ensureDefaults() {
        if !accounts.contains(where: { $0.service == .desktop && $0.isDefault }) {
            accounts.insert(Account(id: "desktop-default", service: .desktop, name: "Main",
                                    isDefault: true, dir: root + "/desktop/desktop-default"), at: 0)
        }
        if !accounts.contains(where: { $0.service == .claude && $0.isDefault }) {
            accounts.insert(Account(id: "claude-default", service: .claude, name: "Main",
                                    isDefault: true, dir: home + "/.claude"), at: 0)
        }
        if !accounts.contains(where: { $0.service == .codex && $0.isDefault }) {
            accounts.append(Account(id: "codex-default", service: .codex, name: "Main",
                                    isDefault: true, dir: home + "/.codex"))
        }
        for s in [Service.desktop, .claude, .codex] where active[s.rawValue] == nil {
            active[s.rawValue] = accounts.first(where: { $0.service == s && $0.isDefault })?.id
        }
    }

    func accounts(for s: Service) -> [Account] { accounts.filter { $0.service == s } }
    func isActive(_ a: Account) -> Bool { active[a.service.rawValue] == a.id }

    // MARK: env + shell hook

    func writeEnv() {
        var lines = ["# Written by AccountDeck. Do not edit — use the menu bar app.", ""]
        for s in [Service.claude, .codex] {
            guard let v = s.envVar else { continue }
            if let id = active[s.rawValue], let a = accounts.first(where: { $0.id == id }), !a.isDefault {
                lines.append("export \(v)=\"\(a.dir)\"")
            } else {
                lines.append("unset \(v)")
            }
        }
        lines.append("")
        fm.createFile(atPath: envPath, contents: lines.joined(separator: "\n").data(using: .utf8))
        shellLinked = (try? String(contentsOfFile: zshrcPath, encoding: .utf8))?.contains(Self.hookMarker) ?? false
    }

    func linkShell() {
        let block = """

        \(Self.hookMarker)
        # Re-reads the active Claude Code / Codex account before every prompt.
        _accountdeck_env() { [ -f "$HOME/.accountdeck/env.sh" ] && source "$HOME/.accountdeck/env.sh"; }
        autoload -Uz add-zsh-hook && add-zsh-hook precmd _accountdeck_env
        _accountdeck_env
        # <<< AccountDeck <<<

        """
        var text = (try? String(contentsOfFile: zshrcPath, encoding: .utf8)) ?? ""
        guard !text.contains(Self.hookMarker) else { shellLinked = true; return }
        if fm.fileExists(atPath: zshrcPath) {
            try? fm.copyItem(atPath: zshrcPath, toPath: zshrcPath + ".accountdeck-backup")
        }
        text += block
        try? text.write(toFile: zshrcPath, atomically: true, encoding: .utf8)
        shellLinked = true
        flash("Terminal connected. Open a new window once.")
    }

    // MARK: account status (read locally, never sent anywhere)

    func refresh() {
        for a in accounts {
            switch a.service {
            case .claude:
                let path = a.isDefault ? home + "/.claude.json" : a.dir + "/.claude.json"
                let email = readJSON(path)?["oauthAccount"].flatMap { ($0 as? [String: Any])?["emailAddress"] as? String }
                details[a.id] = email ?? "Not signed in"
                signedIn[a.id] = email != nil
            case .codex:
                let json = readJSON(a.dir + "/auth.json")
                if let tokens = json?["tokens"] as? [String: Any], let idt = tokens["id_token"] as? String,
                   let email = jwtEmail(idt) {
                    details[a.id] = email; signedIn[a.id] = true
                } else if let key = json?["OPENAI_API_KEY"] as? String, !key.isEmpty {
                    details[a.id] = "API key"; signedIn[a.id] = true
                } else {
                    details[a.id] = "Not signed in"; signedIn[a.id] = false
                }
            case .desktop:
                if isActive(a) {
                    let on = fm.fileExists(atPath: desktopSupport + "/Cookies")
                    details[a.id] = on ? "Open in Claude now" : "Not signed in"
                    signedIn[a.id] = on
                } else {
                    let saved = desktopSlotHasLogin(a)
                    details[a.id] = saved ? "Saved login" : "Sign in after switching"
                    signedIn[a.id] = saved
                }
            case .chatgpt:
                let used = fm.fileExists(atPath: a.dir + "/Default")
                details[a.id] = used ? "Own browser window" : "Not opened yet"
                signedIn[a.id] = used
            }
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    func readJSON(_ path: String) -> [String: Any]? {
        guard let d = fm.contents(atPath: path) else { return nil }
        return (try? JSONSerialization.jsonObject(with: d)) as? [String: Any]
    }

    func jwtEmail(_ jwt: String) -> String? {
        let parts = jwt.split(separator: ".")
        guard parts.count > 1 else { return nil }
        var b64 = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b64.count % 4 != 0 { b64 += "=" }
        guard let d = Data(base64Encoded: b64),
              let obj = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] else { return nil }
        return obj["email"] as? String
    }

    // MARK: actions

    func select(_ a: Account) {
        if a.service == .desktop { switchDesktop(to: a); return }
        if a.service == .chatgpt {
            active[a.service.rawValue] = a.id
            save()
            openBrowser(a)
            flash("Opening ChatGPT as \(a.name)")
            return
        }
        guard !isActive(a) else { return }
        active[a.service.rawValue] = a.id
        save(); writeEnv()
        flash(shellLinked ? "\(a.service.title) → \(a.name). Next command uses it."
                          : "\(a.service.title) → \(a.name). Connect Terminal to apply it.")
    }

    func add(service: Service, name: String) {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        var slug = clean.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" }.reduce("") { $0 + String($1) }
        if slug.isEmpty { slug = "account" }
        var id = "\(service.rawValue)-\(slug)"; var n = 2
        while accounts.contains(where: { $0.id == id }) { id = "\(service.rawValue)-\(slug)-\(n)"; n += 1 }
        let dir = "\(root)/\(service.rawValue)/\(id)"
        try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let acc = Account(id: id, service: service, name: clean, isDefault: false, dir: dir)
        accounts.append(acc)
        save()
        screen = .list
        refresh()
        if service == .desktop { switchDesktop(to: acc, confirmed: true) } else { signIn(acc) }
    }

    /// "Get exact usage" on a Claude Desktop account: one Claude Code sign-in with that
    /// Claude account, in a folder kept just for reading its usage.
    func getExactUsage(_ a: Account) {
        let dir = ExactUsage.linkDir(a)
        try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        UserDefaults.standard.set(true, forKey: ExactUsage.askedKey)
        UserDefaults.standard.set(true, forKey: ExactUsage.onKey)
        runInTerminal(title: "Exact usage — \(a.name)", lines: [
            "export CLAUDE_CONFIG_DIR=\(shq(dir))",
            "echo 'Sign in with the Claude account you use as \"\(a.name)\" in Claude Desktop.'",
            "echo 'AccountDeck only uses this to read its usage. When it says you are signed in, type /exit.'",
            "echo",
            "if ! command -v claude >/dev/null; then echo 'Claude Code is not installed. Install it from https://claude.com/claude-code'; exit 1; fi",
            "claude /login",
        ])
        flash("Sign in as \(a.name) in Terminal")
    }

    func signIn(_ a: Account) {
        switch a.service {
        case .desktop:
            switchDesktop(to: a)
        case .claude:
            runInTerminal(title: "Claude Code — \(a.name)", lines: [
                a.isDefault ? "unset CLAUDE_CONFIG_DIR" : "export CLAUDE_CONFIG_DIR=\(shq(a.dir))",
                "echo 'Signing in to Claude Code as \"\(a.name)\". Finish the login, then type /exit.'",
                "echo",
                "claude /login",
            ])
        case .codex:
            runInTerminal(title: "Codex — \(a.name)", lines: [
                a.isDefault ? "unset CODEX_HOME" : "export CODEX_HOME=\(shq(a.dir))",
                "echo 'Signing in to Codex as \"\(a.name)\".'",
                "echo",
                "if ! command -v codex >/dev/null; then echo 'Codex CLI is not installed. Install it with: npm i -g @openai/codex'; exit 1; fi",
                "codex login",
            ])
        case .chatgpt:
            openBrowser(a)
        }
    }

    func rename(_ a: Account) { renaming = a }

    func applyRename(_ a: Account, to name: String) {
        let v = name.trimmingCharacters(in: .whitespaces)
        renaming = nil
        guard !v.isEmpty, let i = accounts.firstIndex(where: { $0.id == a.id }) else { return }
        accounts[i].name = v
        save()
    }

    func remove(_ a: Account) {
        guard !a.isDefault else { return }
        if a.service == .desktop && isActive(a) {
            flash("Switch Claude to another account first"); return
        }
        confirm = Confirm(title: "Remove “\(a.name)”?",
                          message: "Its saved login moves to the Trash, so you can restore it from there.",
                          button: "Move to Trash", hue: .red, destructive: true) { [weak self] in
            self?.reallyRemove(a)
        }
    }

    func reallyRemove(_ a: Account) {
        try? fm.trashItem(at: URL(fileURLWithPath: a.dir), resultingItemURL: nil)
        accounts.removeAll { $0.id == a.id }
        if active[a.service.rawValue] == a.id {
            active[a.service.rawValue] = accounts.first(where: { $0.service == a.service && $0.isDefault })?.id
        }
        save(); writeEnv()
        flash("Removed \(a.name)")
    }

    func reveal(_ a: Account) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: a.dir)])
    }

    func openTerminal() {
        runInTerminal(title: "AccountDeck", lines: [
            "source \(shq(envPath))",
            "echo \"Claude Code: \(activeName(.claude))   ·   Codex: \(activeName(.codex))\"",
            "exec $SHELL -l",
        ])
    }

    func activeName(_ s: Service) -> String {
        accounts.first(where: { $0.id == active[s.rawValue] })?.name ?? "Main"
    }

    func toggleLaunchAtLogin() {
        do {
            if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
            else { try SMAppService.mainApp.register() }
        } catch { flash("Could not change launch at login") }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    // MARK: Claude Desktop
    //
    // Claude Desktop keeps its login in Cookies and in config.json ("oauth:tokenCacheV2").
    // Switching = quit Claude, save those files into the current account's folder,
    // put the chosen account's files back, reopen Claude.

    let desktopBundle = "com.anthropic.claudefordesktop"
    var desktopSupport: String { home + "/Library/Application Support/Claude" }
    let desktopFiles = ["Cookies", "Cookies-journal", "config.json"]

    func desktopSlotHasLogin(_ a: Account) -> Bool { fm.fileExists(atPath: a.dir + "/Cookies") }

    func switchDesktop(to a: Account, confirmed: Bool = false) {
        guard !switching else { return }
        guard !isActive(a) else {
            if !(signedIn[a.id] ?? false) { relaunchDesktop() }
            return
        }
        guard confirmed else {
            confirm = Confirm(
                title: "Switch Claude to “\(a.name)”?",
                message: desktopSlotHasLogin(a)
                    ? "Claude restarts signed in as \(a.name). Anything running in Claude stops."
                    : "Claude restarts and asks you to sign in. Use your \(a.name) account. Anything running in Claude stops.",
                button: "Restart Claude", hue: Service.desktop.hue) { [weak self] in
                self?.switchDesktop(to: a, confirmed: true)
            }
            return
        }

        let current = accounts.first(where: { $0.id == active[Service.desktop.rawValue] })
        var codeFollowed: String? = nil
        switching = true
        flash("Closing Claude…")
        Task { @MainActor in
            defer { switching = false }
            guard await quitDesktop() else {
                flash("Claude didn't close. Quit it, then try again."); return
            }
            let fromUuid = accountUuid(inConfig: desktopSupport + "/config.json")
            var synced: ChatSync.Result?
            do {
                try swapDesktopFiles(from: current, to: a)
                active[Service.desktop.rawValue] = a.id
                save()
                codeFollowed = followDesktopInCode()
                if carryChat, let to = accountUuid(inConfig: desktopSupport + "/config.json"), to != fromUuid {
                    synced = syncChats(to: to)
                }
            } catch {
                flash("Switch failed: \(error.localizedDescription)")
            }
            refresh()
            relaunchDesktop()
            if let s = synced, s.added + s.updated + s.removed > 0 {
                var parts: [String] = []
                if s.added > 0 { parts.append("\(s.added) new chat\(s.added == 1 ? "" : "s")") }
                if s.updated > 0 { parts.append("\(s.updated) updated") }
                if s.removed > 0 { parts.append("\(s.removed) deleted") }
                flash("Claude → \(a.name), " + parts.joined(separator: ", ") + (codeFollowed.map { ", Claude Code → \($0)" } ?? ""))
            } else {
                flash(desktopSlotHasLogin(a) || signedIn[a.id] == true
                      ? "Claude → \(a.name)" + (codeFollowed.map { ", Claude Code → \($0)" } ?? "") : "Sign in to Claude as \(a.name)")
            }
        }
    }

    /// Brings the account you switch to up to date with the chats you made, changed or
    /// deleted on your other accounts. The first time, all chat lists are backed up whole.
    func syncChats(to uuid: String) -> ChatSync.Result {
        let sessions = desktopSupport + "/claude-code-sessions"
        let firstBackup = root + "/chat-lists-backup"
        if !fm.fileExists(atPath: firstBackup) { try? fm.copyItem(atPath: sessions, toPath: firstBackup) }
        return ChatSync.sync(sessions: sessions, to: uuid, keep: root + "/moved-chats")
    }

    /// After a Claude Desktop switch, Claude Code follows: the Claude Code login that belongs to the same Claude
    /// account becomes the active one (and env.sh says so), so Terminal and apps that read AccountDeck's state, such as
    /// Kliq, use it too. Returns that login's name when it switched; nil when there is no such login or it was active.
    func followDesktopInCode() -> String? {
        guard let uuid = accountUuid(inConfig: desktopSupport + "/config.json"),
              let match = accounts(for: .claude).first(where: {
                  let state = $0.isDefault ? home + "/.claude.json" : $0.dir + "/.claude.json"
                  return (readJSON(state)?["oauthAccount"] as? [String: Any])?["accountUuid"] as? String == uuid
              }),
              !isActive(match) else { return nil }
        active[Service.claude.rawValue] = match.id
        save(); writeEnv()
        return match.name
    }

    func accountUuid(inConfig path: String) -> String? {
        readJSON(path)?["lastKnownAccountUuid"] as? String
    }

    /// Moves your most recently opened Code-tab chat into the new account's chat list, so it
    /// comes up there and you can carry on. Claude keeps these chats per account in
    /// claude-code-sessions/<account>/<organization>/local_*.json; the conversation itself lives
    /// in ~/.claude/projects and is shared. A copy is kept in ~/.accountdeck/moved-chats.
    /// Returns the chat's title, or nil when nothing was moved.
    func carryLastChat(from: String?, to: String?, sup supOverride: String? = nil, base: String? = nil) -> String? {
        guard let from, let to, from != to else { return nil }
        let sessions = (supOverride ?? desktopSupport) + "/claude-code-sessions"

        func chats(in account: String) -> [(path: String, json: [String: Any])] {
            let accDir = "\(sessions)/\(account)"
            let orgs = (try? fm.contentsOfDirectory(atPath: accDir)) ?? []
            return orgs.flatMap { org -> [(String, [String: Any])] in
                let dir = "\(accDir)/\(org)"
                let files = (try? fm.contentsOfDirectory(atPath: dir)) ?? []
                return files.filter { $0.hasPrefix("local_") && $0.hasSuffix(".json") }
                    .compactMap { f in readJSON("\(dir)/\(f)").map { ("\(dir)/\(f)", $0) } }
            }
        }
        func num(_ v: Any?) -> Double { (v as? NSNumber)?.doubleValue ?? 0 }

        // The chat you were in last.
        guard let last = chats(in: from)
            .filter({ ($0.json["isArchived"] as? Bool) != true })
            .max(by: { num($0.json["lastFocusedAt"]) < num($1.json["lastFocusedAt"]) }) else { return nil }

        // Where the new account keeps its chats: the organization folder it used most recently.
        let toDir = "\(sessions)/\(to)"
        let orgs = ((try? fm.contentsOfDirectory(atPath: toDir)) ?? []).filter {
            var isDir: ObjCBool = false
            return fm.fileExists(atPath: "\(toDir)/\($0)", isDirectory: &isDir) && isDir.boolValue
        }
        func newest(_ org: String) -> Date {
            let dir = "\(toDir)/\(org)"
            let files = ((try? fm.contentsOfDirectory(atPath: dir)) ?? []).filter { $0.hasPrefix("local_") }
            let dates = files.compactMap { (try? fm.attributesOfItem(atPath: "\(dir)/\($0)"))?[.modificationDate] as? Date }
            return dates.max() ?? .distantPast
        }
        guard let org = orgs.max(by: { newest($0) < newest($1) }) else { return nil }

        let name = (last.path as NSString).lastPathComponent
        let dest = "\(toDir)/\(org)/\(name)"
        guard !fm.fileExists(atPath: dest) else { return nil }

        // Safety copy, then move it and put it at the top of the list.
        let keep = (base ?? root) + "/moved-chats"
        try? fm.createDirectory(atPath: keep, withIntermediateDirectories: true)
        try? fm.removeItem(atPath: "\(keep)/\(name)")
        try? fm.copyItem(atPath: last.path, toPath: "\(keep)/\(name)")
        var json = last.json
        let now = Date().timeIntervalSince1970 * 1000
        json["lastFocusedAt"] = now
        guard let data = try? JSONSerialization.data(withJSONObject: json, options: []),
              (try? data.write(to: URL(fileURLWithPath: dest))) != nil else { return nil }
        try? fm.removeItem(atPath: last.path)
        return (json["title"] as? String) ?? "your last chat"
    }

    func quitDesktop() async -> Bool {
        func running() -> [NSRunningApplication] {
            NSRunningApplication.runningApplications(withBundleIdentifier: desktopBundle)
        }
        if running().isEmpty { return true }
        running().forEach { $0.terminate() }
        for _ in 0..<120 {                       // wait up to 60 s (Claude may ask to confirm)
            try? await Task.sleep(nanoseconds: 500_000_000)
            if running().isEmpty {
                try? await Task.sleep(nanoseconds: 800_000_000)   // let it finish writing files
                return true
            }
        }
        return false
    }

    func swapDesktopFiles(from current: Account?, to target: Account,
                          sup supOverride: String? = nil, base: String? = nil) throws {
        let sup = supOverride ?? desktopSupport
        // One-time safety copy of the login you had before AccountDeck ever switched.
        let backup = (base ?? root) + "/desktop/_original-backup"
        if !fm.fileExists(atPath: backup) {
            try fm.createDirectory(atPath: backup, withIntermediateDirectories: true)
            for f in desktopFiles where fm.fileExists(atPath: "\(sup)/\(f)") {
                try fm.copyItem(atPath: "\(sup)/\(f)", toPath: "\(backup)/\(f)")
            }
        }
        // Save the login that is in Claude right now.
        if let cur = current {
            try fm.createDirectory(atPath: cur.dir, withIntermediateDirectories: true)
            for f in desktopFiles {
                try? fm.removeItem(atPath: "\(cur.dir)/\(f)")
                if fm.fileExists(atPath: "\(sup)/\(f)") {
                    try fm.copyItem(atPath: "\(sup)/\(f)", toPath: "\(cur.dir)/\(f)")
                }
            }
        }
        // Put the chosen account's login in place.
        if desktopSlotHasLogin(target) {
            for f in desktopFiles {
                try? fm.removeItem(atPath: "\(sup)/\(f)")
                if fm.fileExists(atPath: "\(target.dir)/\(f)") {
                    try fm.copyItem(atPath: "\(target.dir)/\(f)", toPath: "\(sup)/\(f)")
                }
            }
        } else {
            // New account: sign out but keep your app settings.
            try? fm.removeItem(atPath: sup + "/Cookies")
            try? fm.removeItem(atPath: sup + "/Cookies-journal")
            let cfgPath = sup + "/config.json"
            if var cfg = readJSON(cfgPath) {
                cfg.removeValue(forKey: "oauth:tokenCacheV2")
                cfg.removeValue(forKey: "lastKnownAccountUuid")
                let data = try JSONSerialization.data(withJSONObject: cfg, options: [.prettyPrinted])
                try data.write(to: URL(fileURLWithPath: cfgPath))
            }
        }
    }

    func relaunchDesktop() {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: desktopBundle) else {
            flash("Claude Desktop is not installed"); return
        }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }

    // MARK: helpers

    func shq(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    /// Writes a .command script and opens it in Terminal (no Automation permission needed).
    func runInTerminal(title: String, lines: [String]) {
        let dir = root + "/run"
        try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let path = "\(dir)/\(UUID().uuidString.prefix(8)).command"
        let script = (["#!/bin/zsh -il", "printf '\\e]0;\(title)\\a'", "rm -f \(shq(path))"] + lines).joined(separator: "\n") + "\n"
        fm.createFile(atPath: path, contents: script.data(using: .utf8),
                      attributes: [.posixPermissions: 0o755])
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }

    func openBrowser(_ a: Account) {
        let candidates = ["Google Chrome", "Brave Browser", "Microsoft Edge", "Chromium"]
        guard let app = candidates.first(where: { fm.fileExists(atPath: "/Applications/\($0).app") }) else {
            flash("Install Chrome or Brave to use separate ChatGPT accounts"); return
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        p.arguments = ["-na", app, "--args", "--user-data-dir=\(a.dir)",
                       "--no-first-run", "--no-default-browser-check", "https://chatgpt.com"]
        try? p.run()
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in self?.refresh() }
    }

    func flash(_ text: String) {
        withAnimation(.easeOut(duration: 0.18)) { toast = text }
        let current = text
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.6) { [weak self] in
            guard self?.toast == current else { return }
            withAnimation(.easeIn(duration: 0.2)) { self?.toast = nil }
        }
    }
}

// MARK: - Views
//
// Look: native macOS. Grouped inset cards like System Settings, SF Symbol icon tiles,
// monogram avatars like Contacts, menu-style footer rows like the Wi-Fi menu, and
// confirmations styled as macOS alerts.

extension Service {
    var symbol: String {
        switch self {
        case .desktop: return "macwindow"
        case .claude: return "terminal.fill"
        case .codex: return "curlybraces"
        case .chatgpt: return "globe"
        }
    }
}

/// The app's mark: two overlapping rings, one per tool, in their own colours.
struct Mark: View {
    var size: CGFloat = 18
    var body: some View {
        ZStack {
            Circle().fill(Service.claude.hue).frame(width: size * 0.68, height: size * 0.68)
                .offset(x: -size * 0.17)
            Circle().fill(Service.codex.hue).frame(width: size * 0.68, height: size * 0.68)
                .offset(x: size * 0.17).opacity(0.92)
        }
        .frame(width: size, height: size)
    }
}

/// The real app icon, as Finder and the Dock show it.
struct AppGlyph: View {
    var size: CGFloat = 30
    var body: some View {
        Image(nsImage: NSApp?.applicationIconImage ?? NSImage())
            .resizable().interpolation(.high)
            .frame(width: size, height: size)
    }
}

/// A System Settings style icon: white SF Symbol on a rounded, softly graded tile.
struct IconTile: View {
    let symbol: String
    let hue: Color
    var size: CGFloat = 22
    var body: some View {
        let shape = RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
        shape
            .fill(LinearGradient(colors: [hue.opacity(0.78), hue], startPoint: .top, endPoint: .bottom))
            .overlay(Image(systemName: symbol)
                .font(.system(size: size * 0.48, weight: .semibold))
                .foregroundStyle(.white))
            .overlay(shape.strokeBorder(Color.white.opacity(0.22), lineWidth: 0.5))
            .frame(width: size, height: size)
            .shadow(color: .black.opacity(0.12), radius: 0.5, y: 0.5)
    }
}

/// A Contacts style monogram.
struct Avatar: View {
    let name: String
    let hue: Color
    var size: CGFloat = 30
    var body: some View {
        Circle()
            .fill(LinearGradient(colors: [hue.opacity(0.55), hue.opacity(0.95)], startPoint: .top, endPoint: .bottom))
            .overlay(Text(String(name.prefix(1)).uppercased())
                .font(.system(size: size * 0.42, weight: .semibold, design: .rounded))
                .foregroundStyle(.white))
            .frame(width: size, height: size)
    }
}

/// An inset grouped card, as in System Settings.
struct GroupCard<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        VStack(spacing: 0) { content }
            .background(shape.fill(Color.primary.opacity(0.045)))
            .clipShape(shape)
            .overlay(shape.strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
    }
}

struct RowDivider: View {
    var inset: CGFloat = 50
    var body: some View { Divider().opacity(0.7).padding(.leading, inset) }
}

// MARK: - Motion
//
// Two curves, as in the stageshow rules: travel (things that move between places) and
// arrive (things that come from nowhere). Feedback stays as quick as the system's own.

enum Motion {
    static let travel = Animation.timingCurve(0.45, 0, 0.1, 1, duration: 0.45)
    static let arrive = Animation.timingCurve(0.25, 0.8, 0.25, 1, duration: 0.8)
    static let page = Animation.timingCurve(0.25, 0.8, 0.25, 1, duration: 0.32)
    static let quick = Animation.easeOut(duration: 0.15)
    /// The menu opens at system speed: a short settle, never a wait.
    static let menu = Animation.timingCurve(0.25, 0.8, 0.25, 1, duration: 0.28)
}

private struct PanelOpenKey: EnvironmentKey { static let defaultValue = true }
extension EnvironmentValues {
    /// True while the menu bar panel is open; sections arrive when it turns true.
    var panelOpen: Bool {
        get { self[PanelOpenKey.self] }
        set { self[PanelOpenKey.self] = newValue }
    }
}

/// Rises 6 pt into place, staggered 60 ms per step in reading order.
struct Arrive: ViewModifier {
    let index: Int
    @Environment(\.panelOpen) private var open
    func body(content: Content) -> some View {
        content
            .opacity(open ? 1 : 0)
            .offset(y: open ? 0 : 4)
            .animation(Motion.menu.delay(Double(index) * 0.025), value: open)
    }
}
extension View { func arrive(_ index: Int) -> some View { modifier(Arrive(index: index)) } }

struct PressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

// MARK: - Usage limits
//
// Read only from files on this Mac:
//  • Claude Code: its status line receives the 5-hour and weekly limits; a tiny hook
//    (claude-status.sh) saves them to <config dir>/.accountdeck-status.json. Turned on from
//    Customize, per account, never over a status line you already have.
//  • Codex: every session log records rate_limits; the newest one is read.

struct Usage: Equatable {
    var percent: Double
    var resetsAt: Date?
    var window: String
    var second: (percent: Double, resetsAt: Date?, window: String)?
    /// The reset time is worked out from Claude Desktop's usage history, not reported.
    var estimated = false
    /// When the numbers were read, if they can be old.
    var asOf: Date?

    /// The limit to show, as chosen in Customize: "auto" (5-hour, or weekly when that's the
    /// only one in use), "5h" or "weekly". Falls back to what there is.
    func view(_ pref: String) -> Usage {
        guard let s = second, pref != "auto" else { return self }
        let mainIsFive = window == "5-hour", secondIsFive = s.window == "5-hour"
        let swap = (pref == "5h" && !mainIsFive && secondIsFive) || (pref == "weekly" && mainIsFive && !secondIsFive)
        guard swap else { return self }
        return Usage(percent: s.percent, resetsAt: s.resetsAt, window: s.window,
                     second: (percent: percent, resetsAt: resetsAt, window: window), estimated: estimated, asOf: asOf)
    }

    static func == (a: Usage, b: Usage) -> Bool {
        a.percent == b.percent && a.resetsAt == b.resetsAt && a.window == b.window
            && a.second?.percent == b.second?.percent && a.second?.resetsAt == b.second?.resetsAt
            && a.estimated == b.estimated && a.asOf == b.asOf
    }
}

@MainActor
final class UsageStore: ObservableObject {
    static let shared = UsageStore()
    @Published var usage: [String: Usage] = [:]
    @Published var claudeTracking = false

    nonisolated let fm = FileManager.default
    nonisolated var home: String { fm.homeDirectoryForCurrentUser.path }
    nonisolated var scriptPath: String { home + "/.accountdeck/claude-status.sh" }

    nonisolated func claudeDir(_ a: Account) -> String { a.isDefault ? home + "/.claude" : a.dir }
    nonisolated func codexDir(_ a: Account) -> String { a.isDefault ? home + "/.codex" : a.dir }

    private var lastRefresh = Date.distantPast
    private var refreshing = false
    private var pending = false                 // a forced refresh arrived while one was running
    private var accounts: [Account] = []

    // Live updates: FSEvents on every folder a reading comes from, debounced, so a new
    // status file shows within about a second without reopening anything.
    private var stream: FSEventStreamRef?
    private var watched: [String] = []
    private var debounce: DispatchWorkItem?
    private var backup: Timer?
    private var poll: Timer?

    // Exact readings from Anthropic (see ExactUsage.swift): Claude account uuid -> reading, and when each
    // account was last asked, so the server is asked at most once a minute per account.
    private var server: [String: Usage] = [:]
    private var lastAsked: [String: Date] = [:]
    private var asking = false

    func askServer(_ accounts: [Account]) {
        guard ExactUsage.enabled else { if !server.isEmpty { server = [:] }; return }
        guard !asking else { return }
        // Claude Code accounts, plus the logins made for Claude Desktop accounts.
        let due = accounts.filter {
            ($0.service == .claude || ($0.service == .desktop && ExactUsage.hasLink($0)))
                && Date().timeIntervalSince(lastAsked[$0.id] ?? .distantPast) > 60
        }
        guard !due.isEmpty else { return }
        asking = true
        for a in due { lastAsked[a.id] = Date() }
        let jobs = due.map { a in a.service == .desktop ? (a.id, ExactUsage.linkDir(a), false) : (a.id, claudeDir(a), a.isDefault) }
        Task.detached(priority: .utility) {
            var got: [String: Usage] = [:], problems: [String] = []
            for (id, dir, def) in jobs {
                switch await ExactUsage.fetch(configDir: dir, isDefault: def) {
                case .usage(let u, let account): got[account] = u; _ = id
                case .failed(let why): problems.append(why)
                }
            }
            let status = got.isEmpty ? (problems.first ?? "Not working")
                : "Working · \(got.count) account\(got.count == 1 ? "" : "s")" + (problems.isEmpty ? "" : " · \(problems[0])")
            await MainActor.run {
                let s = UsageStore.shared
                s.asking = false
                UserDefaults.standard.set(status, forKey: ExactUsage.statusKey)
                guard !got.isEmpty else { return }
                for (k, v) in got { s.server[k] = v }
                s.refresh(s.accounts, force: true)
            }
        }
    }

    /// Folders whose changes can mean a new reading.
    func watchPaths(_ accounts: [Account]) -> [String] {
        var p = Set<String>()
        for a in accounts {
            switch a.service {
            case .claude: p.insert(claudeDir(a))
            case .desktop: p.insert(home + "/.claude")
            case .codex: p.insert(codexDir(a) + "/sessions")
            default: break
            }
        }
        if accounts.contains(where: { $0.service == .desktop }) {
            p.insert(home + "/Library/Application Support/Claude")
        }
        // FSEvents needs a folder that exists; fall back to the nearest parent that does.
        return p.map { var d = $0; while !fm.fileExists(atPath: d) && d.count > 1 { d = (d as NSString).deletingLastPathComponent }; return d }
            .reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }.sorted()
    }

    /// Only files that hold readings count; the rest of these folders changes all the time.
    nonisolated static func matters(_ path: String) -> Bool {
        path.contains("/.accountdeck-status")
            || path.hasSuffix("/plan-usage-history.json")
            || path.contains("/claude-code-sessions/")
            || (path.contains("/sessions/") && path.hasSuffix(".jsonl"))
    }

    func watch(_ accounts: [Account]) {
        self.accounts = accounts
        if poll == nil {
            // Exact readings are asked for about once a minute, menu open or not.
            poll = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { _ in
                Task { @MainActor in let s = UsageStore.shared; s.askServer(s.accounts) }
            }
        }
        if backup == nil {
            // Backup in case an event is missed: every 15 s while the menu or Dashboard is on screen.
            backup = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { _ in
                Task { @MainActor in
                    let s = UsageStore.shared
                    if NSApp.windows.contains(where: { $0.isVisible && $0.className != "NSStatusBarWindow" }) {
                        s.refresh(s.accounts, force: true)
                    }
                }
            }
        }
        let paths = watchPaths(accounts)
        guard paths != watched else { return }
        if let s = stream { FSEventStreamStop(s); FSEventStreamInvalidate(s); FSEventStreamRelease(s); stream = nil }
        watched = paths
        guard !paths.isEmpty else { return }
        let cb: FSEventStreamCallback = { _, _, count, eventPaths, _, _ in
            let list = unsafeBitCast(eventPaths, to: NSArray.self)
            var hit = false
            for i in 0..<count { if let p = list[i] as? String, UsageStore.matters(p) { hit = true; break } }
            guard hit else { return }
            Task { @MainActor in UsageStore.shared.changed() }
        }
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagNoDefer)
        guard let s = FSEventStreamCreate(nil, cb, nil, paths as CFArray,
                                          FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.1, flags) else { return }
        FSEventStreamSetDispatchQueue(s, DispatchQueue.global(qos: .utility))
        FSEventStreamStart(s)
        stream = s
    }

    /// A reading file changed: wait for the burst to settle (~0.4 s), then read.
    func changed() {
        debounce?.cancel()
        let w = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.refresh(self.accounts, force: true)
        }
        debounce = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: w)
    }

    /// Reads usage in the background so opening the menu never waits on it.
    /// Repeats within 20 seconds reuse what is already on screen, unless forced
    /// (a watched file changed).
    func refresh(_ accounts: [Account], force: Bool = false) {
        watch(accounts)
        askServer(accounts)
        if !force && Date().timeIntervalSince(lastRefresh) < 20 { return }
        guard !refreshing else { if force { pending = true }; return }
        refreshing = true
        lastRefresh = Date()
        // Keep the hook script current (older copies did not save per session).
        if fm.fileExists(atPath: scriptPath),
           (try? String(contentsOfFile: scriptPath, encoding: .utf8)) != Self.script {
            writeScript()
        }
        let exact = ExactUsage.enabled ? server : [:]
        Task.detached(priority: .utility) { [self] in
            let owners = self.desktopSessionOwners()
            var out: [String: Usage] = [:]
            var tracking = true, anyClaude = false
            var claudeId: [String: String] = [:]          // account id -> Claude account uuid
            for a in accounts {
                switch a.service {
                case .claude:
                    anyClaude = true
                    if !self.hasHook(a) { tracking = false }
                    claudeId[a.id] = self.claudeAccountUuid(a)
                    // The newer of the status-line file and Anthropic's exact reading.
                    let file = self.claudeUsage(a, owners: owners), live = claudeId[a.id].flatMap { exact[$0] }
                    if let u = [file, live].compactMap({ $0 }).max(by: { ($0.asOf ?? .distantPast) < ($1.asOf ?? .distantPast) }) {
                        out[a.id] = u
                    }
                case .desktop:
                    let uuid = self.desktopUuid(a)
                    claudeId[a.id] = uuid
                    if let uuid, let u = exact[uuid] ?? self.desktopUsage(uuid: uuid, owners: owners) { out[a.id] = u }
                case .codex:
                    if let u = self.codexUsage(a) { out[a.id] = u }
                default: break
                }
            }
            // A Claude Code login and a Claude Desktop login can be the same Claude account,
            // which has one set of limits. Show the freshest reading on both.
            for ids in Dictionary(grouping: claudeId.keys, by: { claudeId[$0]! }).values where ids.count > 1 {
                // Exact readings (Claude Code) beat Claude Desktop's estimates unless an estimate is
                // more than 10 minutes newer.
                func rank(_ u: Usage) -> Date { (u.asOf ?? .distantPast).addingTimeInterval(u.estimated ? -600 : 0) }
                let best = ids.compactMap { out[$0] }.max { rank($0) < rank($1) }
                if let best { for id in ids { out[id] = best } }
            }
            let result = out, on = anyClaude && tracking
            await MainActor.run {
                self.refreshing = false
                self.claudeTracking = on
                if result != self.usage { withAnimation(Motion.travel) { self.usage = result } }
                if self.pending { self.pending = false; self.refresh(self.accounts, force: true) }
            }
        }
    }

    // Claude Desktop runs its Code-tab chats through Claude Code with the default config
    // folder, and records which CLI session belongs to which Claude account. That lets the
    // per-session status files be split by account.

    nonisolated var desktopSessions: String { home + "/Library/Application Support/Claude/claude-code-sessions" }

    /// CLI session id → the Claude account (uuid) whose Desktop chat it is.
    nonisolated func desktopSessionOwners() -> [String: String] {
        var map: [String: String] = [:]
        for acc in (try? fm.contentsOfDirectory(atPath: desktopSessions)) ?? [] {
            let accDir = desktopSessions + "/" + acc
            for org in (try? fm.contentsOfDirectory(atPath: accDir)) ?? [] {
                let dir = accDir + "/" + org
                for f in (try? fm.contentsOfDirectory(atPath: dir)) ?? [] where f.hasPrefix("local_") && f.hasSuffix(".json") {
                    guard let d = fm.contents(atPath: dir + "/" + f),
                          let j = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any],
                          let sid = j["cliSessionId"] as? String else { continue }
                    map[sid] = acc
                }
            }
        }
        return map
    }

    nonisolated func desktopUuid(_ a: Account) -> String? {
        let state = (fm.contents(atPath: home + "/.accountdeck/state.json"))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        let active = (state?["active"] as? [String: String])?["desktop"] == a.id
        let cfg = active ? home + "/Library/Application Support/Claude/config.json" : a.dir + "/config.json"
        return fm.contents(atPath: cfg)
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }?["lastKnownAccountUuid"] as? String
    }

    /// Status files of one config folder, newest first: (session id, path).
    nonisolated func statusFiles(_ dir: String) -> [(String, String)] {
        let sd = dir + "/.accountdeck-status"
        let files = ((try? fm.contentsOfDirectory(atPath: sd)) ?? []).filter { $0.hasSuffix(".json") }
        return files.map { (String($0.dropLast(5)), sd + "/" + $0) }
            .map { ($0, $1, (try? fm.attributesOfItem(atPath: $1))?[.modificationDate] as? Date ?? .distantPast) }
            .sorted { $0.2 > $1.2 }
            .map { ($0.0, $0.1) }
    }

    nonisolated func desktopUsage(uuid: String, owners: [String: String]) -> Usage? {
        for (sid, path) in statusFiles(home + "/.claude") where owners[sid] == uuid {
            if let u = parseClaudeStatus(path) { return u }
        }
        return desktopPlanUsage(uuid: uuid)
    }

    /// Claude Desktop keeps a history of its plan usage (5-hour and weekly percentages) per
    /// organization in plan-usage-history.json. It doesn't keep the reset time, so the 5-hour
    /// reset is estimated: five hours after usage started climbing in the current window.
    nonisolated func desktopPlanUsage(uuid: String) -> Usage? {
        let orgs = Set(((try? fm.contentsOfDirectory(atPath: desktopSessions + "/" + uuid)) ?? []))
        guard !orgs.isEmpty,
              let d = fm.contents(atPath: home + "/Library/Application Support/Claude/plan-usage-history.json"),
              let j = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any],
              let all = j["samples"] as? [[String: Any]] else { return nil }
        typealias Sample = (t: Date, org: String, fh: Double, sd: Double)
        let samples: [Sample] = all.compactMap { s in
            guard let org = s["org"] as? String, orgs.contains(org),
                  let t = (s["t"] as? NSNumber)?.doubleValue, let u = s["u"] as? [String: Any] else { return nil }
            return (Date(timeIntervalSince1970: t / 1000), org,
                    (u["fh"] as? NSNumber)?.doubleValue ?? 0, (u["sd"] as? NSNumber)?.doubleValue ?? 0)
        }.sorted { $0.t < $1.t }
        // The organization this account used most recently.
        guard let newestOrg = samples.last?.org else { return nil }
        // When did the current 5-hour window start? The first reading above zero after a reset
        // (a reading of zero, a drop, or five hours passing). Claude Desktop sometimes saves 0
        // right after an account switch, before it has the real figure: a 0 inside a window that
        // can't have ended yet is skipped, and so is anything that isn't a full reading.
        let five: TimeInterval = 5 * 3600
        var start: Date?, prev: Sample?
        var trusted: [Sample] = []
        for s in samples where s.org == newestOrg {
            if let p = prev, let st = start, s.fh <= 0, p.fh > 0, s.t < st.addingTimeInterval(five), s.sd >= p.sd {
                continue                                   // a false zero
            }
            if let p = prev, s.fh <= 0, p.fh > 0, s.t < p.t.addingTimeInterval(five), s.sd > p.sd + 0.5 {
                continue                                   // weekly use went up within 5 hours, so the 5-hour figure can't be 0
            }
            if s.fh <= 0 { start = nil }
            else if start == nil || s.t >= start!.addingTimeInterval(five) || (prev.map { s.fh < $0.fh } ?? false) { start = s.t }
            prev = s
            trusted.append(s)
        }
        guard let last = trusted.last, Date().timeIntervalSince(last.t) < 7 * 86400 else { return nil }
        let now = Date()
        if last.fh > 0, let st = start, st.addingTimeInterval(five) > now {
            return Usage(percent: last.fh, resetsAt: st.addingTimeInterval(five), window: "5-hour",
                         second: (percent: last.sd, resetsAt: weeklyReset(raw: all, org: newestOrg), window: "Weekly"), estimated: true, asOf: last.t)
        }
        // No 5-hour use right now: the weekly limit is the one that matters.
        return Usage(percent: last.sd, resetsAt: weeklyReset(raw: all, org: newestOrg), window: "Weekly",
                     second: (percent: 0, resetsAt: nil, window: "5-hour"), estimated: true, asOf: last.t)
    }

    /// Weekly limits reset on a fixed 7-day cycle. Every time the weekly figure fell back to
    /// near zero, the reset happened between those two readings; lining the drops up on the
    /// 7-day cycle narrows it down. Returns the middle of that range, moved to the next one ahead.
    nonisolated func weeklyReset(raw: [[String: Any]], org: String) -> Date? {
        let week: TimeInterval = 7 * 86400
        var prev: (Double, Double)?          // (time, sd) of the previous reading with data
        var ranges: [(Double, Double)] = []
        for s in raw where (s["org"] as? String) == org {
            guard let t = (s["t"] as? NSNumber)?.doubleValue,
                  let sd = ((s["u"] as? [String: Any])?["sd"] as? NSNumber)?.doubleValue else { continue }
            let ts = t / 1000
            if let p = prev, sd <= 10, p.1 - sd >= 3, ts - p.0 < 2 * 86400 { ranges.append((p.0, ts)) }
            prev = (ts, sd)
        }
        guard let latest = ranges.last else { return nil }
        var lo = latest.0, hi = latest.1
        for r in ranges.dropLast() {
            let k = ((latest.0 - r.0) / week).rounded()
            let a = r.0 + k * week, b = r.1 + k * week
            if max(lo, a) < min(hi, b) { lo = max(lo, a); hi = min(hi, b) }
        }
        var reset = (lo + hi) / 2
        let now = Date().timeIntervalSince1970
        while reset <= now { reset += week }
        return Date(timeIntervalSince1970: reset)
    }

    nonisolated static func windowName(minutes: Double) -> String {
        switch Int(minutes) {
        case 300: return "5-hour"
        case 10080: return "Weekly"
        case 43200: return "Monthly"
        default: return minutes >= 1440 ? "\(Int(minutes / 1440))-day" : "\(Int(minutes / 60))-hour"
        }
    }

    // Claude Code
    /// The newest status from this config folder that isn't a Claude Desktop chat
    /// (those belong to the Desktop account that ran them).
    nonisolated func claudeUsage(_ a: Account, owners: [String: String]) -> Usage? {
        let files = statusFiles(claudeDir(a))
        for (sid, path) in files where owners[sid] == nil {
            if let u = parseClaudeStatus(path) { return u }
        }
        // Before per-session files existed: the single latest file, unless it was a Desktop chat.
        let single = claudeDir(a) + "/.accountdeck-status.json"
        guard files.isEmpty, let d = fm.contents(atPath: single),
              let j = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any],
              owners[j["session_id"] as? String ?? ""] == nil else { return nil }
        return parseClaudeStatus(single)
    }

    nonisolated func parseClaudeStatus(_ path: String) -> Usage? {
        guard let d = fm.contents(atPath: path),
              let json = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] else { return nil }
        // No rate_limits yet (a session's first status line runs before its first reply):
        // nothing to say, so an older file with real numbers is used instead.
        guard let rl = json["rate_limits"] as? [String: Any], !rl.isEmpty else { return nil }
        func window(_ key: String, _ name: String) -> (Double, Date?, String)? {
            guard let w = rl[key] as? [String: Any], let p = (w["used_percentage"] as? NSNumber)?.doubleValue else { return nil }
            let r = (w["resets_at"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
            if let r, r < Date() { return nil }          // that window has reset since
            return (p, r, name)
        }
        let five = window("five_hour", "5-hour"), week = window("seven_day", "Weekly")
        let when = (try? fm.attributesOfItem(atPath: path))?[.modificationDate] as? Date
        guard let main = five ?? week else { return Usage(percent: 0, resetsAt: nil, window: "5-hour", asOf: when) }
        let other = five != nil ? week : nil
        return Usage(percent: main.0, resetsAt: main.1, window: main.2,
                     second: other.map { (percent: $0.0, resetsAt: $0.1, window: $0.2) }, asOf: when)
    }

    /// The Claude account behind a Claude Code login (same id Claude Desktop uses).
    nonisolated func claudeAccountUuid(_ a: Account) -> String? {
        let state = a.isDefault ? home + "/.claude.json" : a.dir + "/.claude.json"
        guard let d = fm.contents(atPath: state),
              let j = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] else { return nil }
        return (j["oauthAccount"] as? [String: Any])?["accountUuid"] as? String
    }

    nonisolated func hasHook(_ a: Account) -> Bool {
        guard let d = fm.contents(atPath: claudeDir(a) + "/settings.json"),
              let s = String(data: d, encoding: .utf8) else { return false }
        return s.contains("claude-status.sh")
    }

    /// Adds the status line hook to every Claude Code account that has no status line yet.
    /// Returns the names of accounts skipped because they already have their own.
    static let script = """
    #!/bin/sh
    # AccountDeck: saves Claude Code's usage limits for the menu bar, per session. Prints nothing.
    d="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
    input=$(cat)
    printf '%s' "$input" > "$d/.accountdeck-status.tmp" && mv -f "$d/.accountdeck-status.tmp" "$d/.accountdeck-status.json"
    sid=$(printf '%s' "$input" | sed -n 's/.*"session_id" *: *"\\([A-Za-z0-9_-]*\\)".*/\\1/p' | head -n 1)
    if [ -n "$sid" ]; then
      mkdir -p "$d/.accountdeck-status"
      printf '%s' "$input" > "$d/.accountdeck-status/.$sid.tmp" && mv -f "$d/.accountdeck-status/.$sid.tmp" "$d/.accountdeck-status/$sid.json"
      find "$d/.accountdeck-status" -name '*.json' -mtime +8 -delete 2>/dev/null
    fi

    """

    func writeScript() {
        fm.createFile(atPath: scriptPath, contents: Self.script.data(using: .utf8), attributes: [.posixPermissions: 0o755])
    }

    func enableClaudeTracking(_ accounts: [Account]) -> [String] {
        writeScript()
        var skipped: [String] = []
        for a in accounts where a.service == .claude && !hasHook(a) {
            let dir = claudeDir(a), path = dir + "/settings.json"
            try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
            var json: [String: Any] = [:]
            if let d = fm.contents(atPath: path) {
                guard let j = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] else { skipped.append(a.name); continue }
                json = j
                if !fm.fileExists(atPath: path + ".accountdeck-backup") {
                    try? fm.copyItem(atPath: path, toPath: path + ".accountdeck-backup")
                }
            }
            if json["statusLine"] != nil { skipped.append(a.name); continue }
            json["statusLine"] = ["type": "command", "command": "sh \"$HOME/.accountdeck/claude-status.sh\""]
            if let data = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: URL(fileURLWithPath: path))
            }
        }
        refresh(accounts, force: true)
        return skipped
    }

    // Codex
    nonisolated func codexUsage(_ a: Account) -> Usage? {
        let root = codexDir(a) + "/sessions"
        guard let en = fm.enumerator(atPath: root) else { return nil }
        var files: [String] = []
        while let p = en.nextObject() as? String, files.count < 4000 {
            if p.hasSuffix(".jsonl") { files.append(p) }
        }
        // Newest by when it was last written: a long session started days ago can hold the latest reading.
        func mtime(_ f: String) -> Date { ((try? fm.attributesOfItem(atPath: root + "/" + f))?[.modificationDate] as? Date) ?? .distantPast }
        let newest = files.map { ($0, mtime($0)) }.sorted { $0.1 > $1.1 }.prefix(6).map(\.0)
        for f in newest {
            if let u = codexRateLimits(root + "/" + f) { return u }
        }
        return nil
    }

    nonisolated func codexRateLimits(_ path: String) -> Usage? {
        guard let h = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? h.close() }
        let size = (try? h.seekToEnd()) ?? 0
        try? h.seek(toOffset: size > 600_000 ? size - 600_000 : 0)
        guard let data = try? h.readToEnd(), let text = String(data: data, encoding: .utf8) else { return nil }
        for line in text.split(separator: "\n").reversed() where line.contains("\"rate_limits\"") {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)),
                  let rl = Self.find("rate_limits", in: obj) as? [String: Any] else { continue }
            // When Codex got this reading (falls back to when the log was last written).
            let stamp = ((obj as? [String: Any])?["timestamp"] as? String).flatMap { Self.iso.date(from: $0) }
                ?? ((try? fm.attributesOfItem(atPath: path))?[.modificationDate] as? Date)
            func window(_ key: String) -> (Double, Date?, String)? {
                guard let w = rl[key] as? [String: Any], let p = (w["used_percent"] as? NSNumber)?.doubleValue else { return nil }
                var r = (w["resets_at"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
                if r == nil, let s = (w["resets_in_seconds"] as? NSNumber)?.doubleValue { r = (stamp ?? Date()).addingTimeInterval(s) }
                let mins = (w["window_minutes"] as? NSNumber)?.doubleValue ?? 300
                if let rr = r, rr < Date() { return (0, nil, Self.windowName(minutes: mins)) }
                return (p, r, Self.windowName(minutes: mins))
            }
            guard let main = window("primary") else { continue }
            let other = window("secondary")
            return Usage(percent: main.0, resetsAt: main.1, window: main.2,
                         second: other.map { (percent: $0.0, resetsAt: $0.1, window: $0.2) }, asOf: stamp)
        }
        return nil
    }

    nonisolated static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f
    }()

    nonisolated static func find(_ key: String, in obj: Any) -> Any? {
        if let d = obj as? [String: Any] {
            if let v = d[key], !(v is NSNull) { return v }
            for v in d.values { if let f = find(key, in: v) { return f } }
        } else if let arr = obj as? [Any] {
            for v in arr { if let f = find(key, in: v) { return f } }
        }
        return nil
    }
}

/// Two quiet glyphs: a ring that fills with the limit used, and a timer with the time to reset.
struct UsageBadge: View {
    let usage: Usage
    @State private var drawn = false

    var tint: Color { usage.percent >= 85 ? .red : (usage.percent >= 60 ? .orange : .green) }

    static func short(_ s: TimeInterval) -> String {
        if s <= 60 { return "now" }
        if s < 3600 { return "\(Int(s / 60))m" }
        if s < 86400 { return "\(Int(s / 3600))h" }
        return "\(Int(s / 86400))d"
    }
    static func long(_ s: TimeInterval) -> String {
        let h = Int(s / 3600), m = Int(s.truncatingRemainder(dividingBy: 3600) / 60)
        if h >= 48 { return "\(h / 24) days" }
        return h > 0 ? "\(h)h \(m)m" : "\(max(m, 1))m"
    }

    func tooltip(_ now: Date) -> String {
        var t = "\(usage.window) limit: \(Int(usage.percent.rounded()))% used"
        if let r = usage.resetsAt { t += ", resets in \(usage.estimated ? "about " : "")\(Self.long(r.timeIntervalSince(now)))" }
        if let s = usage.second {
            t += "\n\(s.window) limit: \(Int(s.percent.rounded()))% used"
            if let r = s.resetsAt { t += ", resets in \(Self.long(r.timeIntervalSince(now)))" }
        }
        if usage.estimated {
            t += "\nFrom Claude Desktop's usage history"
            if let a = usage.asOf { t += " (\(Self.long(now.timeIntervalSince(a))) ago)" }
            t += ". The reset time is an estimate."
        } else if let a = usage.asOf {
            t += "\nUpdated \(now.timeIntervalSince(a) < 120 ? "just now" : Self.long(now.timeIntervalSince(a)) + " ago")."
            t += " Claude Code reports its limits with each reply, so this refreshes as you use it."
        }
        return t
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { ctx in
            HStack(spacing: 6) {
                ZStack {
                    Circle().stroke(Color.primary.opacity(0.12), lineWidth: 2.2)
                    Circle()
                        .trim(from: 0, to: drawn ? max(0.03, min(usage.percent / 100, 1)) : 0)
                        .stroke(tint, style: StrokeStyle(lineWidth: 2.2, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                }
                .frame(width: 12, height: 12)

                // The number itself, so the ring is never the only way to read it.
                Text("\(Int(usage.percent.rounded()))%")
                    .font(.system(size: 10.5, weight: .semibold).monospacedDigit())
                    .foregroundStyle(usage.percent >= 85 ? Color.red : (usage.percent >= 60 ? Color.orange : Color.primary.opacity(0.75)))
                    .contentTransition(.numericText())
                    .padding(.leading, -2)

                if let r = usage.resetsAt {
                    HStack(spacing: 2) {
                        Image(systemName: "timer").font(.system(size: 9.5, weight: .semibold))
                        Text((usage.estimated ? "~" : "") + Self.short(r.timeIntervalSince(ctx.date)))
                            .font(.system(size: 10.5, weight: .medium).monospacedDigit())
                            .contentTransition(.numericText(countsDown: true))
                            .animation(Motion.travel, value: Self.short(r.timeIntervalSince(ctx.date)))
                    }
                    .foregroundStyle(.secondary)
                }
            }
            .lineLimit(1)
            .fixedSize()                      // never wraps; the name beside it gives way instead
            .padding(.horizontal, 6).padding(.vertical, 3)
            .background(Capsule().fill(Color.primary.opacity(0.05)))
            .help(tooltip(ctx.date))
        }
        .onAppear { withAnimation(Motion.arrive.delay(0.2)) { drawn = true } }
        .onDisappear { drawn = false }
    }
}

/// The quick actions, as a small panel of round toggles like Control Center.
struct QuickTile: View {
    let title: String
    let help: String
    let symbol: String
    var on: Bool?
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 5) {
                Circle()
                    .fill(on == true ? Color.accentColor : Color.primary.opacity(hover ? 0.13 : 0.08))
                    .overlay(Image(systemName: symbol)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(on == true ? Color.white : Color.primary))
                    .frame(width: 34, height: 34)
                Text(title).font(.system(size: 10)).foregroundStyle(.secondary)
                    .lineLimit(1).fixedSize()
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle())
        .onHover { h in withAnimation(Motion.quick) { hover = h } }
        .animation(Motion.quick, value: on)
        .help(help)
    }
}

struct QuickActionsPanel: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 7) {
                IconTile(symbol: "bolt.fill", hue: .gray, size: 18)
                Text("Quick Actions").font(.system(size: 12, weight: .semibold))
                Spacer()
            }
            .padding(.horizontal, 4)
            GroupCard {
                HStack(spacing: 0) {
                    QuickTile(title: "Terminal", help: "New Terminal window with the active accounts",
                              symbol: "terminal") { model.openTerminal() }
                    QuickTile(title: "Sync Chats", help: "New and changed Code-tab chats follow you to every Claude account when you switch",
                              symbol: "bubble.left.and.text.bubble.right", on: model.carryChat) { model.carryChat.toggle() }
                    QuickTile(title: "At Login", help: "Open AccountDeck when you log in",
                              symbol: "power", on: model.launchAtLogin) { model.toggleLaunchAtLogin() }
                    QuickTile(title: "Data", help: "Show AccountDeck's data folder",
                              symbol: "folder") { NSWorkspace.shared.open(URL(fileURLWithPath: model.root)) }
                }
                .padding(.vertical, 10).padding(.horizontal, 4)
            }
        }
    }
}

struct AccountRow: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject private var usageStore = UsageStore.shared
    let account: Account
    @State private var hover = false
    @AppStorage(MenuLayout.compactKey) private var compact = false
    @AppStorage(MenuLayout.footerKey) private var showUsage = true
    @AppStorage(MenuLayout.limitKey) private var limitPref = "auto"

    var body: some View {
        let active = model.isActive(account)
        let hue = account.service.hue
        let ok = model.signedIn[account.id] ?? false
        Button { model.select(account) } label: {
            HStack(spacing: 10) {
                Avatar(name: account.name, hue: hue, size: compact ? 22 : 30)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 5) {
                        Text(account.name)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.primary)
                        if compact && !ok {
                            Image(systemName: "exclamationmark.circle.fill")
                                .font(.system(size: 10)).foregroundStyle(.orange)
                        }
                    }
                    if !compact { HStack(spacing: 4) {
                        if !ok {
                            Image(systemName: "exclamationmark.circle.fill")
                                .font(.system(size: 9.5)).foregroundStyle(.orange)
                        }
                        Text(model.details[account.id] ?? "")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.middle)
                    } }
                }
                Spacer(minLength: 8)
                if showUsage, let u = usageStore.usage[account.id] {
                    UsageBadge(usage: u.view(limitPref)).transition(.opacity.combined(with: .scale(scale: 0.9)))
                        .animation(Motion.travel, value: limitPref)
                } else if showUsage, !usageStore.claudeTracking,
                          account.service == .claude || account.service == .desktop {
                    // No limits yet: a faint ring. Clicking it turns Claude usage limits on.
                    Button {
                        let skipped = usageStore.enableClaudeTracking(model.accounts)
                        model.flash(skipped.isEmpty ? "Usage limits on. They show after Claude's next reply."
                                                    : "Skipped \(skipped.joined(separator: ", ")): it has its own status line")
                    } label: {
                        Circle().strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [2, 2]))
                            .foregroundStyle(Color.secondary.opacity(0.5))
                            .frame(width: 12, height: 12)
                            .padding(.horizontal, 6).padding(.vertical, 3)
                            .background(Capsule().fill(Color.primary.opacity(0.05)))
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .help("Show this account's usage limit and reset countdown. Adds a small status line hook to Claude Code that saves the limits on this Mac.")
                }
                trailing(active: active, hue: hue)
            }
            .padding(.horizontal, 10).padding(.vertical, compact ? 5 : 7)
            .help(compact ? (model.details[account.id] ?? "") : "")
            .background(hover ? Color.primary.opacity(0.06) : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { h in withAnimation(.easeOut(duration: 0.12)) { hover = h } }
        .contextMenu {
            Button(account.service == .chatgpt ? "Open ChatGPT"
                   : (account.service == .desktop ? "Switch Claude to This Account" : "Sign In Again")) { model.signIn(account) }
            Button("Rename…") { model.rename(account) }
            Button("Show in Finder") { model.reveal(account) }
            if !account.isDefault {
                Divider()
                Button("Remove…", role: .destructive) { model.remove(account) }
            }
        }
    }

    @ViewBuilder func trailing(active: Bool, hue: Color) -> some View {
        if account.service == .chatgpt {
            Image(systemName: "arrow.up.forward.app")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(hover ? hue : Color.secondary.opacity(0.6))
        } else if hover && !active {
            Text(account.service == .desktop ? "Switch" : "Use")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(hue)
                .padding(.horizontal, 9).padding(.vertical, 3)
                .background(Capsule().fill(hue.opacity(0.14)))
                .transition(.opacity.combined(with: .scale(scale: 0.92)))
        } else {
            // One symbol that morphs between the empty circle and the filled check.
            Image(systemName: active ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 17, weight: active ? .regular : .light))
                .symbolRenderingMode(.palette)
                .foregroundStyle(active ? Color.white : Color.secondary.opacity(0.5),
                                 active ? hue : Color.secondary.opacity(0.5))
                .contentTransition(.symbolEffect(.replace))
                .animation(Motion.quick, value: active)
        }
    }
}

struct AddRow: View {
    @EnvironmentObject var model: AppModel
    let service: Service
    var subtitle: String?
    @State private var hover = false
    @AppStorage(MenuLayout.compactKey) private var compact = false

    var body: some View {
        Button { model.addPreset = service; model.screen = .add } label: {
            HStack(spacing: 10) {
                Circle().fill(Color.primary.opacity(0.06))
                    .overlay(Image(systemName: "plus").font(.system(size: compact ? 10 : 12, weight: .semibold)).foregroundStyle(service.hue))
                    .frame(width: compact ? 22 : 30, height: compact ? 22 : 30)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Add Account…").font(.system(size: 13)).foregroundStyle(service.hue)
                    if let subtitle, !compact {
                        Text(subtitle).font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
                Spacer()
            }
            .padding(.horizontal, 10).padding(.vertical, compact ? 5 : 7)
            .background(hover ? Color.primary.opacity(0.06) : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { h in withAnimation(.easeOut(duration: 0.12)) { hover = h } }
        .help("Add a \(service.title) account")
    }
}

struct ServiceSection: View {
    @EnvironmentObject var model: AppModel
    let service: Service
    @AppStorage(MenuLayout.compactKey) private var compact = false

    var body: some View {
        let list = model.accounts(for: service)
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 7) {
                IconTile(symbol: service.symbol, hue: service.hue, size: 18)
                Text(service.title).font(.system(size: 12, weight: .semibold))
                Spacer()
                Text(service.whereItRuns).font(.system(size: 11)).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 4)

            GroupCard {
                ForEach(Array(list.enumerated()), id: \.element.id) { i, a in
                    if i > 0 { RowDivider(inset: compact ? 42 : 50) }
                    AccountRow(account: a)
                }
                if !list.isEmpty { RowDivider(inset: compact ? 42 : 50) }
                AddRow(service: service,
                       subtitle: list.isEmpty && service == .chatgpt ? "Opens in its own browser window" : nil)
            }
        }
    }
}

extension AppModel {
    var addPreset: Service {
        get { Service(rawValue: UserDefaults.standard.string(forKey: "addPreset") ?? "") ?? .claude }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "addPreset") }
    }
}

/// A row that behaves like a native menu item: full-width, accent highlight on hover.
struct MenuRow<Trailing: View>: View {
    let title: String
    var symbol: String?
    var action: () -> Void
    @ViewBuilder var trailing: Trailing
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if let symbol {
                    Image(systemName: symbol).font(.system(size: 12)).frame(width: 16)
                }
                Text(title).font(.system(size: 13))
                Spacer()
                trailing.foregroundStyle(hover ? Color.white.opacity(0.85) : Color.secondary)
            }
            .foregroundStyle(hover ? Color.white : Color.primary)
            .padding(.horizontal, 8).frame(height: 24)
            .background(RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(hover ? Color.accentColor : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

extension MenuRow where Trailing == EmptyView {
    init(title: String, symbol: String? = nil, action: @escaping () -> Void) {
        self.init(title: title, symbol: symbol, action: action) { EmptyView() }
    }
}

struct ListView: View {
    @EnvironmentObject var model: AppModel
    @AppStorage(MenuLayout.orderKey) private var orderRaw = MenuLayout.defaultOrder
    @AppStorage(MenuLayout.hiddenKey) private var hiddenRaw = ""
    @AppStorage(MenuLayout.footerKey) private var showFooter = true

    var shown: [Service] {
        let hidden = MenuLayout.hidden(hiddenRaw)
        return MenuLayout.order(orderRaw).filter { !hidden.contains($0) }
    }

    var summary: String {
        let n = model.accounts.count
        let desk = model.activeName(.desktop)
        return "\(n) account\(n == 1 ? "" : "s") · Claude on \(desk)"
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header: the app icon, its name and a one-line status.
            HStack(spacing: 10) {
                AppGlyph(size: 32)
                VStack(alignment: .leading, spacing: 1) {
                    Text("AccountDeck").font(.system(size: 14, weight: .semibold))
                    Text(summary).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
                        .contentTransition(.numericText())
                        .animation(Motion.travel, value: summary)
                }
                Spacer()
                if !model.shellLinked {
                    Button { MainWindow.shared.show(model) } label: {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 11, weight: .semibold))
                            .frame(width: 24, height: 24)
                            .background(Circle().fill(Color.orange.opacity(0.15)))
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain).foregroundStyle(.orange)
                    .help("Terminal isn't connected, so Claude Code and Codex can't switch yet. Open AccountDeck to connect it.")
                }
                Button { MainWindow.shared.show(model) } label: {
                    Image(systemName: "macwindow")
                        .font(.system(size: 11, weight: .semibold))
                        .frame(width: 24, height: 24)
                        .background(Circle().fill(Color.primary.opacity(0.07)))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain).foregroundStyle(.secondary)
                .help("Open AccountDeck: usage, setup, chats and more")
                Button { model.screen = .customize } label: {
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 11, weight: .semibold))
                        .frame(width: 24, height: 24)
                        .background(Circle().fill(Color.primary.opacity(0.07)))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain).foregroundStyle(.secondary)
                .help("Customize what this menu shows")
            }
            .padding(.horizontal, 14).padding(.top, 14).padding(.bottom, 12)
            .arrive(0)

            // The menu only switches accounts. Everything else lives in the AccountDeck window.
            VStack(alignment: .leading, spacing: 14) {
                ForEach(Array(shown.enumerated()), id: \.element) { i, s in
                    ServiceSection(service: s).arrive(i + 2)
                }
                if shown.isEmpty {
                    GroupCard {
                        VStack(spacing: 8) {
                            Image(systemName: "eye.slash").font(.system(size: 20)).foregroundStyle(.tertiary)
                            Text("All apps are hidden").font(.system(size: 13, weight: .semibold))
                            Button("Customize…") { model.screen = .customize }.controlSize(.small)
                        }
                        .frame(maxWidth: .infinity).padding(.vertical, 18)
                    }
                }
            }
            .padding(.horizontal, 12).padding(.bottom, 10)
            .animation(Motion.travel, value: shown)

            // Footer: plain menu rows, like a system menu bar extra.
            Divider().padding(.horizontal, 14).padding(.vertical, 4)
            MenuRow(title: "Customize Menu…") { model.screen = .customize }
                .padding(.horizontal, 6)
            MenuRow(title: "Quit AccountDeck", symbol: nil, action: { AppDelegate.quitForReal = true; NSApp.terminate(nil) }) {
                Text("⌘Q").font(.system(size: 12))
            }
            .keyboardShortcut("q")
            .padding(.horizontal, 6)
            CreditLink(size: 10.5)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14).padding(.top, 2).padding(.bottom, 10)
        }
    }
}

struct AddView: View {
    @EnvironmentObject var model: AppModel
    @State private var service: Service = .claude
    @State private var name = ""
    @FocusState private var focused: Bool

    var explainer: String {
        switch service {
        case .desktop: return "Claude closes and reopens signed out. Sign in with the new account and it is saved."
        case .claude: return "A Terminal window opens and runs claude /login for this account only. Your other accounts stay signed in."
        case .codex: return "A Terminal window opens and runs codex login for this account only. Your other accounts stay signed in."
        case .chatgpt: return "A separate browser window opens on chatgpt.com. Sign in once there and it remembers this account."
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ZStack {
                Text("New Account").font(.system(size: 13, weight: .semibold))
                HStack {
                    Button { model.screen = .list } label: {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 11, weight: .semibold))
                            .frame(width: 24, height: 24)
                            .background(Circle().fill(Color.primary.opacity(0.07)))
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                    Spacer()
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("App").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary).padding(.leading, 4)
                GroupCard {
                    ForEach(Array(Service.allCases.enumerated()), id: \.element.id) { i, s in
                        if i > 0 { RowDivider(inset: 42) }
                        Button { service = s } label: {
                            HStack(spacing: 10) {
                                IconTile(symbol: s.symbol, hue: s.hue, size: 22)
                                Text(s.title).font(.system(size: 13))
                                Spacer()
                                Text(s.whereItRuns).font(.system(size: 11)).foregroundStyle(.tertiary)
                                Image(systemName: "checkmark")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(Color.accentColor)
                                    .opacity(service == s ? 1 : 0)
                            }
                            .padding(.horizontal, 10).padding(.vertical, 7)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Name").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary).padding(.leading, 4)
                GroupCard {
                    HStack(spacing: 10) {
                        Avatar(name: name.isEmpty ? "?" : name, hue: service.hue, size: 24)
                        TextField("Work, Personal, Client…", text: $name)
                            .textFieldStyle(.plain)
                            .font(.system(size: 13))
                            .focused($focused)
                            .onSubmit(submit)
                    }
                    .padding(.horizontal, 10).padding(.vertical, 8)
                }
                Text(explainer).font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 4).padding(.top, 2)
            }

            HStack(spacing: 8) {
                Button { model.screen = .list } label: { Text("Cancel").frame(maxWidth: .infinity) }
                    .keyboardShortcut(.cancelAction)
                Button(action: submit) {
                    Text(service == .chatgpt ? "Add and Open" : (service == .desktop ? "Add and Switch" : "Add and Sign In"))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .controlSize(.large)
        }
        .padding(14)
        .onAppear {
            service = model.addPreset
            NSApp.activate(ignoringOtherApps: true)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { focused = true }
        }
    }

    func submit() { model.add(service: service, name: name) }
}

/// Choose which apps the main menu shows, in what order, and how dense it is.
struct CustomizeView: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject private var usageStore = UsageStore.shared
    @AppStorage(MenuLayout.orderKey) private var orderRaw = MenuLayout.defaultOrder
    @AppStorage(MenuLayout.hiddenKey) private var hiddenRaw = ""
    @AppStorage(MenuLayout.compactKey) private var compact = false
    @AppStorage(MenuLayout.footerKey) private var showFooter = true
    @AppStorage(MenuLayout.limitKey) private var limitPref = "auto"
    @AppStorage(ExactUsage.onKey) private var exactOn = false
    @AppStorage(ExactUsage.statusKey) private var exactStatus = ""

    var order: [Service] { MenuLayout.order(orderRaw) }

    func isShown(_ s: Service) -> Binding<Bool> {
        Binding(
            get: { !MenuLayout.hidden(hiddenRaw).contains(s) },
            set: { on in
                var h = MenuLayout.hidden(hiddenRaw)
                if on { h.remove(s) } else { h.insert(s) }
                hiddenRaw = MenuLayout.encode(Service.allCases.filter { h.contains($0) })
            })
    }

    func move(_ s: Service, by d: Int) {
        var o = order
        guard let i = o.firstIndex(of: s), o.indices.contains(i + d) else { return }
        o.swapAt(i, i + d)
        withAnimation(.easeOut(duration: 0.18)) { orderRaw = MenuLayout.encode(o) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ZStack {
                Text("Customize Menu").font(.system(size: 13, weight: .semibold))
                HStack {
                    Spacer()
                    Button("Done") { model.screen = .list }
                        .buttonStyle(.borderedProminent).controlSize(.small)
                        .keyboardShortcut(.defaultAction)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Show in Menu").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary).padding(.leading, 4)
                GroupCard {
                    ForEach(Array(order.enumerated()), id: \.element.id) { i, s in
                        if i > 0 { RowDivider(inset: 42) }
                        HStack(spacing: 10) {
                            IconTile(symbol: s.symbol, hue: s.hue, size: 22)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(s.title).font(.system(size: 13))
                                let n = model.accounts(for: s).count
                                Text(n == 0 ? "No accounts" : "\(n) account\(n == 1 ? "" : "s")")
                                    .font(.system(size: 11)).foregroundStyle(.secondary)
                            }
                            Spacer()
                            HStack(spacing: 2) {
                                arrow("chevron.up", enabled: i > 0) { move(s, by: -1) }
                                arrow("chevron.down", enabled: i < order.count - 1) { move(s, by: 1) }
                            }
                            Toggle("", isOn: isShown(s)).toggleStyle(.switch).controlSize(.mini).labelsHidden()
                        }
                        .padding(.horizontal, 10).padding(.vertical, 7)
                        .opacity(isShown(s).wrappedValue ? 1 : 0.55)
                    }
                }
                Text("Hidden apps keep their accounts. Use the arrows to change the order.")
                    .font(.system(size: 11)).foregroundStyle(.secondary).padding(.horizontal, 4).padding(.top, 2)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Layout").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary).padding(.leading, 4)
                GroupCard {
                    settingRow("Compact Rows", detail: "Hides emails and status lines", symbol: "rectangle.compress.vertical",
                               hue: .indigo, isOn: $compact)
                    RowDivider(inset: 42)
                    settingRow("Usage on Rows", detail: "Limit ring and reset timer", symbol: "gauge.with.needle",
                               hue: .green, isOn: $showFooter)
                    RowDivider(inset: 42)
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 10) {
                            IconTile(symbol: "timer", hue: .orange, size: 22)
                            VStack(alignment: .leading, spacing: 1) {
                                Text("Limit to Show").font(.system(size: 13))
                                Text(limitPref == "auto" ? "5-hour, or weekly when 5-hour isn't in use"
                                     : (limitPref == "5h" ? "Always the 5-hour limit" : "Always the weekly limit"))
                                    .font(.system(size: 11)).foregroundStyle(.secondary)
                                    .contentTransition(.opacity)
                            }
                            Spacer()
                        }
                        Picker("", selection: $limitPref) {
                            Text("Auto").tag("auto")
                            Text("5-Hour").tag("5h")
                            Text("Weekly").tag("weekly")
                        }
                        .pickerStyle(.segmented).labelsHidden().controlSize(.small)
                        .padding(.leading, 32)
                    }
                    .padding(.horizontal, 10).padding(.vertical, 8)
                    .animation(Motion.quick, value: limitPref)
                    RowDivider(inset: 42)
                    settingRow("Exact Usage", detail: exactOn ? (exactStatus.isEmpty ? "Asks Anthropic about once a minute" : exactStatus)
                                                              : "Reads your Claude Code login to ask Anthropic",
                               symbol: "checkmark.seal", hue: .teal, isOn: $exactOn)
                        .onChange(of: exactOn) { _, on in
                            UserDefaults.standard.set(true, forKey: ExactUsage.askedKey)
                            if !on { exactStatus = "Off" }
                            UsageStore.shared.refresh(AppModel.shared.accounts, force: true)
                        }
                }
            }


            Button("Reset to Default") {
                withAnimation { orderRaw = MenuLayout.defaultOrder; hiddenRaw = ""; compact = false; showFooter = true; limitPref = "auto" }
            }
            .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(Color.accentColor)
            .frame(maxWidth: .infinity)
        }
        .padding(14)
    }

    func arrow(_ symbol: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 9, weight: .bold))
                .frame(width: 20, height: 20)
                .background(Circle().fill(Color.primary.opacity(enabled ? 0.07 : 0.03)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(enabled ? Color.secondary : Color.secondary.opacity(0.3))
        .disabled(!enabled)
    }

    func settingRow(_ title: String, detail: String, symbol: String, hue: Color, isOn: Binding<Bool>) -> some View {
        HStack(spacing: 10) {
            IconTile(symbol: symbol, hue: hue, size: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 13))
                Text(detail).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer()
            Toggle("", isOn: isOn).toggleStyle(.switch).controlSize(.mini).labelsHidden()
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
    }
}

/// A macOS-style alert drawn inside the panel (pop-up alerts don't show reliably from a menu bar panel).
struct AlertCard<Body: View>: View {
    var onDismiss: () -> Void
    @ViewBuilder var content: Body
    var body: some View {
        ZStack {
            Color.black.opacity(0.2).onTapGesture(perform: onDismiss)
            VStack(spacing: 12) { content }
                .padding(16)
                .frame(width: 270)
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.regularMaterial))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5))
                .shadow(color: .black.opacity(0.25), radius: 18, y: 8)
        }
        .transition(.opacity)
    }
}

struct ConfirmCard: View {
    @EnvironmentObject var model: AppModel
    let confirm: Confirm
    var body: some View {
        AlertCard(onDismiss: { model.confirm = nil }) {
            AppGlyph(size: 52)
            VStack(spacing: 5) {
                Text(confirm.title).font(.system(size: 13, weight: .bold))
                    .multilineTextAlignment(.center)
                Text(confirm.message).font(.system(size: 11))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                Button { model.confirm = nil } label: { Text("Cancel").frame(maxWidth: .infinity) }
                    .keyboardShortcut(.cancelAction)
                Button {
                    let act = confirm.action
                    model.confirm = nil
                    act()
                } label: { Text(confirm.button).frame(maxWidth: .infinity) }
                    .buttonStyle(.borderedProminent)
                    .tint(confirm.destructive ? .red : .accentColor)
                    .keyboardShortcut(.defaultAction)
            }
            .controlSize(.large)
            .padding(.top, 2)
        }
    }
}

struct RenameCard: View {
    @EnvironmentObject var model: AppModel
    let account: Account
    @State private var name = ""
    @FocusState private var focused: Bool
    var body: some View {
        AlertCard(onDismiss: { model.renaming = nil }) {
            Avatar(name: name.isEmpty ? account.name : name, hue: account.service.hue, size: 48)
            VStack(spacing: 3) {
                Text("Rename Account").font(.system(size: 13, weight: .bold))
                Text(account.service.title).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            TextField("Name", text: $name).textFieldStyle(.roundedBorder).focused($focused)
                .onSubmit { model.applyRename(account, to: name) }
            HStack(spacing: 8) {
                Button { model.renaming = nil } label: { Text("Cancel").frame(maxWidth: .infinity) }
                    .keyboardShortcut(.cancelAction)
                Button { model.applyRename(account, to: name) } label: { Text("Rename").frame(maxWidth: .infinity) }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
            .controlSize(.large)
        }
        .onAppear {
            name = account.name
            NSApp.activate(ignoringOtherApps: true)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { focused = true }
        }
    }
}

struct RootView: View {
    @EnvironmentObject var model: AppModel
    @State private var open = false

    func refreshAll() {
        model.refresh()
        UsageStore.shared.refresh(model.accounts)
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            Group {
                switch model.screen {
                case .add: AddView()
                case .customize: CustomizeView()
                case .list: ListView()
                }
            }
            // A page change keeps the panel and crossfades the body with a small rise.
            .id("\(model.screen)")
            .transition(.asymmetric(insertion: .opacity.combined(with: .offset(y: 8)),
                                    removal: .opacity))
            .animation(Motion.page, value: "\(model.screen)")
            if let c = model.confirm {
                ConfirmCard(confirm: c)
            }
            if let a = model.renaming {
                RenameCard(account: a)
            }
            if let t = model.toast {
                // A HUD pill, like the system's volume and AirDrop notices.
                HStack(spacing: 7) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.accentColor)
                    Text(t).foregroundStyle(.primary)
                }
                .font(.system(size: 12, weight: .medium))
                .padding(.horizontal, 14).padding(.vertical, 9)
                .background(Capsule().fill(.regularMaterial))
                .overlay(Capsule().strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5))
                .shadow(color: .black.opacity(0.18), radius: 12, y: 4)
                .padding(.bottom, 64)
                .transition(.opacity.combined(with: .offset(y: 10)).combined(with: .scale(scale: 0.96)))
            }
        }
        .frame(width: 340)
        .environment(\.panelOpen, open)
        .onAppear { refreshAll(); model.writeEnv(); open = true }
        // The panel re-staggers in each time it opens from the menu bar.
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { n in
            guard (n.object as? NSWindow) !== MainWindow.shared.window else { return }
            refreshAll(); open = true
        }
        // Hide the sections (ready for the next arrival) only once the panel is really gone.
        // macOS can show the panel, or keep it on screen, without it being the key window;
        // hiding on focus alone left an empty panel.
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { n in
            guard let w = n.object as? NSWindow, w !== MainWindow.shared.window else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                guard !w.isVisible || !w.occlusionState.contains(.visible) else { return }
                var t = Transaction(); t.disablesAnimations = true
                withTransaction(t) { open = false }
            }
        }
        // On screen without becoming key: show the sections anyway.
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didChangeOcclusionStateNotification)) { n in
            guard let w = n.object as? NSWindow, w !== MainWindow.shared.window,
                  w.isVisible, w.occlusionState.contains(.visible), !open else { return }
            refreshAll(); open = true
        }
        .onReceive(Timer.publish(every: 60, on: .main, in: .common).autoconnect()) { _ in
            UsageStore.shared.refresh(model.accounts)
        }
    }
}

#if !SNAPSHOT
@main
struct AccountDeckApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @ObservedObject private var model = AppModel.shared

    /// Menu bar icon: the mascot alone, a soft round body with two eyes, at the menu bar's
    /// glyph size (18 pt tall, like the system icons next to it). Template, so macOS tints it.
    static let menuBarIcon: NSImage = {
        let img = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            NSColor.black.set()
            // Body: rounded on top, running off the bottom edge, with two eye holes.
            let body = NSBezierPath(roundedRect: NSRect(x: 1.5, y: -7, width: 15, height: 23.5), xRadius: 7.5, yRadius: 7.5)
            body.append(NSBezierPath(ovalIn: NSRect(x: 4.1, y: 7.4, width: 4.4, height: 5.6)))
            body.append(NSBezierPath(ovalIn: NSRect(x: 9.5, y: 8.0, width: 4.4, height: 5.6)))
            body.windingRule = .evenOdd
            body.fill()
            // Pupils, glancing to the side.
            NSBezierPath(ovalIn: NSRect(x: 6.4, y: 9.0, width: 1.8, height: 2.3)).fill()
            NSBezierPath(ovalIn: NSRect(x: 11.8, y: 9.6, width: 1.8, height: 2.3)).fill()
            return true
        }
        img.isTemplate = true
        return img
    }()

    var body: some Scene {
        MenuBarExtra {
            RootView().environmentObject(model)
        } label: {
            Image(nsImage: Self.menuBarIcon)
        }
        .menuBarExtraStyle(.window)
    }
}
#endif
