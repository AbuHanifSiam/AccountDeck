// AccountDeck — the full window: every account in a sidebar, and for each one its usage,
// its environment (settings, MCP servers, plugins, skills, memory) and its chats, which can be
// copied into another of your accounts.
//
// Rules this window keeps:
//  • Everything is read from and written to this Mac. Nothing is uploaded.
//  • Logins and tokens are never read, shown or copied. Environment variables show names only.
//  • Chats are copied, never moved or deleted, and only between your own accounts.
//  • Chats on claude.ai live on Anthropic's servers with their account and are not touched.

import SwiftUI
import AppKit

// MARK: - Window

@MainActor
final class MainWindow: NSObject, NSWindowDelegate {
    static let shared = MainWindow()
    private(set) var window: NSWindow?

    func show(_ model: AppModel, select: String? = nil) {
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 680),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                             backing: .buffered, defer: false)
            w.title = "AccountDeck"
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            // A real (empty) toolbar: the sidebar button sits in it, and the page starts below it,
            // so nothing slides under the window buttons when the sidebar is hidden.
            let bar = NSToolbar(identifier: "AccountDeckMain")
            bar.displayMode = .iconOnly
            w.toolbar = bar
            w.toolbarStyle = .unified
            w.isReleasedWhenClosed = false
            w.minSize = NSSize(width: 780, height: 520)
            w.contentView = NSHostingView(rootView: DashboardView(initial: select).environmentObject(model))
            w.center()
            w.setFrameAutosaveName("AccountDeckMain")
            w.delegate = self
            window = w
        }
        // While the window is open, AccountDeck is a normal app: Dock icon and app switcher.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        // Once: ask whether AccountDeck may get exact usage from Anthropic.
        if !UserDefaults.standard.bool(forKey: ExactUsage.askedKey) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                ExactUsage.askIfNeeded(hasClaudeCode: model.accounts.contains { $0.service == .claude })
                UsageStore.shared.refresh(model.accounts, force: true)
            }
        }
    }

    func windowWillClose(_ notification: Notification) {
        // Back to a menu bar only app. The window is made fresh next time, so it always
        // opens on the Dashboard.
        DispatchQueue.main.async {
            self.window = nil
            NSApp.setActivationPolicy(.accessory)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Opened from Applications, Spotlight or Finder: show the window.
        // Started at login: stay quietly in the menu bar.
        let ev = NSAppleEventManager.shared().currentAppleEvent
        let atLogin = ev?.eventID == AEEventID(kAEOpenApplication)
            && ev?.paramDescriptor(forKeyword: AEKeyword(keyAEPropData))?.enumCodeValue == OSType(keyAELaunchedAsLogInItem)
        if !atLogin {
            Task { @MainActor in MainWindow.shared.show(AppModel.shared) }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        Task { @MainActor in MainWindow.shared.show(AppModel.shared) }
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// Set by "Quit AccountDeck" in the menu bar panel: the one way to quit everything.
    static var quitForReal = false

    /// Quit from the Dock or ⌘Q in the window closes the window only, so the menu bar icon
    /// stays. Logging out, restarting and shutting down always quit.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if Self.quitForReal { return .terminateNow }
        let ev = NSAppleEventManager.shared().currentAppleEvent
        if ev?.attributeDescriptor(forKeyword: AEKeyword(kAEQuitReason)) != nil { return .terminateNow }
        if let w = MainWindow.shared.window, w.isVisible {
            w.close()
            return .terminateCancel
        }
        return .terminateNow
    }
}

extension AppModel {
    static let shared = AppModel()
}

// MARK: - Data

struct ChatItem: Identifiable, Hashable {
    enum Kind { case code, desktop }
    let id: String          // the file's path
    var title: String
    var folder: String      // the project folder the chat ran in
    var date: Date
    var size: Int64
    var kind: Kind
}

struct ChatFolder: Identifiable {
    var id: String { path }
    let path: String
    var chats: [ChatItem]
    var name: String { path.isEmpty ? "No folder" : (path as NSString).lastPathComponent }
    var newest: Date { chats.map(\.date).max() ?? .distantPast }
}

/// What can be sent from one Claude Code account to another.
enum EnvPart: String, CaseIterable, Identifiable {
    case model, permissions, mcp, plugins, skills, hooks, memory, env
    var id: String { rawValue }
    var title: String {
        switch self {
        case .model: return "Model"
        case .permissions: return "Permissions"
        case .mcp: return "MCP servers"
        case .plugins: return "Plugins"
        case .skills: return "Skills"
        case .hooks: return "Hooks"
        case .memory: return "Memory"
        case .env: return "Environment"
        }
    }
}

struct EnvFact: Identifiable {
    let id = UUID()
    var part: EnvPart? = nil
    var symbol: String
    var hue: Color
    var title: String
    var value: String
    var detail: String?
}

enum ChatIndex {
    static let fm = FileManager.default

    static func readHead(_ path: String, bytes: Int) -> String {
        guard let h = FileHandle(forReadingAtPath: path) else { return "" }
        defer { try? h.close() }
        let d = (try? h.read(upToCount: bytes)) ?? Data()
        return String(decoding: d, as: UTF8.self)
    }

    static func readTail(_ path: String, bytes: UInt64) -> String {
        guard let h = FileHandle(forReadingAtPath: path) else { return "" }
        defer { try? h.close() }
        let size = (try? h.seekToEnd()) ?? 0
        try? h.seek(toOffset: size > bytes ? size - bytes : 0)
        return String(decoding: (try? h.readToEnd()) ?? Data(), as: UTF8.self)
    }

    static func clean(_ s: String) -> String {
        let one = s.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        return one.count > 90 ? String(one.prefix(90)) + "…" : one
    }

    /// Claude Code chats: <config>/projects/<project>/<session>.jsonl, newest first.
    static func codeChats(projects: String, limit: Int = 400) -> [ChatItem] {
        guard let dirs = try? fm.contentsOfDirectory(atPath: projects) else { return [] }
        var files: [(String, Date, Int64)] = []
        for d in dirs {
            let dir = projects + "/" + d
            for f in (try? fm.contentsOfDirectory(atPath: dir)) ?? [] where f.hasSuffix(".jsonl") {
                let p = dir + "/" + f
                let attrs = try? fm.attributesOfItem(atPath: p)
                files.append((p, attrs?[.modificationDate] as? Date ?? .distantPast,
                              (attrs?[.size] as? NSNumber)?.int64Value ?? 0))
            }
        }
        files.sort { $0.1 > $1.1 }
        let known = desktopTitles()
        return Array(files.prefix(limit).enumerated()).compactMap { index, f in
            let (p, date, size) = f
            guard size > 0 else { return nil }
            var custom: String?, ai: String?, first: String?, cwd: String?
            func scan(_ text: String) {
                for line in text.split(separator: "\n") {
                    // Title lines are short; check them by their start before anything else.
                    let isTitle = line.hasPrefix("{\"type\":\"custom-title\"") || line.hasPrefix("{\"type\":\"ai-title\"")
                        || (line.count < 2000 && (line.contains("\"custom-title\"") || line.contains("\"ai-title\"")))
                    // Only decode a message while the first prompt or the folder is still unknown.
                    let needUser = first == nil || cwd == nil
                    let isUser = needUser && line.contains("\"type\":\"user\"")
                    guard isTitle || isUser || (cwd == nil && line.contains("\"cwd\"")) else { continue }
                    guard let o = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any] else { continue }
                    if cwd == nil, let c = o["cwd"] as? String { cwd = c }
                    if let t = o["customTitle"] as? String { custom = t }
                    if let t = o["aiTitle"] as? String { ai = t }
                    if first == nil, isUser, let m = o["message"] as? [String: Any] {
                        var text: String?
                        if let s = m["content"] as? String { text = s }
                        if let arr = m["content"] as? [[String: Any]] {
                            text = arr.first(where: { $0["type"] as? String == "text" })?["text"] as? String
                        }
                        if let t = text?.trimmingCharacters(in: .whitespacesAndNewlines),
                           !t.isEmpty, !t.hasPrefix("<"), !t.hasPrefix("Caveat:") { first = t }
                    }
                }
            }
            scan(readHead(p, bytes: 96_000))
            scan(readTail(p, bytes: 24_000))
            // Titles are written as the chat goes; in a long chat the last one can be further back.
            let sid = ((p as NSString).lastPathComponent as NSString).deletingPathExtension
            if custom == nil && ai == nil, let t = known[sid] { custom = t }
            if custom == nil && ai == nil && index < 60 { scan(readTail(p, bytes: 400_000)) }
            let title = custom ?? ai ?? first ?? "Untitled chat"
            return ChatItem(id: p, title: clean(title), folder: cwd ?? "", date: date, size: size, kind: .code)
        }
    }

    /// Titles Claude Desktop keeps for the Code-tab chats it ran: CLI session id → title.
    static func desktopTitles() -> [String: String] {
        let root = fm.homeDirectoryForCurrentUser.path + "/Library/Application Support/Claude/claude-code-sessions"
        var out: [String: String] = [:]
        for acc in (try? fm.contentsOfDirectory(atPath: root)) ?? [] {
            for org in (try? fm.contentsOfDirectory(atPath: root + "/" + acc)) ?? [] {
                let dir = root + "/" + acc + "/" + org
                for f in (try? fm.contentsOfDirectory(atPath: dir)) ?? [] where f.hasPrefix("local_") {
                    guard let d = fm.contents(atPath: dir + "/" + f),
                          let j = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any],
                          let sid = j["cliSessionId"] as? String, let t = j["title"] as? String, !t.isEmpty else { continue }
                    out[sid] = t
                }
            }
        }
        return out
    }

    /// Claude Desktop Code-tab chats for one signed-in account.
    static func desktopChats(sessions: String, accountUuid: String) -> [ChatItem] {
        let accDir = sessions + "/" + accountUuid
        var out: [ChatItem] = []
        for org in (try? fm.contentsOfDirectory(atPath: accDir)) ?? [] {
            let dir = accDir + "/" + org
            for f in (try? fm.contentsOfDirectory(atPath: dir)) ?? [] where f.hasPrefix("local_") && f.hasSuffix(".json") {
                let p = dir + "/" + f
                guard let d = fm.contents(atPath: p),
                      let j = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any],
                      (j["isArchived"] as? Bool) != true else { continue }
                let ms = (j["lastActivityAt"] as? NSNumber)?.doubleValue ?? (j["createdAt"] as? NSNumber)?.doubleValue ?? 0
                out.append(ChatItem(id: p, title: clean(j["title"] as? String ?? "Untitled chat"),
                                    folder: j["cwd"] as? String ?? "", date: Date(timeIntervalSince1970: ms / 1000),
                                    size: Int64(d.count), kind: .desktop))
            }
        }
        return out.sorted { $0.date > $1.date }
    }

    static func group(_ chats: [ChatItem]) -> [ChatFolder] {
        Dictionary(grouping: chats, by: \.folder)
            .map { ChatFolder(path: $0.key, chats: $0.value.sorted { $0.date > $1.date }) }
            .sorted { $0.newest > $1.newest }
    }

    /// Copies Claude Code chats into another account's projects folder, keeping each one's
    /// project folder so `claude --resume` finds it there. Existing chats are never overwritten.
    static func copyCode(_ chats: [ChatItem], from: String, to: String) -> (copied: Int, skipped: Int) {
        var copied = 0, skipped = 0
        for c in chats {
            guard c.id.hasPrefix(from + "/") else { skipped += 1; continue }
            let rel = String(c.id.dropFirst(from.count + 1))
            let dest = to + "/" + rel
            if fm.fileExists(atPath: dest) { skipped += 1; continue }
            try? fm.createDirectory(atPath: (dest as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            guard (try? fm.copyItem(atPath: c.id, toPath: dest)) != nil else { skipped += 1; continue }
            // The chat's side folder (subagents, saved tool output), when it has one.
            let side = String(c.id.dropLast(6)), sideDest = String(dest.dropLast(6))
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: side, isDirectory: &isDir), isDir.boolValue, !fm.fileExists(atPath: sideDest) {
                try? fm.copyItem(atPath: side, toPath: sideDest)
            }
            copied += 1
        }
        return (copied, skipped)
    }

    /// Copies Claude Desktop Code-tab chats into another account's chat list. The transcript
    /// itself is shared on this Mac, so the copy opens the same conversation.
    static func copyDesktop(_ chats: [ChatItem], sessions: String, toUuid: String) -> (copied: Int, skipped: Int)? {
        let toDir = sessions + "/" + toUuid
        let orgs = ((try? fm.contentsOfDirectory(atPath: toDir)) ?? []).filter {
            var isDir: ObjCBool = false
            return fm.fileExists(atPath: toDir + "/" + $0, isDirectory: &isDir) && isDir.boolValue
        }
        func newest(_ org: String) -> Date {
            let dir = toDir + "/" + org
            return ((try? fm.contentsOfDirectory(atPath: dir)) ?? [])
                .compactMap { (try? fm.attributesOfItem(atPath: dir + "/" + $0))?[.modificationDate] as? Date }
                .max() ?? .distantPast
        }
        guard let org = orgs.max(by: { newest($0) < newest($1) }) else { return nil }
        var copied = 0, skipped = 0
        for c in chats {
            let dest = toDir + "/" + org + "/" + (c.id as NSString).lastPathComponent
            if fm.fileExists(atPath: dest) { skipped += 1; continue }
            if (try? fm.copyItem(atPath: c.id, toPath: dest)) != nil { copied += 1 } else { skipped += 1 }
        }
        return (copied, skipped)
    }
}

