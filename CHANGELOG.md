# Changelog

## macOS 1.4
- **Fixed: the menu panel could open empty.** Its contents only showed once the panel had keyboard focus, which macOS doesn't always give it. Now they show whenever the panel is on screen.
- **More accurate usage:**
  - Codex reads the session log that was written last, not the one with the newest name, so a long-running session's latest numbers are used.
  - Codex readings now say how old they are ("as of 3 days ago"), and reset times are counted from when the reading was taken.
  - Claude Desktop skips false 0% readings: a 5-hour figure of 0 while weekly use went up in the same window.
  - When a Claude Code login and a Claude Desktop login are the same Claude account, Claude Code's exact numbers win over Desktop's estimate unless the estimate is clearly newer.

## macOS 1.3
- Code-tab chats in Claude Desktop follow you between accounts: new, changed and deleted chats sync on every switch. Chat lists are backed up before the first sync.

## macOS 1.2
- Usage limits update live: AccountDeck watches the files they come from, so new readings show within about a second.
- Rows say how fresh each reading is.

## Windows 1.0 (beta)
- First Windows version: switching, live usage and the Dashboard. Not yet tested on a real Windows PC.
