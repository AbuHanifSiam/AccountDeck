# AccountDeck for macOS

A SwiftUI menu bar app with a Dashboard window. It has no dependencies, so you only need Xcode or the Command Line Tools.

```bash
./build.sh      # universal (arm64 + x86_64) AccountDeck.app, installed in ~/Applications
./make-dmg.sh   # the same, packed as dist/AccountDeck-<version>.dmg with install notes
```

The version number is set in `build.sh` (`CFBundleShortVersionString`).

| File | What's in it |
|---|---|
| `Sources/main.swift` | accounts, switching, Claude Desktop login swap, usage reading and live file watching, menu bar panel |
| `Sources/ChatSync.swift` | keeps Claude Desktop Code-tab chats in sync between accounts on every switch |
| `Sources/Dashboard.swift` | the Dashboard window, account pages, chats and MCP |
| `Sources/Home.swift` | Dashboard home, usage rows and credit |
| `Icon/` | the app icon: `make-icon.swift` turns `artwork.jpg` into `AppIcon.icns` |

Data lives in `~/.accountdeck`: saved Claude Desktop logins, per-account config folders, the status-line hook (`claude-status.sh`), and chat backups (`chat-lists-backup`, `moved-chats`).