/// One MCP connection and where it lives.
struct MCPEntry: Identifiable {
    enum Scope: Hashable { case user, project(String), desktop }
    var id: String { "\(scopeKey)/\(name)" }
    let name: String
    let scope: Scope
    let config: [String: Any]
    var scopeKey: String {
        switch scope { case .user: return "user"; case .project(let p): return "project:" + p; case .desktop: return "desktop" }
    }
    var kind: String {
        if let t = config["type"] as? String { return t == "stdio" ? "Local" : t.uppercased() }
        return config["url"] != nil ? "HTTP" : "Local"
    }
    var summary: String {
        if let u = config["url"] as? String { return URL(string: u)?.host ?? u }
        let cmd = (config["command"] as? String).map { ($0 as NSString).lastPathComponent } ?? ""
        let arg = (config["args"] as? [String])?.first(where: { !$0.hasPrefix("-") }).map { ($0 as NSString).lastPathComponent } ?? ""
        return [cmd, arg].filter { !$0.isEmpty }.joined(separator: " ")
    }
}

enum MCPStore {
    static var desktopConfig: String {
        FileManager.default.homeDirectoryForCurrentUser.path + "/Library/Application Support/Claude/claude_desktop_config.json"
    }

    /// Every MCP connection a Claude Code account has: its own, its projects', and (shared on
    /// this Mac) Claude Desktop's.
    static func entries(state: String, includeCode: Bool) -> [MCPEntry] {
        var out: [MCPEntry] = []
        if includeCode {
            let st = EnvCopy.read(state)
            for (k, v) in (st["mcpServers"] as? [String: Any] ?? [:]).sorted(by: { $0.key.lowercased() < $1.key.lowercased() }) {
                out.append(MCPEntry(name: k, scope: .user, config: v as? [String: Any] ?? [:]))
            }
            for (path, proj) in (st["projects"] as? [String: Any] ?? [:]).sorted(by: { $0.key < $1.key }) {
                for (k, v) in ((proj as? [String: Any])?["mcpServers"] as? [String: Any] ?? [:]).sorted(by: { $0.key < $1.key }) {
                    out.append(MCPEntry(name: k, scope: .project(path), config: v as? [String: Any] ?? [:]))
                }
            }
        }
        for (k, v) in (EnvCopy.read(desktopConfig)["mcpServers"] as? [String: Any] ?? [:]).sorted(by: { $0.key.lowercased() < $1.key.lowercased() }) {
            out.append(MCPEntry(name: k, scope: .desktop, config: v as? [String: Any] ?? [:]))
        }
        return out
    }

    /// Adds the connections to another Claude Code account. Ones it already has by that name
    /// are left alone. Project connections go to the same project there.
    static func send(_ list: [MCPEntry], toState: String) -> (added: Int, skipped: Int) {
        var st = EnvCopy.read(toState)
        var user = st["mcpServers"] as? [String: Any] ?? [:]
        var projects = st["projects"] as? [String: Any] ?? [:]
        var added = 0, skipped = 0
        for e in list {
            switch e.scope {
            case .user, .desktop:
                if user[e.name] != nil { skipped += 1 } else { user[e.name] = e.config; added += 1 }
            case .project(let path):
                var proj = projects[path] as? [String: Any] ?? [:]
                var servers = proj["mcpServers"] as? [String: Any] ?? [:]
                if servers[e.name] != nil { skipped += 1; continue }
                servers[e.name] = e.config; added += 1
                proj["mcpServers"] = servers
                projects[path] = proj
            }
        }
        if added > 0 {
            st["mcpServers"] = user
            if !projects.isEmpty { st["projects"] = projects }
            EnvCopy.write(st, toState)
        }
        return (added, skipped)
    }
}

