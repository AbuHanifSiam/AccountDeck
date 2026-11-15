// Builds a fake Windows profile for UI previews: node test/fake-home.js <dir>
'use strict';
const fs = require('fs'), path = require('path');
const T = process.argv[2]; const now = Math.floor(Date.now() / 1000);
const w = (p, v) => { fs.mkdirSync(path.dirname(path.join(T, p)), { recursive: true }); fs.writeFileSync(path.join(T, p), typeof v === 'string' ? v : JSON.stringify(v)); };
w('.claude.json', { oauthAccount: { emailAddress: 'nadim@example.com', accountUuid: 'U1', organizationName: 'Personal' }, mcpServers: { github: { command: 'npx', args: ['-y', '@modelcontextprotocol/server-github'], env: { GITHUB_TOKEN: 'x' } }, figma: { type: 'http', url: 'https://mcp.figma.com/mcp' } } });
w('.claude/settings.json', { model: 'opus', permissions: { allow: ['Bash(ls)', 'Read'], defaultMode: 'acceptEdits' }, env: { API_BASE: 'x' }, enabledPlugins: { 'vercel@official': true }, statusLine: { type: 'command', command: 'powershell -File "C:/Users/me/.accountdeck/claude-status.ps1"' } });
w('.claude/CLAUDE.md', '#');
for (const s of ['pdf', 'docx', 'xlsx']) w(`.claude/skills/${s}/SKILL.md`, 'x');
const chats = [['C--code-editstudio', 'C:\\code\\EditStudio', ['Add caption track export', 'Fix timeline zoom jitter', 'Refactor render queue']], ['C--code-accountdeck', 'C:\\code\\AccountDeck', ['Windows tray menu', 'Usage countdown badge']]];
for (const [d, cwd, titles] of chats) titles.forEach((t, i) => w(`.claude/projects/${d}/s${d}${i}.jsonl`, [JSON.stringify({ type: 'user', cwd, message: { content: t } }), JSON.stringify({ type: 'ai-title', aiTitle: t })].join('\n')));
w('.claude/.accountdeck-status/a.json', { session_id: 'a', rate_limits: { five_hour: { used_percentage: 42, resets_at: now + 7800 }, seven_day: { used_percentage: 18, resets_at: now + 86400 * 3 } } });
w('.accountdeck/claude/claude-work/.claude.json', { oauthAccount: { emailAddress: 'nadim@studio.example', accountUuid: 'U2' } });
w('.accountdeck/claude/claude-work/settings.json', { statusLine: { type: 'command', command: 'powershell -File "C:/Users/me/.accountdeck/claude-status.ps1"' } });
w('.accountdeck/claude/claude-work/.accountdeck-status/b.json', { session_id: 'b', rate_limits: { five_hour: { used_percentage: 88, resets_at: now + 1500 } } });
w('.accountdeck/state.json', { accounts: [
  { id: 'desktop-default', service: 'desktop', name: 'Main', isDefault: true, dir: path.join(T, '.accountdeck/desktop/desktop-default') },
  { id: 'desktop-work', service: 'desktop', name: 'Work', isDefault: false, dir: path.join(T, '.accountdeck/desktop/desktop-work') },
  { id: 'claude-default', service: 'claude', name: 'Main', isDefault: true, dir: path.join(T, '.claude') },
  { id: 'claude-work', service: 'claude', name: 'Work', isDefault: false, dir: path.join(T, '.accountdeck/claude/claude-work') },
  { id: 'codex-default', service: 'codex', name: 'Main', isDefault: true, dir: path.join(T, '.codex') },
  { id: 'chatgpt-personal', service: 'chatgpt', name: 'Personal', isDefault: false, dir: path.join(T, '.accountdeck/chatgpt/chatgpt-personal') },
], active: { desktop: 'desktop-default', claude: 'claude-work', codex: 'codex-default' } });
w('.accountdeck/desktop/desktop-work/Network/Cookies', 'x');
w('.codex/auth.json', { tokens: { id_token: 'h.' + Buffer.from(JSON.stringify({ email: 'nadim@example.com' })).toString('base64url') + '.s' } });
w('.codex/sessions/2026/11/14/rollout-2026-11-14T10-00-00-abc.jsonl', JSON.stringify({ payload: { rate_limits: { primary: { used_percent: 63, window_minutes: 300, resets_at: now + 3600 * 3 }, secondary: { used_percent: 30, window_minutes: 10080, resets_at: now + 86400 * 4 } } } }));
w('AppData/Roaming/Claude/config.json', { lastKnownAccountUuid: 'U1' });
w('AppData/Roaming/Claude/Network/Cookies', 'x');
w('AppData/Roaming/Claude/claude_desktop_config.json', { mcpServers: { filesystem: { command: 'npx', args: ['@modelcontextprotocol/server-filesystem'] } } });
w('AppData/Roaming/Claude/claude-code-sessions/U1/org/local_1.json', { title: 'Plan the launch video', cliSessionId: 'zz', lastActivityAt: Date.now() - 3600e3, cwd: 'C:\\code\\EditStudio' });
console.log(T);
