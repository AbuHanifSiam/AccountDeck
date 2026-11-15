// AccountDeck — the Dashboard: the window's home page. Totals at the top, every account's usage
// limit as a meter with its number and reset, who is signed in now, and the common actions.
// Layout follows the usage pages of Grok, StackAI and Cofounder (seen on Mobbin): a snapshot
// strip, meters with the figure on the right, and a grid of action tiles.

import SwiftUI
import AppKit

// MARK: - Credit

/// "Made by Nadim Sheikh", linking to the developer's X profile.
struct CreditLink: View {
    var size: CGFloat = 11
    @State private var hover = false
    var body: some View {
        Link(destination: URL(string: "https://x.com/Nadim_404")!) {
            HStack(spacing: 3) {
                Text("Made by")
                Text("Nadim Sheikh").fontWeight(.semibold)
            }
            .font(.system(size: size))
            .foregroundStyle(hover ? Color.accentColor : Color.secondary)
            .underline(hover, color: Color.accentColor.opacity(0.6))
        }
        .buttonStyle(.plain)
        .onHover { h in withAnimation(Motion.quick) { hover = h } }
        .help("x.com/Nadim_404")
    }
}

// MARK: - Numbers

enum Fmt {
    static func count(_ n: Int) -> String {
        let f = NumberFormatter(); f.numberStyle = .decimal
        return f.string(from: NSNumber(value: n)) ?? "\(n)"
    }
    static func percent(_ p: Double) -> String { "\(Int(p.rounded()))%" }
    static func reset(_ u: Usage, now: Date = Date()) -> String {
        guard let r = u.resetsAt else { return "—" }
        return (u.estimated ? "~" : "") + UsageBadge.short(r.timeIntervalSince(now))
    }
}

// MARK: - Stats

struct DashStats: Equatable {
    var chats = 0
    var mcp = 0
    var skills = 0
    var loaded = false

    /// Counted from files on this Mac, in the background.
    static func load(_ accounts: [Account], home: String) async -> DashStats {
        await Task.detached(priority: .utility) {
            let fm = FileManager.default
            var s = DashStats()
            var mcpNames = Set<String>()
            for a in accounts where a.service == .claude {
                let dir = a.isDefault ? home + "/.claude" : a.dir
                for d in (try? fm.contentsOfDirectory(atPath: dir + "/projects")) ?? [] {
                    s.chats += ((try? fm.contentsOfDirectory(atPath: dir + "/projects/" + d)) ?? []).filter { $0.hasSuffix(".jsonl") }.count
                }
                s.skills += ((try? fm.contentsOfDirectory(atPath: dir + "/skills")) ?? []).filter { !$0.hasPrefix(".") }.count
                let state = a.isDefault ? home + "/.claude.json" : a.dir + "/.claude.json"
                for e in MCPStore.entries(state: state, includeCode: true) { mcpNames.insert(e.scopeKey + "/" + e.name) }
            }
            if !accounts.contains(where: { $0.service == .claude }) {
                for e in MCPStore.entries(state: "", includeCode: false) { mcpNames.insert(e.scopeKey + "/" + e.name) }
            }
            s.mcp = mcpNames.count
            s.loaded = true
            return s
        }.value
    }
}

// MARK: - Dashboard