@MainActor
final class AccountData: ObservableObject {
    @Published var facts: [EnvFact] = []
    @Published var mcp: [MCPEntry] = []
    @Published var folders: [ChatFolder] = []
    @Published var loadingChats = true

    var chatCount: Int { folders.reduce(0) { $0 + $1.chats.count } }

    func projectsDir(_ a: Account, _ model: AppModel) -> String {
        (a.isDefault ? model.home + "/.claude" : a.dir) + "/projects"
    }
    var sessionsDir: String {
        FileManager.default.homeDirectoryForCurrentUser.path + "/Library/Application Support/Claude/claude-code-sessions"
    }

    /// The Claude account behind a Claude Desktop slot (nil until it has signed in once).
    static func desktopUuid(_ a: Account, _ model: AppModel) -> String? {
        let cfg = model.isActive(a) ? model.desktopSupport + "/config.json" : a.dir + "/config.json"
        return model.readJSON(cfg)?["lastKnownAccountUuid"] as? String
    }

    func stateFile(_ a: Account, _ model: AppModel) -> String {
        a.isDefault ? model.home + "/.claude.json" : a.dir + "/.claude.json"
    }

    func load(_ a: Account, _ model: AppModel) async {
        facts = environment(a, model)
        if a.service == .claude || a.service == .desktop {
            mcp = MCPStore.entries(state: stateFile(a, model), includeCode: a.service == .claude)
        }
        loadingChats = true
        let kind = a.service
        let projects = projectsDir(a, model)
        let sessions = sessionsDir
        let uuid = kind == .desktop ? Self.desktopUuid(a, model) : nil
        let chats: [ChatItem] = await Task.detached(priority: .userInitiated) {
            switch kind {
            case .claude: return ChatIndex.codeChats(projects: projects)
            case .desktop: return uuid.map { ChatIndex.desktopChats(sessions: sessions, accountUuid: $0) } ?? []
            default: return []
            }
        }.value
        // No animation here: hundreds of rows animating in at once stutter. The list
        // fades in as one piece instead (see ChatsPane).
        folders = ChatIndex.group(chats)
        loadingChats = false
    }

    func environment(_ a: Account, _ model: AppModel) -> [EnvFact] {
        let fm = FileManager.default
        var out: [EnvFact] = []
        func count(_ n: Int, _ one: String) -> String { n == 0 ? "None" : "\(n) \(one)\(n == 1 ? "" : "s")" }
        func names(_ list: [String]) -> String? { list.isEmpty ? nil : list.sorted().prefix(6).joined(separator: ", ") + (list.count > 6 ? "…" : "") }

        switch a.service {
        case .claude:
            let dir = a.isDefault ? model.home + "/.claude" : a.dir
            let state = model.readJSON(a.isDefault ? model.home + "/.claude.json" : a.dir + "/.claude.json") ?? [:]
            let oauth = state["oauthAccount"] as? [String: Any] ?? [:]
            let settings = model.readJSON(dir + "/settings.json") ?? [:]
            let perms = settings["permissions"] as? [String: Any] ?? [:]
            let mcp = (state["mcpServers"] as? [String: Any])?.keys.map { $0 } ?? []
            let plugins = (settings["enabledPlugins"] as? [String: Any])?.filter { ($0.value as? Bool) == true }.map(\.key) ?? []
            let skills = ((try? fm.contentsOfDirectory(atPath: dir + "/skills")) ?? []).filter { !$0.hasPrefix(".") }
            let hooks = (settings["hooks"] as? [String: Any])?.keys.map { $0 } ?? []
            let env = (settings["env"] as? [String: Any])?.keys.map { $0 } ?? []
            let status = settings["statusLine"] as? [String: Any]
            let statusText = status == nil ? "Off"
                : (((status?["command"] as? String) ?? "").contains("claude-status.sh") ? "AccountDeck limits" : "Your own")

            out.append(EnvFact(symbol: "person.crop.circle", hue: .blue, title: "Signed in",
                               value: oauth["emailAddress"] as? String ?? "Not signed in",
                               detail: oauth["organizationName"] as? String))
            out.append(EnvFact(symbol: "folder", hue: .cyan, title: "Config folder",
                               value: dir.replacingOccurrences(of: model.home, with: "~"),
                               detail: a.isDefault ? "Default (CLAUDE_CONFIG_DIR unset)" : "CLAUDE_CONFIG_DIR"))
            out.append(EnvFact(part: .model, symbol: "cpu", hue: .purple, title: "Model",
                               value: settings["model"] as? String ?? "Default", detail: nil))
            out.append(EnvFact(part: .permissions, symbol: "lock.shield", hue: .green, title: "Permissions",
                               value: perms["defaultMode"] as? String ?? "Ask each time",
                               detail: count((perms["allow"] as? [Any])?.count ?? 0, "allow rule")))
            out.append(EnvFact(part: .mcp, symbol: "point.3.connected.trianglepath.dotted", hue: .orange, title: "MCP servers",
                               value: count(mcp.count, "server"), detail: names(mcp)))
            out.append(EnvFact(part: .plugins, symbol: "puzzlepiece.extension", hue: .pink, title: "Plugins",
                               value: count(plugins.count, "plugin"), detail: names(plugins.map { $0.components(separatedBy: "@").first ?? $0 })))
            out.append(EnvFact(part: .skills, symbol: "sparkles.rectangle.stack", hue: .indigo, title: "Skills",
                               value: count(skills.count, "skill"), detail: names(skills)))
            out.append(EnvFact(part: .hooks, symbol: "bolt.horizontal", hue: .yellow, title: "Hooks",
                               value: count(hooks.count, "event"), detail: names(hooks)))
            out.append(EnvFact(part: .memory, symbol: "brain", hue: .teal, title: "Memory",
                               value: fm.fileExists(atPath: dir + "/CLAUDE.md") ? "CLAUDE.md" : "No CLAUDE.md", detail: nil))
            out.append(EnvFact(part: .env, symbol: "terminal", hue: .gray, title: "Environment",
                               value: count(env.count, "variable"), detail: names(env)))
            out.append(EnvFact(symbol: "gauge.with.needle", hue: .mint, title: "Status line",
                               value: statusText, detail: nil))

        case .codex:
            let dir = a.isDefault ? model.home + "/.codex" : a.dir
            let toml = (try? String(contentsOfFile: dir + "/config.toml", encoding: .utf8)) ?? ""
            let model_ = toml.split(separator: "\n").first { $0.hasPrefix("model ") || $0.hasPrefix("model=") }
                .map { $0.split(separator: "=", maxSplits: 1).last.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " \"")) } ?? "" }
            let mcp = toml.split(separator: "\n").compactMap { line -> String? in
                guard line.hasPrefix("[mcp_servers.") else { return nil }
                return String(line.dropFirst(13).dropLast()).components(separatedBy: ".").first
            }
            let sessions = (fm.enumerator(atPath: dir + "/sessions")?.allObjects as? [String] ?? []).filter { $0.hasSuffix(".jsonl") }.count
            out.append(EnvFact(symbol: "person.crop.circle", hue: .blue, title: "Signed in",
                               value: model.details[a.id] ?? "Not signed in", detail: nil))
            out.append(EnvFact(symbol: "folder", hue: .cyan, title: "Config folder",
                               value: dir.replacingOccurrences(of: model.home, with: "~"),
                               detail: a.isDefault ? "Default (CODEX_HOME unset)" : "CODEX_HOME"))
            out.append(EnvFact(symbol: "cpu", hue: .purple, title: "Model", value: model_ ?? "Default", detail: nil))
            out.append(EnvFact(symbol: "point.3.connected.trianglepath.dotted", hue: .orange, title: "MCP servers",
                               value: count(Set(mcp).count, "server"), detail: names(Array(Set(mcp)))))
            out.append(EnvFact(symbol: "text.bubble", hue: .green, title: "Sessions",
                               value: count(sessions, "session"), detail: "Saved in sessions/"))

        case .desktop:
            let saved = model.isActive(a) || model.desktopSlotHasLogin(a)
            let cfg = model.readJSON(model.desktopSupport + "/claude_desktop_config.json") ?? [:]
            let mcp = (cfg["mcpServers"] as? [String: Any])?.keys.map { $0 } ?? []
            out.append(EnvFact(symbol: "person.crop.circle", hue: .blue, title: "Login",
                               value: model.isActive(a) ? "Open in Claude now" : (saved ? "Saved, ready to switch" : "Sign in after switching"),
                               detail: nil))
            out.append(EnvFact(symbol: "folder", hue: .cyan, title: "Saved login folder",
                               value: a.dir.replacingOccurrences(of: model.home, with: "~"), detail: "Cookies and app settings only"))
            out.append(EnvFact(symbol: "point.3.connected.trianglepath.dotted", hue: .orange, title: "MCP servers",
                               value: count(mcp.count, "server"), detail: names(mcp).map { "Shared by all accounts: \($0)" }))
            out.append(EnvFact(symbol: "bubble.left.and.text.bubble.right", hue: .green, title: "Sync chats",
                               value: model.carryChat ? "On" : "Off", detail: "New, changed and deleted chats follow every switch"))

        case .chatgpt:
            out.append(EnvFact(symbol: "globe", hue: .green, title: "Browser profile",
                               value: a.dir.replacingOccurrences(of: model.home, with: "~"), detail: "Its own cookies and history"))
            out.append(EnvFact(symbol: "clock", hue: .gray, title: "Status",
                               value: model.details[a.id] ?? "", detail: nil))
        }
        return out
    }
}

