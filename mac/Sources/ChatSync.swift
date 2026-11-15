// AccountDeck — keeps Claude Desktop's Code-tab chats the same on every account.
//
// Claude Desktop lists Code-tab chats per account in
//   claude-code-sessions/<account uuid>/<organization>/local_<id>.json
// (the conversation itself lives in ~/.claude/projects, shared by all accounts).
// A deleted chat leaves a small "deleted_<id>" marker in its place.
//
// On every switch, while Claude is closed, the account you switch to gets:
//   - every chat any other account has that it doesn't (new chats you made elsewhere),
//   - the newer copy of every chat both have (renames, archiving, new turns),
//   - the deletions you made elsewhere (its copy moves to ~/.accountdeck/moved-chats).
// Switching back later brings that account up to date the same way.

import Foundation

enum ChatSync {
    struct Result { var added = 0, updated = 0, removed = 0 }

    static let fm = FileManager.default

    /// - sessions: the claude-code-sessions folder. - to: the account uuid now signed in.
    /// - keep: where replaced or deleted copies are saved first.
    @discardableResult
    static func sync(sessions: String, to target: String, keep: String) -> Result {
        var r = Result()
        func dirs(_ p: String) -> [String] {
            ((try? fm.contentsOfDirectory(atPath: p)) ?? []).filter {
                var d: ObjCBool = false
                return fm.fileExists(atPath: p + "/" + $0, isDirectory: &d) && d.boolValue
            }
        }
        // A copied file's time can come back a few nanoseconds short, so "newer" means by more than this.
        let slack: TimeInterval = 0.5
        func mtime(_ p: String) -> Date { ((try? fm.attributesOfItem(atPath: p))?[.modificationDate] as? Date) ?? .distantPast }

        // Everything every account has: newest copy of each chat, and every deletion marker.
        var newest: [String: String] = [:]          // local_<id>.json -> path of the newest copy
        var deleted: [String: String] = [:]         // <id> -> path of a deleted_<id> marker
        var mine: [String: [String]] = [:]          // the target's own chats: file name -> paths
        var targetOrgs: [String] = []
        for acc in dirs(sessions) {
            for org in dirs(sessions + "/" + acc) {
                let dir = "\(sessions)/\(acc)/\(org)"
                if acc == target { targetOrgs.append(dir) }
                for f in (try? fm.contentsOfDirectory(atPath: dir)) ?? [] {
                    let p = dir + "/" + f
                    if f.hasPrefix("deleted_") { deleted[String(f.dropFirst(8))] = p; continue }
                    guard f.hasPrefix("local_"), f.hasSuffix(".json") else { continue }
                    if acc == target { mine[f, default: []].append(p) }
                    if let cur = newest[f], mtime(cur) >= mtime(p) - slack { continue }
                    newest[f] = p
                }
            }
        }
        // New chats go where this account keeps its chats now: its most recently used organization.
        func lastUsed(_ dir: String) -> Date {
            ((try? fm.contentsOfDirectory(atPath: dir)) ?? []).filter { $0.hasPrefix("local_") }
                .map { mtime(dir + "/" + $0) }.max() ?? .distantPast
        }
        guard let home = targetOrgs.max(by: { lastUsed($0) < lastUsed($1) }) else { return r }

        func save(_ p: String) {
            try? fm.createDirectory(atPath: keep, withIntermediateDirectories: true)
            let dest = keep + "/" + (p as NSString).lastPathComponent
            try? fm.removeItem(atPath: dest)
            try? fm.copyItem(atPath: p, toPath: dest)
        }
        func copy(_ src: String, to dest: String) -> Bool {
            let tmp = dest + ".accountdeck-tmp"
            try? fm.removeItem(atPath: tmp)
            guard (try? fm.copyItem(atPath: src, toPath: tmp)) != nil else { return false }
            try? fm.setAttributes([.modificationDate: mtime(src)], ofItemAtPath: tmp)   // keeps "newest" honest
            try? fm.removeItem(atPath: dest)
            return (try? fm.moveItem(atPath: tmp, toPath: dest)) != nil
        }

        for (name, src) in newest {
            let id = String(name.dropFirst(6).dropLast(5))
            if let marker = deleted[id] {
                // Deleted somewhere: delete it here too, the way Claude does.
                for p in mine[name] ?? [] {
                    save(p)
                    let dir = (p as NSString).deletingLastPathComponent
                    if !fm.fileExists(atPath: dir + "/deleted_" + id) { _ = copy(marker, to: dir + "/deleted_" + id) }
                    try? fm.removeItem(atPath: p)
                    r.removed += 1
                }
                continue
            }
            if let paths = mine[name] {
                var changed = false
                for p in paths where p != src && mtime(src) > mtime(p) + slack {
                    save(p); if copy(src, to: p) { changed = true }
                }
                if changed { r.updated += 1 }
            } else if copy(src, to: home + "/" + name) {
                r.added += 1
            }
        }
        return r
    }
}