struct DashboardHome: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject private var usage = UsageStore.shared
    @AppStorage(MenuLayout.orderKey) private var orderRaw = MenuLayout.defaultOrder
    let open: (String) -> Void
    @State private var stats = DashStats()
    @State private var shown = false

    var greeting: String {
        let h = Calendar.current.component(.hour, from: Date())
        return h < 12 ? "Good morning" : (h < 18 ? "Good afternoon" : "Good evening")
    }
    var services: [Service] { MenuLayout.order(orderRaw).filter { !model.accounts(for: $0).isEmpty } }
    var usedApps: Int { services.count }
    var needsSetup: Bool {
        !model.shellLinked || (!usage.claudeTracking && model.accounts.contains { $0.service == .claude })
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header.stagger(0, shown)
                StatsStrip(cells: [
                    ("Accounts", model.accounts.count, "\(usedApps) apps"),
                    ("Chats", stats.loaded ? stats.chats : nil, "Claude Code"),
                    ("MCP", stats.loaded ? stats.mcp : nil, "connections"),
                    ("Skills", stats.loaded ? stats.skills : nil, "Claude Code"),
                ])
                .stagger(1, shown)

                if needsSetup { setup.stagger(2, shown) }

                // One card per app: its accounts, who's signed in, usage and reset, and Switch.
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 400), spacing: 16, alignment: .top)],
                          alignment: .leading, spacing: 16) {
                    ForEach(services) { s in AppCard(service: s, open: open) }
                }
                .stagger(3, shown)

                VStack(alignment: .leading, spacing: 4) {
                    if usage.usage.values.contains(where: { $0.estimated }) {
                        Text("~ Claude Desktop readings are as recent as its last usage check, shown on each row; reset times are estimated.")
                    }
                    Text("A Claude Code login and a Claude Desktop login on the same Claude account share their limits.")
                }
                .font(.system(size: 11)).foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
                .stagger(4, shown)

                HStack { Spacer(); CreditLink(size: 11.5); Spacer() }
            }
            .padding(.horizontal, 32).padding(.top, 16).padding(.bottom, 28)
            .frame(maxWidth: 1000, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task {
            shown = true
            stats = await DashStats.load(model.accounts, home: model.home)
        }
    }

    var header: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 12) { titleBlock; Spacer(minLength: 16); headerButtons }
            VStack(alignment: .leading, spacing: 12) { titleBlock; headerButtons }
        }
    }

    var titleBlock: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Dashboard").font(.system(size: 26, weight: .bold))
            Text("\(greeting). \(model.accounts.count) accounts across \(usedApps) apps, all on this Mac.")
                .font(.system(size: 13)).foregroundStyle(.secondary)
        }
    }

    var headerButtons: some View {
        HStack(spacing: 8) {
            Button { model.openTerminal() } label: { Label("New Terminal", systemImage: "terminal") }
                .controlSize(.large)
            AddAnyAccountButton()
        }
    }

    var setup: some View {
        GroupCard {
            if !model.shellLinked {
                NoticeRow(symbol: "exclamationmark.triangle.fill", hue: .orange, title: "Connect Terminal",
                          text: "Claude Code and Codex switch accounts through it.", button: "Connect") {
                    withAnimation(Motion.travel) { model.linkShell() }
                }
            }
            if !model.shellLinked && !usage.claudeTracking { RowDivider(inset: 48) }
            if !usage.claudeTracking && model.accounts.contains(where: { $0.service == .claude }) {
                NoticeRow(symbol: "gauge.with.needle", hue: .green, title: "Track Claude Code limits",
                          text: "Adds a quiet status line hook that saves its limits on this Mac.", button: "Turn On") {
                    _ = usage.enableClaudeTracking(model.accounts)
                }
            }
        }
    }
}

/// Four numbers in one card, divided like a stat bar; two by two when narrow.
struct StatsStrip: View {
    let cells: [(String, Int?, String)]
    var body: some View {
        ViewThatFits(in: .horizontal) {
            row(cells, minCell: 130)
            VStack(spacing: 0) {
                row(Array(cells.prefix(2)), minCell: 0)
                Divider()
                row(Array(cells.suffix(2)), minCell: 0)
            }
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(0.045)))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
        }
    }

    func row(_ list: [(String, Int?, String)], minCell: CGFloat) -> some View {
        HStack(spacing: 0) {
            ForEach(Array(list.enumerated()), id: \.offset) { i, c in
                if i > 0 { Divider().frame(height: 44) }
                VStack(alignment: .leading, spacing: 2) {
                    Text(c.0).font(.system(size: 11.5, weight: .medium)).foregroundStyle(.secondary)
                    Text(c.1.map(Fmt.count) ?? "–")
                        .font(.system(size: 24, weight: .semibold, design: .rounded).monospacedDigit())
                        .contentTransition(.numericText(value: Double(c.1 ?? 0)))
                        .animation(Motion.travel, value: c.1)
                    Text(c.2).font(.system(size: 11)).foregroundStyle(.tertiary)
                }
                .lineLimit(1)
                .frame(minWidth: minCell, maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16).padding(.vertical, 12)
            }
        }
        .background(minCell > 0 ? RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(0.045)) : nil)
        .overlay(minCell > 0 ? RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5) : nil)
    }
}