// MARK: - Views

struct DashboardView: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject private var usage = UsageStore.shared
    @AppStorage(MenuLayout.orderKey) private var orderRaw = MenuLayout.defaultOrder
    @State private var selection: String?
    @State private var columns: NavigationSplitViewVisibility = DashboardView.startColumns
    static var startColumns: NavigationSplitViewVisibility = .all
    var initial: String?

    init(initial: String? = nil) {
        self.initial = initial
        _selection = State(initialValue: initial)
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $columns) {
            List(selection: $selection) {
                Label { Text("Dashboard") } icon: {
                    IconTile(symbol: "square.grid.2x2.fill", hue: .gray, size: 20)
                }
                .tag("dashboard")
                .padding(.vertical, 3)

                ForEach(MenuLayout.order(orderRaw)) { s in
                    let list = model.accounts(for: s)
                    if !list.isEmpty {
                        Section {
                            ForEach(list) { a in SidebarRow(account: a).tag(a.id) }
                        } header: {
                            HStack(spacing: 6) {
                                IconTile(symbol: s.symbol, hue: s.hue, size: 15)
                                Text(s.title)
                            }
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            .safeAreaInset(edge: .bottom) { SidebarFooter() }
            .navigationSplitViewColumnWidth(min: 230, ideal: 250, max: 320)
        } detail: {
            ZStack {
                if let id = selection, let a = model.accounts.first(where: { $0.id == id }) {
                    AccountPage(account: a)
                        .id(a.id)
                } else {
                    DashboardHome(open: { selection = $0 })
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .frame(minWidth: 640, minHeight: 480)
        #if SNAPSHOT
        .onReceive(NotificationCenter.default.publisher(for: .init("snap.select"))) { n in selection = n.object as? String }
        .onReceive(NotificationCenter.default.publisher(for: .init("snap.columns"))) { n in
            withAnimation { columns = (n.object as? String) == "hide" ? .detailOnly : .all }
        }
        #endif
        .onAppear {
            if selection == nil { selection = "dashboard" }
            model.refresh()
            usage.refresh(model.accounts)
        }
    }
}

/// The bottom of the sidebar: Terminal setup when it's needed, then the quick actions.
struct SidebarFooter: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        VStack(spacing: 10) {
            if !model.shellLinked {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        IconTile(symbol: "exclamationmark.triangle.fill", hue: .orange, size: 22)
                        VStack(alignment: .leading, spacing: 0) {
                            Text("Connect Terminal").font(.system(size: 12, weight: .semibold))
                            Text("Lets Claude Code and Codex switch").font(.system(size: 10.5)).foregroundStyle(.secondary)
                        }
                    }
                    Button { withAnimation(Motion.travel) { model.linkShell() } } label: {
                        Text("Connect").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent).controlSize(.small)
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.orange.opacity(0.09)))
                .transition(.opacity.combined(with: .offset(y: 8)))
            }
            HStack(spacing: 0) {
                QuickTile(title: "Terminal", help: "New Terminal window with the active accounts",
                          symbol: "terminal") { model.openTerminal() }
                QuickTile(title: "Sync Chats", help: "New and changed Code-tab chats follow you to every Claude account when you switch",
                          symbol: "bubble.left.and.text.bubble.right", on: model.carryChat) { model.carryChat.toggle() }
                QuickTile(title: "At Login", help: "Open AccountDeck in the menu bar when you log in",
                          symbol: "power", on: model.launchAtLogin) { model.toggleLaunchAtLogin() }
                QuickTile(title: "Data", help: "Show AccountDeck's data folder",
                          symbol: "folder") { NSWorkspace.shared.open(URL(fileURLWithPath: model.root)) }
            }
            CreditLink(size: 10.5)
        }
        .padding(.horizontal, 10).padding(.vertical, 12)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
        .animation(Motion.travel, value: model.shellLinked)
    }
}

struct SidebarRow: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.backgroundProminence) private var prominence
    let account: Account
    var body: some View {
        HStack(spacing: 8) {
            Avatar(name: account.name, hue: account.service.hue, size: 22)
            VStack(alignment: .leading, spacing: 0) {
                Text(account.name).font(.system(size: 13))
                Text(model.details[account.id] ?? "").font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            if model.isActive(account) && account.service != .chatgpt {
                Circle().fill(prominence == .increased ? Color.white : account.service.hue)
                    .frame(width: 7, height: 7).help("Active")
            }
        }
        .padding(.vertical, 2)
    }
}

enum PageTab: String, CaseIterable { case overview = "Overview", chats = "Chats" }

