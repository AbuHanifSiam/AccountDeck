# AccountDeck for Windows

A tray app that switches between several accounts of **Claude Desktop, Claude Code, Codex and ChatGPT** on one Windows PC, with a Dashboard window. It is the Windows version of the Mac menu bar app.

Made by [Nadim Sheikh](https://x.com/Nadim_404).

---

## For friends: installing

1. Download an installer:
   - **Easiest:** `AccountDeck-Setup-1.0.0.exe` (162 MB). It works on every PC and picks the right version by itself.
   - Smaller, if you know your PC: `AccountDeck-Setup-1.0.0-x64.exe` (80 MB) for most PCs (Intel/AMD), or `AccountDeck-Setup-1.0.0-arm64.exe` (96 MB) for Windows on Arm (Snapdragon / Surface Pro X). Not sure which you have? Open **Settings → System → About** and look at "System type".
2. Double-click it. **Windows SmartScreen will warn you** because the app isn't signed with a paid certificate:
   click **More info**, then **Run anyway**.
3. Pick where to install (the default is fine) and finish. AccountDeck opens its Dashboard and puts a small round face icon in the tray, next to the clock. If you don't see the icon, click the **^** arrow by the clock.

**First run**
- Your current logins become each app's **Main** account. Nothing changes until you switch.
- To see Claude Code limits, click **Turn On** under "Track Claude Code limits" on the Dashboard. It adds a quiet status-line hook. It's never added over a status line you already have.
- Claude Code and Codex switches apply to **terminal windows you open after switching**. Close and reopen your terminal, or use **New Terminal** in AccountDeck.

To uninstall, use **Settings → Apps**. Your saved account folders stay in `%USERPROFILE%\.accountdeck`. Delete that folder if you want them gone.

---

## What it does

| | How switching works on Windows |
|---|---|
| **Claude Desktop** | Closes Claude, saves its login files (cookies and `config.json`) into the current account's folder, puts the chosen account's back, and reopens Claude. The original login is backed up once, to `%USERPROFILE%\.accountdeck\desktop\_original-backup`. |
| **Claude Code** | Each account has its own config folder. AccountDeck sets the per-user variable `CLAUDE_CONFIG_DIR` (in `HKCU\Environment`, then broadcasts `WM_SETTINGCHANGE`). For Main the variable is removed, so Claude Code uses `%USERPROFILE%\.claude`. |
| **Codex** | Works the same way with `CODEX_HOME` (Main uses `%USERPROFILE%\.codex`). |
| **ChatGPT** | Each account gets its own Chrome, Brave or Edge profile (`--user-data-dir`), opened on chatgpt.com. |

**Tray menu.** Accounts are grouped by app, and the active one is ticked. Click an account to switch. Each row has a usage badge (`42% · 2h`). The menu also has **Add … Account**, **Customize** (show/hide apps, *Limit to show*: Auto / 5-hour / Weekly, usage on rows, Start with Windows, Change order…), **New Terminal**, the credit and **Quit**. Left- or right-click opens the menu. Double-click opens the Dashboard.

**Dashboard** (opens first)
- A stats strip: accounts, chats, MCP connections, skills.
- One card per app, listing its accounts with *In use* / *Switch*, a usage bar, % used and time to reset.
- An account page for each account:
  - **Overview** cards: signed-in email, config folder, model, permissions, MCP servers, plugins, skills, hooks, CLAUDE.md, and environment variable **names only**. You can send any of those parts to another Claude Code account. Sending merges and never removes, and the old files are backed up first.
  - **Chats**: Claude Code chats from `<config>\projects\*\*.jsonl`, grouped by folder. Tick chats or whole folders and copy them to another account. A copy never overwrites a chat that's already there. **Resume** opens a chat with `claude --resume`.
- **MCP connections**: lists every server an account can use (its own, its projects', and Claude Desktop's) and sends the ticked ones to another Claude Code account. Sending merges, never overwrites, and backs up `.claude.json` first.
- **Customize** has the same settings as the tray menu, plus the app order.

**Usage limits.** These are read only from files on the PC, and they update live: AccountDeck watches the files, so a new reading shows within about a second.
- **Claude Code.** The status-line hook (`%USERPROFILE%\.accountdeck\claude-status.ps1`, a PowerShell script that prints nothing) saves the JSON that Claude Code passes it to `<config>\.accountdeck-status\<session>.json`. AccountDeck reads `rate_limits.five_hour` / `seven_day` from it. Claude Code only runs the status line while it's working, so the figure is as fresh as your last message.
- **Codex.** Reads `rate_limits` from the newest session log in `<CODEX_HOME>\sessions`.
- **Claude Desktop.** Reads `plan-usage-history.json` in its data folder, if present. That file has no reset time, so the reset is estimated and shown with `~`.

**Safety.** Passwords and tokens are never shown, copied out or sent anywhere. Everything stays on the PC.
- Claude Desktop's login files are only moved between its own data folder and `%USERPROFILE%\.accountdeck`.
- The Codex email comes from the `email` claim of the local id token, decoded in memory. The token itself is never stored or shown.
- MCP and environment pages show variable *names* only.

---

## Building (from a Mac or a PC)

The stack is **Electron + electron-builder**. I chose it because it can produce a Windows NSIS installer from macOS without a Windows machine, .NET or Wine.

Requirements: Node.js 18 or newer.

```bash
npm install
```

```bash
npm test
```

This runs the core switching, usage and copy logic against a fake Windows profile.

```bash
npm run dist
```

This writes `dist/AccountDeck-Setup-<version>.exe` (both architectures) plus `-x64.exe` and `-arm64.exe`. On a Mac, electron-builder downloads its own Wine copy to embed the exe icon.

To try the UI on a Mac with fake data (Windows actions turn into no-ops off Windows):

```bash
node test/fake-home.js /tmp/deck-home && ACCOUNTDECK_TEST_HOME=/tmp/deck-home npx electron .
```

**Project layout**

```
src/main.js          tray menu, window, IPC, live usage watching
src/preload.js       the only bridge between the window and the app
src/core/model.js    accounts, switching, Claude Desktop file swap, carry last chat
src/core/usage.js    status-line hook, Codex / Desktop usage parsing
src/core/data.js     chats, MCP, environment cards, merge-copy between accounts
src/core/win.js      Windows-only actions (env vars, closing/opening Claude, browsers, terminals)
src/core/paths.js    where things live (including the Microsoft Store data folder)
src/ui/              Dashboard (plain HTML/CSS/JS)
build/icon.ico       app icon (from the Mac artwork); assets/tray-*.png = mascot tray glyph
tools/make-tray.js   draws the tray glyph
```

---

## Not tested (no Windows PC was available)

Everything below was written from documentation and Electron defaults. The logic was unit-tested on macOS against a fake Windows profile, and the Dashboard was rendered and checked on macOS, but **none of it has run on Windows yet**. Please try these on a real PC first:

1. **The installer itself.** Installing, the Start menu and desktop shortcuts, uninstalling, and the SmartScreen prompt. Both the x64 and the arm64 builds are untested.
2. **Tray icon and menu.** How it looks on light and dark taskbars and at 125/150% scaling, and that left-click opens the menu.
3. **Claude Desktop switching**, the riskiest part. Check these:
   - Claude closes. AccountDeck first asks it to close its window, then ends the `claude.exe` processes under its install folder after about 4 s. Processes are matched by install path so a Claude Code `claude.exe` is never touched.
   - The login really moves with the files. Check signing in to account B, switching back to A, then to B again. *Unverified:* that the files are `Network\Cookies` (current Chromium) or `Cookies` (older), plus `config.json`, as on the Mac. Their contents are encrypted with a key in `Local State`, which AccountDeck leaves in place, so saved logins should work on the same Windows user.
   - **Microsoft Store / MSIX install.** Data is read from `%LOCALAPPDATA%\Packages\Claude_*\LocalCache\Roaming\Claude` when that folder is the newer one. Reopening uses its Start-menu AppID (`Get-StartApps`). The package name `Claude_pzs8sxrjxfjjc` comes from user reports and is matched with a wildcard, so treat it as unverified.
   - **Direct installer.** AccountDeck reopens Claude with `%LOCALAPPDATA%\AnthropicClaude\claude.exe` (unverified) and falls back to the exe that was running.
   - "Bring last chat" uses `claude-code-sessions` in the data folder. It's assumed to have the same layout as on the Mac.
4. **Environment variables.** That `CLAUDE_CONFIG_DIR` / `CODEX_HOME` appear in new cmd, PowerShell and Windows Terminal windows after a switch. Windows Terminal only picks up the new value in new tabs when it reloads its environment, so restart it if a new tab still uses the old account. VS Code's terminal needs VS Code restarted.
5. **Sign-in terminals.** `claude /login` and `codex login` opening in a new console with the right variable set. Check this with a user name that has spaces or accents.
6. **The status-line hook.** That Claude Code on Windows runs `powershell -NoProfile -ExecutionPolicy Bypass -File "C:/Users/…/claude-status.ps1"` (through Git Bash or cmd), that it prints nothing, and that the files appear in `.accountdeck-status`. PowerShell starting takes about 0.3 s per status refresh. Some company PCs block PowerShell scripts.
7. **Codex usage.** Assumes the same `sessions\YYYY\MM\DD\rollout-*.jsonl` layout as on the Mac.
8. **Claude Desktop usage.** Whether `plan-usage-history.json` exists in the Windows data folder at all.
9. **ChatGPT profiles.** Chrome, Brave or Edge opening a separate profile, and Edge being used when Chrome isn't installed.
10. **Recycle Bin, Start with Windows and notifications** (shown when the Dashboard is closed).

Sources for the Windows paths:
- [Where Claude Desktop stores its config on Windows](https://exchangepedia.com/2026/04/claudetools-claude-desktop-powershell-module.html)
- [anthropics/claude-code#26073](https://github.com/anthropics/claude-code/issues/26073), the MSIX virtualized config path
- [Local Data Encryption in Chromium](https://textslashplain.com/2020/09/28/local-data-encryption-in-chromium/), for `Local State` and the cookie key