struct NoticeRow: View {
    let symbol: String, hue: Color, title: String, text: String, button: String
    let action: () -> Void
    var body: some View {
        HStack(spacing: 12) {
            IconTile(symbol: symbol, hue: hue, size: 26)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Text(text).font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer(minLength: 12)
            Button(button, action: action).buttonStyle(.borderedProminent).controlSize(.small)
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
    }
}

/// One app: its accounts with who's signed in, each limit as number + meter + reset, and Switch.
struct AppCard: View {
    @EnvironmentObject var model: AppModel
    let service: Service
    let open: (String) -> Void

    var body: some View {
        let list = model.accounts(for: service)
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                IconTile(symbol: service.symbol, hue: service.hue, size: 20)
                Text(service.title).font(.system(size: 13, weight: .semibold))
                Text("\(list.count)").font(.system(size: 11, weight: .medium).monospacedDigit()).foregroundStyle(.secondary)
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .background(Capsule().fill(Color.primary.opacity(0.06)))
                Spacer()
                Text(service.whereItRuns).font(.system(size: 11)).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 4)
            GroupCard {
                ForEach(Array(list.enumerated()), id: \.element.id) { i, a in
                    if i > 0 { RowDivider(inset: 52) }
                    AppAccountRow(account: a) { open(a.id) }
                }
            }
        }
    }
}