struct AccountPage: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject private var usage = UsageStore.shared
    @AppStorage(MenuLayout.limitKey) private var limitPref = "auto"
    @StateObject private var data = AccountData()
    let account: Account
    static var startTab: PageTab = .overview
    @State private var tab: PageTab = AccountPage.startTab
    @State private var shown = false
    @State private var tabIn = true
    @State private var renaming = false
    @State private var newName = ""

    var hasChats: Bool { account.service == .claude || account.service == .desktop }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                hero.stagger(0, shown)

                if hasChats {
                    Picker("", selection: $tab) {
                        Text("Overview").tag(PageTab.overview)
                        Text(data.loadingChats ? "Chats" : "Chats  \(data.chatCount >= 400 ? "400+" : "\(data.chatCount)")").tag(PageTab.chats)
                    }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
                    .stagger(1, shown)
                }

                Group {
                    switch tab {
                    case .overview: overview
                    case .chats: ChatsPane(account: account, data: data)
                    }
                }
                // The old tab goes at once; the new one fades in. (A removal transition would
                // keep the old tab on screen under the new one for the length of the fade.)
                .opacity(tabIn ? 1 : 0)
                .onChange(of: tab) { _, _ in
                    var t = Transaction(); t.disablesAnimations = true
                    withTransaction(t) { tabIn = false }
                    DispatchQueue.main.async { withAnimation(.easeOut(duration: 0.18)) { tabIn = true } }
                }
            }
            .padding(.horizontal, 32).padding(.top, 16).padding(.bottom, 28)
            .frame(maxWidth: 900, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        #if SNAPSHOT
        .onReceive(NotificationCenter.default.publisher(for: .init("snap.tab"))) { n in tab = (n.object as? String) == "chats" ? .chats : .overview }
        #endif
        .task {
            shown = true
            await data.load(account, model)
        }
    }

    // MARK: hero
    var hero: some View {
        ViewThatFits(in: .horizontal) {
            heroRow(stacked: false)
            heroRow(stacked: true)
        }
    }

    @ViewBuilder func heroButton() -> some View {
        if !model.isActive(account) || account.service == .chatgpt {
            Button(account.service == .chatgpt ? "Open ChatGPT" : (account.service == .desktop ? "Switch Claude" : "Use This Account")) {
                model.select(account)
            }
            .buttonStyle(.borderedProminent).controlSize(.large)
        }
    }

    @ViewBuilder func heroRow(stacked: Bool) -> some View {
        if stacked {
            VStack(alignment: .leading, spacing: 12) { heroMain; heroButton() }
        } else {
            HStack(alignment: .center, spacing: 18) { heroMain; Spacer(minLength: 16); heroButton() }
        }
    }

    var heroMain: some View {
        let active = model.isActive(account)
        return HStack(alignment: .center, spacing: 18) {
            Avatar(name: account.name, hue: account.service.hue, size: 64)
            VStack(alignment: .leading, spacing: 5) {
                Text(account.name).font(.system(size: 24, weight: .bold))
                Text(model.details[account.id] ?? "").font(.system(size: 13)).foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    HStack(spacing: 5) {
                        IconTile(symbol: account.service.symbol, hue: account.service.hue, size: 16)
                        Text(account.service.title).font(.system(size: 11.5, weight: .medium))
                    }
                    .padding(.leading, 3).padding(.trailing, 8).padding(.vertical, 3)
                    .background(Capsule().fill(Color.primary.opacity(0.06)))
                    if active && account.service != .chatgpt {
                        Label("Active", systemImage: "checkmark.circle.fill")
                            .font(.system(size: 11.5, weight: .semibold))
                            .foregroundStyle(account.service.hue)
                    }
                }
            }
        }
    }

    // MARK: overview
    var overview: some View {
        VStack(alignment: .leading, spacing: 22) {
            // One limit: the 5-hour window, or the weekly one when that is the only limit.
            if let u = usage.usage[account.id]?.view(limitPref) {
                VStack(alignment: .leading, spacing: 8) {
                    SectionLabel("Usage limit")
                    LimitCard(window: u.window, percent: u.percent, resetsAt: u.resetsAt, estimated: u.estimated)
                }
                .stagger(2, shown)
            } else if account.service == .claude {
                HStack(spacing: 12) {
                    HintCard(symbol: "gauge.with.needle", hue: .green,
                             title: usage.claudeTracking ? "No limit reported yet" : "Usage limits are off for Claude Code",
                             text: usage.claudeTracking ? "It shows after Claude Code's next reply in this account."
                                                        : "Adds a status line hook that saves the limits on this Mac. It prints nothing.")
                    if !usage.claudeTracking {
                        Button("Turn On") {
                            let skipped = usage.enableClaudeTracking(model.accounts)
                            if !skipped.isEmpty {
                                model.flash("Skipped \(skipped.joined(separator: ", ")): it has its own status line")
                            }
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
                .stagger(2, shown)
            }

            EnvironmentSection(account: account, data: data, shown: shown).stagger(3, shown)
            if !data.mcp.isEmpty {
                MCPPanel(account: account, data: data).stagger(4, shown)
            }

            HStack(spacing: 10) {
                Button { model.reveal(account) } label: { Label("Show in Finder", systemImage: "folder") }
                Button { newName = account.name; renaming = true } label: { Label("Rename…", systemImage: "pencil") }
                    .popover(isPresented: $renaming, arrowEdge: .bottom) {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Rename Account").font(.system(size: 13, weight: .semibold))
                            TextField("Name", text: $newName).textFieldStyle(.roundedBorder).frame(width: 220)
                                .onSubmit { model.applyRename(account, to: newName); renaming = false }
                            HStack {
                                Spacer()
                                Button("Cancel") { renaming = false }
                                Button("Rename") { model.applyRename(account, to: newName); renaming = false }
                                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                            }
                        }
                        .padding(14)
                    }
                if account.service != .desktop {
                    Button { model.signIn(account) } label: { Label("Sign In Again", systemImage: "arrow.triangle.2.circlepath") }
                }
            }
            .controlSize(.regular)
        }
    }
}

struct SectionLabel: View {
    let text: String
    init(_ t: String) { text = t }
    var body: some View {
        Text(text).font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary).padding(.leading, 2)
    }
}

extension View {
    /// Arrives with a short stagger once `shown` turns true: 6 pt rise, 0.32 s, 40 ms apart,
    /// at most five steps, so a page is settled in under half a second.
    func stagger(_ i: Int, _ shown: Bool) -> some View {
        opacity(shown ? 1 : 0)
            .offset(y: shown ? 0 : 6)
            .animation(.timingCurve(0.25, 0.8, 0.25, 1, duration: 0.32).delay(Double(min(i, 4)) * 0.04), value: shown)
    }
}

struct LimitCard: View {
    let window: String
    let percent: Double
    let resetsAt: Date?
    var estimated = false
    @State private var drawn = false
    var tint: Color { percent >= 85 ? .red : (percent >= 60 ? .orange : .green) }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { ctx in
            HStack(spacing: 14) {
                ZStack {
                    Circle().stroke(Color.primary.opacity(0.1), lineWidth: 6)
                    Circle().trim(from: 0, to: drawn ? max(0.02, min(percent / 100, 1)) : 0)
                        .stroke(tint, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                    Text("\(Int(percent.rounded()))%")
                        .font(.system(size: 13, weight: .semibold, design: .rounded).monospacedDigit())
                        .contentTransition(.numericText())
                }
                .frame(width: 54, height: 54)
                VStack(alignment: .leading, spacing: 3) {
                    Text("\(window) limit").font(.system(size: 13, weight: .semibold))
                    if let r = resetsAt {
                        Label("Resets in \(estimated ? "about " : "")\(UsageBadge.long(r.timeIntervalSince(ctx.date)))", systemImage: "timer")
                            .font(.system(size: 11.5)).foregroundStyle(.secondary)
                    } else {
                        Text("Nothing used in this window").font(.system(size: 11.5)).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(14)
            .frame(maxWidth: 300)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(0.045)))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
        }
        .onAppear { withAnimation(Motion.arrive.delay(0.25)) { drawn = true } }
    }
}

struct FactCard: View {
    let fact: EnvFact
    var picked: Bool? = nil          // nil: this card can't be sent to another account
    var onPick: () -> Void = {}
    @State private var hover = false
    var body: some View {
        let on = picked == true
        HStack(alignment: .top, spacing: 10) {
            IconTile(symbol: fact.symbol, hue: fact.hue, size: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(fact.title).font(.system(size: 11)).foregroundStyle(.secondary)
                Text(fact.value).font(.system(size: 13, weight: .medium)).lineLimit(1).truncationMode(.middle)
                if let d = fact.detail {
                    Text(d).font(.system(size: 11)).foregroundStyle(.tertiary).lineLimit(2)
                }
            }
            Spacer(minLength: 0)
            if picked != nil {
                CheckMark(on: on, partial: false, action: onPick)
                    .opacity(on || hover ? 1 : 0.45)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 64, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(on ? Color.accentColor.opacity(0.09) : Color.primary.opacity(hover ? 0.07 : 0.045)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(on ? Color.accentColor.opacity(0.55) : Color.primary.opacity(0.08), lineWidth: on ? 1 : 0.5))
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .onTapGesture { if picked != nil { onPick() } }
        .onHover { h in withAnimation(Motion.quick) { hover = h } }
        .animation(Motion.quick, value: on)
        .help(fact.detail.map { "\(fact.value)\n\($0)" } ?? fact.value)
    }
}

/// The environment cards. On a Claude Code account, pick cards and send them to another account.
struct EnvironmentSection: View {
    @EnvironmentObject var model: AppModel
    let account: Account
    @ObservedObject var data: AccountData
    let shown: Bool
    @State private var picked: Set<EnvPart> = []
    @State private var result: String?

    var canSend: Bool { account.service == .claude }
    var destinations: [Account] { model.accounts(for: .claude).filter { $0.id != account.id } }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                SectionLabel("Environment")
                Spacer()
                if canSend {
                    if !picked.isEmpty {
                        Text("\(picked.count) selected").font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                            .contentTransition(.numericText())
                        Button("Clear") { withAnimation(Motion.quick) { picked.removeAll() } }
                            .buttonStyle(.plain).foregroundStyle(Color.accentColor).font(.system(size: 12))
                    } else {
                        ViewThatFits(in: .horizontal) {
                            Text(destinations.isEmpty ? "Add a second Claude Code account to send these to it" : "Pick cards, then Send to Account")
                                .font(.system(size: 11.5)).foregroundStyle(.tertiary).lineLimit(1)
                            Color.clear.frame(width: 0, height: 0)
                        }
                    }
                    if destinations.isEmpty {
                        AddAccountButton(service: .claude)
                    } else {
                        Menu {
                            ForEach(destinations) { d in
                                Button("\(d.name)  ·  \(model.details[d.id] ?? "")") { send(to: d) }
                            }
                        } label: { Label("Send to Account", systemImage: "paperplane") }
                        .menuStyle(.borderedButton).fixedSize()
                        .disabled(picked.isEmpty)
                    }
                }
            }
            .animation(Motion.quick, value: picked.isEmpty)

            if let result {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    Text(result).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button { withAnimation(Motion.quick) { self.result = nil } } label: { Image(systemName: "xmark") }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.green.opacity(0.1)))
                .transition(.opacity.combined(with: .offset(y: -6)))
            }

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 230), spacing: 12)], alignment: .leading, spacing: 12) {
                ForEach(Array(data.facts.enumerated()), id: \.element.id) { i, f in
                    FactCard(fact: f,
                             picked: canSend && f.part != nil ? picked.contains(f.part!) : nil,
                             onPick: {
                                 guard let part = f.part else { return }
                                 withAnimation(Motion.quick) {
                                     if picked.contains(part) { picked.remove(part) } else { picked.insert(part) }
                                 }
                             })
                }
            }
        }
    }

    func send(to dest: Account) {
        let fromDir = account.isDefault ? model.home + "/.claude" : account.dir
        let toDir = dest.isDefault ? model.home + "/.claude" : dest.dir
        let fromState = account.isDefault ? model.home + "/.claude.json" : account.dir + "/.claude.json"
        let toState = dest.isDefault ? model.home + "/.claude.json" : dest.dir + "/.claude.json"
        let lines = EnvCopy.copy(Array(picked), fromDir: fromDir, toDir: toDir, fromState: fromState, toState: toState)
        withAnimation(Motion.travel) {
            result = "Sent to \(dest.name): " + lines.joined(separator: " · ")
                + ". Nothing it already had was replaced, except the model. Its old settings are backed up next to them."
            picked.removeAll()
        }
    }
}

