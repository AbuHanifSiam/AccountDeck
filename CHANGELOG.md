# Changelog

## macOS 1.5.1
- **Get exact usage for Claude Desktop accounts.** A Claude Desktop account without exact numbers shows a "Get exact usage" link. It opens one Claude Code sign-in with that Claude account, kept in its own folder only for reading usage. After that, the account shows exact numbers.
- **One Keychain question instead of several.** AccountDeck opens only the newest matching login and keeps it in memory, so macOS asks once per login.
- **Usage goes on the right account.** AccountDeck asks Anthropic which Claude account a login belongs to before showing its numbers.

## macOS 1.5
- **Exact usage (optional).** With your permission, AccountDeck gets your current usage from Anthropic with your Claude Code login, the same numbers as `/usage`, about once a minute. It shows them on the right Claude account in Claude Code and Claude Desktop. A pop-up asks once (Allow or Skip); change it in Customize Menu → Exact Usage, which also shows whether it's working.
- When that login has expired, AccountDeck renews it the way Claude Code does and saves it back, so Claude Code stays signed in. It doesn't renew unless it can save the new login.

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