struct AppAccountRow: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject private var usage = UsageStore.shared
    @AppStorage(MenuLayout.limitKey) private var limitPref = "auto"
    let account: Account
    let open: () -> Void
    @State private var hover = false

    var body: some View {
        let active = model.isActive(account) && account.service != .chatgpt
        let u = usage.usage[account.id]?.view(limitPref)
        TimelineView(.periodic(from: .now, by: 30)) { ctx in
            HStack(spacing: 12) {
                Avatar(name: account.name, hue: account.service.hue, size: 30)
                VStack(alignment: .leading, spacing: 2) {
                    // The name comes first; the "In use" label gives way when space is tight
                    // (the check on the right says the same thing).
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 6) {
                            Text(account.name).font(.system(size: 13, weight: .medium)).fixedSize()
                            if active {
                                Text("In use").font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(account.service.hue)
                                    .fixedSize()
                                    .padding(.horizontal, 6).padding(.vertical, 1)
                                    .background(Capsule().fill(account.service.hue.opacity(0.14)))
                            }
                        }
                        Text(account.name).font(.system(size: 13, weight: .medium)).lineLimit(1)
                    }
                    Text(subtitle(u, now: ctx.date)).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                    // Claude Desktop only has estimates: offer the one sign-in that gets exact numbers.
                    if account.service == .desktop, u?.estimated ?? true, model.signedIn[account.id] == true {
                        // Its own high-priority tap: the row's tap (open the account) would otherwise take it.
                        Text("Get exact usage")
                            .font(.system(size: 11, weight: .medium)).foregroundStyle(Color.accentColor)
                            .contentShape(Rectangle())
                            .highPriorityGesture(TapGesture().onEnded { model.getExactUsage(account) })
                            .onHover { inside in if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() } }
                            .help("Sign in to Claude Code once with this Claude account, so AccountDeck can show its exact usage")
                    }
                }
                .frame(minWidth: 70, alignment: .leading)
                .layoutPriority(1)
                Spacer(minLength: 10)
                if let u {
                    // With room: number, reset and a bar. Without: just the number and reset.
                    ViewThatFits(in: .horizontal) {
                        VStack(alignment: .trailing, spacing: 5) {
                            figures(u, now: ctx.date)
                            MeterBar(percent: u.percent).frame(width: 110)
                        }
                        figures(u, now: ctx.date)
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    .help(UsageBadge(usage: u).tooltip(ctx.date))
                }
                trailing(active: active)
            }
            .padding(.horizontal, 12).padding(.vertical, 9)
            .background(hover ? Color.primary.opacity(0.04) : .clear)
            .contentShape(Rectangle())
            .onTapGesture(perform: open)
        }
        .onHover { h in withAnimation(Motion.quick) { hover = h } }
    }

    func figures(_ u: Usage, now: Date) -> some View {
        HStack(spacing: 8) {
            Text(Fmt.percent(u.percent))
                .font(.system(size: 14, weight: .semibold).monospacedDigit())
                .foregroundStyle(u.percent >= 85 ? Color.red : (u.percent >= 60 ? Color.orange : Color.primary))
                .fixedSize()
            HStack(spacing: 3) {
                Image(systemName: "timer").font(.system(size: 9.5, weight: .semibold))
                Text(Fmt.reset(u, now: now)).font(.system(size: 11.5).monospacedDigit())
            }
            .fixedSize()
            .foregroundStyle(.secondary).opacity(u.resetsAt == nil ? 0.45 : 1)
            .frame(width: 46, alignment: .trailing)
        }
    }

    func subtitle(_ u: Usage?, now: Date) -> String {
        guard let u else {
            if account.service == .claude { return "Limit shows after its next reply" }
            return model.details[account.id] ?? ""
        }
        var t = "\(u.window) limit"
        if let a = u.asOf {
            // Claude Code only reports limits when it replies, so say how fresh this is.
            let mins = now.timeIntervalSince(a) / 60
            t += mins < 2 ? " · just now" : " · as of \(UsageBadge.long(now.timeIntervalSince(a))) ago"
        }
        return t
    }

    @ViewBuilder func trailing(active: Bool) -> some View {
        if account.service == .chatgpt {
            Button("Open") { model.select(account) }.controlSize(.small)
        } else if active {
            Image(systemName: "checkmark.circle.fill").font(.system(size: 17))
                .symbolRenderingMode(.palette).foregroundStyle(.white, account.service.hue)
                .frame(width: 58)
        } else {
            Button("Switch") { model.select(account) }.controlSize(.small).fixedSize().frame(minWidth: 58)
        }
    }
}

/// The header's Add Account: pick the app, name it, and sign in the same way the menu does.
struct AddAnyAccountButton: View {
    @EnvironmentObject var model: AppModel
    @State private var show = false
    @State private var service: Service = .claude
    @State private var name = ""

    var body: some View {
        Button { name = ""; show = true } label: { Label("Add Account", systemImage: "plus") }
            .buttonStyle(.borderedProminent).controlSize(.large)
            .popover(isPresented: $show, arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("New Account").font(.system(size: 13, weight: .semibold))
                    Picker("App", selection: $service) {
                        ForEach(Service.allCases) { s in Text(s.title).tag(s) }
                    }
                    .frame(width: 260)
                    TextField("Work, Personal, Client…", text: $name).textFieldStyle(.roundedBorder).frame(width: 260)
                        .onSubmit(add)
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

// MARK: - Parts

/// A horizontal meter, filled to the percentage, coloured by how close it is to the limit.
struct MeterBar: View {
    let percent: Double
    @State private var drawn = false
    var tint: Color { percent >= 85 ? .red : (percent >= 60 ? .orange : .green) }
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.08))
                Capsule().fill(tint)
                    .frame(width: max(percent > 0 ? 6 : 0, g.size.width * CGFloat(min(percent, 100) / 100) * (drawn ? 1 : 0)))
            }
        }
        .frame(height: 6)
        .onAppear { withAnimation(.timingCurve(0.25, 0.8, 0.25, 1, duration: 0.6).delay(0.1)) { drawn = true } }
    }
}