/// Copies parts of one Claude Code account's setup into another. Merges, never removes: what
/// the destination already has stays. Backs up each file it changes first. Logins are never touched.
enum EnvCopy {
    static let fm = FileManager.default

    static func read(_ path: String) -> [String: Any] {
        fm.contents(atPath: path).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
    }

    static func write(_ json: [String: Any], _ path: String) {
        if fm.fileExists(atPath: path) {
            let f = DateFormatter(); f.dateFormat = "yyyyMMdd-HHmmss"
            try? fm.copyItem(atPath: path, toPath: path + ".accountdeck-" + f.string(from: Date()))
        }
        try? fm.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        if let d = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]) {
            try? d.write(to: URL(fileURLWithPath: path))
        }
    }

    /// Adds the keys of `src` that `dst` lacks.
    static func mergeKeys(_ dst: Any?, _ src: Any?) -> ([String: Any], Int) {
        var out = dst as? [String: Any] ?? [:]
        var n = 0
        for (k, v) in src as? [String: Any] ?? [:] where out[k] == nil { out[k] = v; n += 1 }
        return (out, n)
    }

    static func copy(_ parts: [EnvPart], fromDir: String, toDir: String, fromState: String, toState: String) -> [String] {
        var report: [String] = []
        let src = read(fromDir + "/settings.json")
        var dst = read(toDir + "/settings.json")
        var settingsChanged = false

        for part in EnvPart.allCases where parts.contains(part) {
            switch part {
            case .model:
                if let m = src["model"] { dst["model"] = m; settingsChanged = true; report.append("model") }
                else { report.append("no model to send") }
            case .permissions:
                var p = dst["permissions"] as? [String: Any] ?? [:]
                let sp = src["permissions"] as? [String: Any] ?? [:]
                var added = 0
                for key in ["allow", "deny", "ask", "additionalDirectories"] {
                    let have = p[key] as? [String] ?? []
                    let more = (sp[key] as? [String] ?? []).filter { !have.contains($0) }
                    if !more.isEmpty { p[key] = have + more; added += more.count }
                }
                if p["defaultMode"] == nil, let m = sp["defaultMode"] { p["defaultMode"] = m; added += 1 }
                dst["permissions"] = p; settingsChanged = true
                report.append("\(added) permission rule\(added == 1 ? "" : "s")")
            case .plugins:
                let (ep, n) = mergeKeys(dst["enabledPlugins"], src["enabledPlugins"])
                let (mk, _) = mergeKeys(dst["extraKnownMarketplaces"], src["extraKnownMarketplaces"])
                if !ep.isEmpty { dst["enabledPlugins"] = ep }
                if !mk.isEmpty { dst["extraKnownMarketplaces"] = mk }
                settingsChanged = true
                report.append("\(n) plugin\(n == 1 ? "" : "s")")
            case .hooks:
                var h = dst["hooks"] as? [String: Any] ?? [:]
                var added = 0
                for (event, v) in src["hooks"] as? [String: Any] ?? [:] {
                    var have = h[event] as? [Any] ?? []
                    let seen = Set(have.compactMap { (try? JSONSerialization.data(withJSONObject: $0, options: .sortedKeys)).map { String(decoding: $0, as: UTF8.self) } })
                    for entry in v as? [Any] ?? [] {
                        let key = (try? JSONSerialization.data(withJSONObject: entry, options: .sortedKeys)).map { String(decoding: $0, as: UTF8.self) } ?? ""
                        if !seen.contains(key) { have.append(entry); added += 1 }
                    }
                    h[event] = have
                }
                if !h.isEmpty { dst["hooks"] = h }
                settingsChanged = true
                report.append("\(added) hook\(added == 1 ? "" : "s")")
            case .env:
                let (e, n) = mergeKeys(dst["env"], src["env"])
                if !e.isEmpty { dst["env"] = e }
                settingsChanged = true
                report.append("\(n) variable\(n == 1 ? "" : "s")")
            case .mcp:
                var state = read(toState)
                let (m, n) = mergeKeys(state["mcpServers"], read(fromState)["mcpServers"])
                if n > 0 { state["mcpServers"] = m; write(state, toState) }
                report.append("\(n) MCP server\(n == 1 ? "" : "s")")
            case .skills:
                let from = fromDir + "/skills", to = toDir + "/skills"
                try? fm.createDirectory(atPath: to, withIntermediateDirectories: true)
                var n = 0
                for name in (try? fm.contentsOfDirectory(atPath: from)) ?? [] where !name.hasPrefix(".") {
                    if !fm.fileExists(atPath: to + "/" + name), (try? fm.copyItem(atPath: from + "/" + name, toPath: to + "/" + name)) != nil { n += 1 }
                }
                report.append("\(n) skill\(n == 1 ? "" : "s")")
            case .memory:
                let s = fromDir + "/CLAUDE.md", d = toDir + "/CLAUDE.md"
                if !fm.fileExists(atPath: s) { report.append("no CLAUDE.md to send") }
                else if fm.fileExists(atPath: d) { report.append("CLAUDE.md kept (it has its own)") }
                else { try? fm.copyItem(atPath: s, toPath: d); report.append("CLAUDE.md") }
            }
        }
        if settingsChanged { write(dst, toDir + "/settings.json") }
        return report
    }
}

struct HintCard: View {
    let symbol: String, hue: Color, title: String, text: String
    var body: some View {
        HStack(spacing: 10) {
            IconTile(symbol: symbol, hue: hue, size: 26)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 13, weight: .medium))
                Text(text).font(.system(size: 11.5)).foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(0.045)))
    }
}

// MARK: - MCP connections

struct MCPPanel: View {
    @EnvironmentObject var model: AppModel
    let account: Account
    @ObservedObject var data: AccountData
    @State private var picked: Set<String> = []
    @State private var result: String?

    var destinations: [Account] { model.accounts(for: .claude).filter { $0.id != account.id } }
    var allPicked: Bool { !data.mcp.isEmpty && picked.count == data.mcp.count }

    struct MCPGroup: Identifiable { let id: String; let title: String; let symbol: String; let items: [MCPEntry] }
    var groups: [MCPGroup] {
        var out: [MCPGroup] = []
        let user = data.mcp.filter { $0.scope == .user }
        if !user.isEmpty { out.append(MCPGroup(id: "user", title: "This account · every folder", symbol: "person.crop.circle", items: user)) }
        var projects: [String: [MCPEntry]] = [:]
        for e in data.mcp { if case .project(let p) = e.scope { projects[p, default: []].append(e) } }
        for (p, items) in projects.sorted(by: { $0.key < $1.key }) {
            out.append(MCPGroup(id: "p:" + p, title: "Only in " + (p as NSString).lastPathComponent, symbol: "folder", items: items))
        }
        let desk = data.mcp.filter { $0.scope == .desktop }
        if !desk.isEmpty { out.append(MCPGroup(id: "desktop", title: "Claude Desktop · shared by its accounts", symbol: "macwindow", items: desk)) }
        return out
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                SectionLabel("MCP connections")
                Text("\(data.mcp.count)").font(.system(size: 11, weight: .medium).monospacedDigit()).foregroundStyle(.secondary)
                    .padding(.horizontal, 7).padding(.vertical, 2).background(Capsule().fill(Color.primary.opacity(0.06)))
                Spacer()
                Button(allPicked ? "Deselect All" : "Select All") {
                    withAnimation(Motion.quick) { picked = allPicked ? [] : Set(data.mcp.map(\.id)) }
                }
                .buttonStyle(.plain).foregroundStyle(Color.accentColor).font(.system(size: 12))
                if destinations.isEmpty {
                    AddAccountButton(service: .claude)
                } else {
                    Menu {
                        ForEach(destinations) { d in
                            Button("\(d.name)  ·  \(model.details[d.id] ?? "")") { send(to: d) }
                        }
                    } label: {
                        Label(picked.isEmpty ? "Send to Account" : "Send \(picked.count) to Account", systemImage: "paperplane")
                    }
                    .menuStyle(.borderedButton).fixedSize()
                    .disabled(picked.isEmpty)
                }
            }
            .animation(Motion.quick, value: picked.count)

            if let result {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    Text(result).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button { withAnimation(Motion.quick) { self.result = nil } } label: { Image(systemName: "xmark") }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.green.opacity(0.1)))
                .transition(.opacity.combined(with: .offset(y: -6)))
            }

            GroupCard {
                ForEach(Array(groups.enumerated()), id: \.element.id) { gi, g in
                    if gi > 0 { Divider() }
                    // Group header: pick the whole group.
                    let ids = Set(g.items.map(\.id))
                    HStack(spacing: 10) {
                        CheckMark(on: ids.isSubset(of: picked), partial: !ids.isDisjoint(with: picked) && !ids.isSubset(of: picked)) {
                            withAnimation(Motion.quick) { if ids.isSubset(of: picked) { picked.subtract(ids) } else { picked.formUnion(ids) } }
                        }
                        Image(systemName: g.symbol).font(.system(size: 12)).foregroundStyle(.secondary).frame(width: 18)
                        Text(g.title).font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                        Spacer()
                    }
                    .padding(.horizontal, 12).padding(.top, 9).padding(.bottom, 5)
                    ForEach(g.items) { e in
                        MCPRow(entry: e, on: picked.contains(e.id)) {
                            withAnimation(Motion.quick) { if picked.contains(e.id) { picked.remove(e.id) } else { picked.insert(e.id) } }
                        }
                    }
                }
            }

            Text("Each connection is added to the other account under the same name; ones it already has stay as they are. Online connections that need a sign-in (like Figma) ask you to connect once in the other account; sign-ins are never copied.")
                .font(.system(size: 11)).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
        }
    }

    func send(to dest: Account) {
        let list = data.mcp.filter { picked.contains($0.id) }
        let r = MCPStore.send(list, toState: data.stateFile(dest, model))
        withAnimation(Motion.travel) {
            result = "Sent \(r.added) MCP connection\(r.added == 1 ? "" : "s") to \(dest.name)"
                + (r.skipped > 0 ? " (\(r.skipped) it already had)" : "")
                + ". They load next time Claude Code starts in that account."
            picked.removeAll()
        }
    }
}

struct MCPRow: View {
    let entry: MCPEntry
    let on: Bool
    let toggle: () -> Void
    @State private var hover = false
    var body: some View {
        HStack(spacing: 10) {
            CheckMark(on: on, partial: false, action: toggle)
            IconTile(symbol: entry.kind == "Local" ? "shippingbox.fill" : "globe", hue: entry.kind == "Local" ? .orange : .blue, size: 20)
            Text(entry.name).font(.system(size: 12.5, weight: .medium))
            Text(entry.summary).font(.system(size: 11)).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 8)
            Text(entry.kind).font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(Capsule().fill(Color.primary.opacity(0.06)))
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(on ? Color.accentColor.opacity(0.08) : (hover ? Color.primary.opacity(0.04) : .clear))
        .contentShape(Rectangle())
        .onTapGesture(perform: toggle)
        .onHover { h in withAnimation(Motion.quick) { hover = h } }
    }
}

// MARK: - Chats

/// A paper plane that lists the accounts a chat or folder can go to.
struct SendMenu: View {
    @EnvironmentObject var model: AppModel
    let destinations: [Account]
    let send: (Account) -> Void
    var body: some View {
        Menu {
            if destinations.isEmpty { Text("No other account to send to yet") }
            ForEach(destinations) { d in
                Button { send(d) } label: { Text("Send to \(d.name)  ·  \(model.details[d.id] ?? "")") }
            }
        } label: {
            Image(systemName: "paperplane")
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .help("Send to another account")
    }
}

/// Adds an account from the window, the same way the menu does.
struct AddAccountButton: View {
    @EnvironmentObject var model: AppModel
    let service: Service
    @State private var show = false
    @State private var name = ""
    var body: some View {
        Button { name = ""; show = true } label: { Label("Add \(service.title) Account…", systemImage: "plus") }
            .popover(isPresented: $show, arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("New \(service.title) Account").font(.system(size: 13, weight: .semibold))
                    TextField("Work, Personal, Client…", text: $name).textFieldStyle(.roundedBorder).frame(width: 240)
                        .onSubmit(add)
                    Text(service == .desktop ? "Claude restarts signed out. Sign in with the new account."
                                             : "A Terminal window opens to sign in to this account only.")
                        .font(.system(size: 11)).foregroundStyle(.secondary).frame(width: 240, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Spacer()
                        Button("Cancel") { show = false }
                        Button("Add", action: add).buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                            .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
                .padding(14)
            }
    }
    func add() {
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        show = false
        model.add(service: service, name: name)
    }
}

struct SentResult: Equatable {
    var message: String
    var dest: Account
    var chats: [ChatItem]
    var copied: Int
    static func == (a: SentResult, b: SentResult) -> Bool { a.message == b.message }
}

struct ChatsPane: View {
    @EnvironmentObject var model: AppModel
    let account: Account
    @ObservedObject var data: AccountData
    @State private var picked: Set<String> = []
    @State private var query = ""
    @State private var result: SentResult?

    var destinations: [Account] { model.accounts(for: account.service).filter { $0.id != account.id } }

    var visible: [ChatFolder] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return data.folders }
        return data.folders.compactMap { f in
            let chats = f.chats.filter { $0.title.lowercased().contains(q) || f.name.lowercased().contains(q) }
            return chats.isEmpty ? nil : ChatFolder(path: f.path, chats: chats)
        }
    }

    var pickedChats: [ChatItem] { data.folders.flatMap(\.chats).filter { picked.contains($0.id) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Toolbar: search, what is picked, and where it goes.
            HStack(spacing: 10) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Search chats and folders", text: $query).textFieldStyle(.plain)
                }
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.06)))
                .frame(maxWidth: 280)

                Spacer()

                if !picked.isEmpty {
                    Text("\(picked.count) selected")
                        .font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                        .contentTransition(.numericText())
                    Button("Clear") { withAnimation(Motion.quick) { picked.removeAll() } }
                        .buttonStyle(.plain).foregroundStyle(Color.accentColor).font(.system(size: 12))
                }

                if destinations.isEmpty {
                    AddAccountButton(service: account.service)
                } else {
                    Menu {
                        ForEach(destinations) { d in
                            Button { send(pickedChats, to: d) } label: { Text("\(d.name)  ·  \(model.details[d.id] ?? "")") }
                        }
                    } label: {
                        Label(picked.isEmpty ? "Send to Account" : "Send \(picked.count) to Account", systemImage: "paperplane")
                    }
                    .menuStyle(.borderedButton).fixedSize()
                    .disabled(picked.isEmpty)
                }
            }
            .animation(Motion.quick, value: picked.isEmpty)

            // How it works, said once, quietly.
            if result == nil {
                Text(destinations.isEmpty
                     ? "To send chats, add a second \(account.service.title) account first."
                     : "Tick chats or a whole folder, then Send to Account. Or hover any chat or folder and click its paper plane.")
                    .font(.system(size: 11.5)).foregroundStyle(.tertiary)
            }

            if let r = result {
                HStack(spacing: 10) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).font(.system(size: 16))
                    Text(r.message).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    if account.service == .claude, let first = r.chats.first {
                        Button { openInTerminal(r.chats, first: first, as: r.dest) } label: {
                            Label("Open as \(r.dest.name)", systemImage: "terminal")
                        }
                        .buttonStyle(.borderedProminent).controlSize(.small)
                    } else if account.service == .desktop, !model.isActive(r.dest) {
                        Button { model.select(r.dest) } label: { Label("Switch Claude to \(r.dest.name)", systemImage: "arrow.left.arrow.right") }
                            .buttonStyle(.borderedProminent).controlSize(.small)
                    }
                    Button { withAnimation(Motion.quick) { result = nil } } label: { Image(systemName: "xmark") }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.green.opacity(0.1)))
                .transition(.opacity.combined(with: .offset(y: -6)))
            }

            Group {
            if data.loadingChats {
                HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Reading chats…").foregroundStyle(.secondary) }
                    .font(.system(size: 12)).padding(.vertical, 20)
            } else if account.service == .desktop && AccountData.desktopUuid(account, model) == nil {
                HintCard(symbol: "person.crop.circle.badge.questionmark", hue: .orange, title: "Not signed in yet",
                         text: "Switch Claude to this account once; its chats show here after that.")
            } else if visible.isEmpty {
                HintCard(symbol: "bubble.left.and.bubble.right", hue: .gray, title: query.isEmpty ? "No chats yet" : "No matches",
                         text: query.isEmpty ? "Chats this account has on this Mac show here." : "Try another word.")
            } else {
                LazyVStack(alignment: .leading, spacing: 14) {
                    ForEach(visible) { f in
                        FolderCard(folder: f, picked: $picked, destinations: destinations,
                                   send: { chats, d in send(chats, to: d) })
                    }
                }
                .transition(.opacity)
            }
            }
            // The spinner gives way to the list with one short fade.
            .animation(.easeOut(duration: 0.2), value: data.loadingChats)

            // The rules, said once, at the foot.
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "lock.shield").foregroundStyle(.secondary)
                Text("Chats are copied between your own accounts on this Mac only. Nothing is uploaded, nothing is deleted, and logins are never read. Chats on claude.ai stay with their account. Each account keeps its own plan, limits and Anthropic's usage policies.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, 6)
        }
    }

    func send(_ chats: [ChatItem], to dest: Account) {
        guard !chats.isEmpty else { return }
        var message = "", copied = 0
        switch account.service {
        case .claude:
            let from = data.projectsDir(account, model), to = data.projectsDir(dest, model)
            let r = ChatIndex.copyCode(chats, from: from, to: to)
            copied = r.copied
            message = "Sent \(chats.count) chat\(chats.count == 1 ? "" : "s") to \(dest.name)"
                + (r.skipped > 0 ? " (\(r.skipped) were already there)" : "")
                + ". Same folder, same history."
        case .desktop:
            guard let uuid = AccountData.desktopUuid(dest, model),
                  let r = ChatIndex.copyDesktop(chats, sessions: data.sessionsDir, toUuid: uuid) else {
                message = "\(dest.name) hasn't signed in to Claude yet. Switch to it once, then send again."
                break
            }
            copied = r.copied
            message = "Sent \(chats.count) chat\(chats.count == 1 ? "" : "s") to \(dest.name)"
                + (r.skipped > 0 ? " (\(r.skipped) were already there)" : "")
                + ". They show in its Code tab."
        default: break
        }
        withAnimation(Motion.travel) {
            result = SentResult(message: message, dest: dest, chats: chats, copied: copied)
            picked.subtract(chats.map(\.id))
        }
    }

    /// Opens Terminal in the chat's folder, signed in as the other account, and resumes it.
    func openInTerminal(_ chats: [ChatItem], first: ChatItem, as dest: Account) {
        let sid = ((first.id as NSString).lastPathComponent as NSString).deletingPathExtension
        var lines = [dest.isDefault ? "unset CLAUDE_CONFIG_DIR" : "export CLAUDE_CONFIG_DIR=\(model.shq(dest.dir))"]
        if !first.folder.isEmpty { lines.append("cd \(model.shq(first.folder)) || exit 1") }
        lines.append(chats.count == 1 ? "claude --resume \(sid)" : "claude --resume")
        model.runInTerminal(title: "Claude Code — \(dest.name)", lines: lines)
    }
}

struct FolderCard: View {
    let folder: ChatFolder
    @Binding var picked: Set<String>
    let destinations: [Account]
    let send: ([ChatItem], Account) -> Void
    @State private var open = true
    @State private var hover = false

    var ids: Set<String> { Set(folder.chats.map(\.id)) }
    var allPicked: Bool { ids.isSubset(of: picked) }
    var somePicked: Bool { !ids.isDisjoint(with: picked) }

    var body: some View {
        GroupCard {
            // Folder row: pick the whole folder, send it, or open and close it.
            HStack(spacing: 10) {
                CheckMark(on: allPicked, partial: somePicked && !allPicked) {
                    withAnimation(Motion.quick) {
                        if allPicked { picked.subtract(ids) } else { picked.formUnion(ids) }
                    }
                }
                Image(systemName: "folder.fill").foregroundStyle(Color.accentColor.opacity(0.85))
                VStack(alignment: .leading, spacing: 0) {
                    Text(folder.name).font(.system(size: 13, weight: .semibold))
                    Text(folder.path.isEmpty ? "—" : folder.path.replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~"))
                        .font(.system(size: 10.5)).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle)
                }
                Spacer()
                if !destinations.isEmpty {
                    SendMenu(destinations: destinations) { d in send(folder.chats, d) }
                        .opacity(hover ? 1 : 0)
                        .help("Send the whole folder (\(folder.chats.count) chats) to another account")
                }
                Text("\(folder.chats.count)").font(.system(size: 11, weight: .medium).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(Capsule().fill(Color.primary.opacity(0.06)))
                Button { withAnimation(Motion.travel) { open.toggle() } } label: {
                    Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold))
                        .rotationEffect(.degrees(open ? 90 : 0))
                        .frame(width: 20, height: 20).contentShape(Rectangle())
                }
                .buttonStyle(.plain).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12).padding(.vertical, 9)
            .contentShape(Rectangle())
            .onHover { h in withAnimation(Motion.quick) { hover = h } }

            if open {
                ForEach(folder.chats.prefix(40)) { c in
                    RowDivider(inset: 44)
                    ChatRow(chat: c, on: picked.contains(c.id), destinations: destinations,
                            toggle: {
                                withAnimation(Motion.quick) {
                                    if picked.contains(c.id) { picked.remove(c.id) } else { picked.insert(c.id) }
                                }
                            },
                            send: { d in send([c], d) })
                }
                .transition(.opacity)
                if folder.chats.count > 40 {
                    RowDivider(inset: 44)
                    Text("\(folder.chats.count - 40) older chats — tick or send the folder to include them")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                        .padding(.leading, 44).padding(.vertical, 8)
                }
            }
        }
    }
}

struct ChatRow: View {
    let chat: ChatItem
    let on: Bool
    let destinations: [Account]
    let toggle: () -> Void
    let send: (Account) -> Void
    @State private var hover = false
    static let rel: RelativeDateTimeFormatter = { let f = RelativeDateTimeFormatter(); f.unitsStyle = .abbreviated; return f }()

    var body: some View {
        HStack(spacing: 10) {
            CheckMark(on: on, partial: false, action: toggle)
            Text(chat.title).font(.system(size: 12.5)).lineLimit(1).foregroundStyle(.primary)
            Spacer(minLength: 12)
            if !destinations.isEmpty {
                SendMenu(destinations: destinations, send: send)
                    .opacity(hover ? 1 : 0)
            }
            Text(Self.rel.localizedString(for: chat.date, relativeTo: Date()))
                .font(.system(size: 11)).foregroundStyle(.secondary)
            Text(ByteCountFormatter.string(fromByteCount: chat.size, countStyle: .file))
                .font(.system(size: 11).monospacedDigit()).foregroundStyle(.tertiary)
                .frame(width: 60, alignment: .trailing)
        }
        .padding(.horizontal, 12).padding(.vertical, 7)
        .background(on ? Color.accentColor.opacity(0.08) : (hover ? Color.primary.opacity(0.04) : .clear))
        .contentShape(Rectangle())
        .onTapGesture(perform: toggle)
        .onHover { h in withAnimation(Motion.quick) { hover = h } }
    }
}

struct CheckMark: View {
    let on: Bool
    let partial: Bool
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: on ? "checkmark.circle.fill" : (partial ? "minus.circle.fill" : "circle"))
                .font(.system(size: 16))
                .symbolRenderingMode(.palette)
                .foregroundStyle(on || partial ? Color.white : Color.secondary.opacity(0.5),
                                 on || partial ? Color.accentColor : Color.secondary.opacity(0.5))
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 22, height: 22)
        }
        .buttonStyle(.plain)
    }
}
