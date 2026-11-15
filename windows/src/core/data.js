// Dashboard data: chats, MCP connections, environment cards and copying between accounts.
// Read from files on this PC only. Copies merge and never overwrite; changed files are backed up first.
'use strict';
const fs = require('fs');
const path = require('path');
const P = require('./paths');
const U = require('./util');

const clean = s => { const one = String(s).replace(/\s+/g, ' ').trim(); return one.length > 90 ? one.slice(0, 90) + '…' : one; };

// ---------------------------------------------------------------- chats
/** Titles Claude Desktop keeps for the Code-tab chats it ran: CLI session id → title. */
function desktopTitles() {
  const root = path.join(P.desktopSupport(), 'claude-code-sessions');
  const out = {};
  for (const acc of U.ls(root)) for (const org of U.ls(path.join(root, acc))) {
    const dir = path.join(root, acc, org);
    for (const f of U.ls(dir)) if (f.startsWith('local_')) {
      const j = U.readJSON(path.join(dir, f)); if (j && j.cliSessionId && j.title) out[j.cliSessionId] = j.title;
    }
  }
  return out;
}

/** Claude Code chats: <config>\projects\<project>\<session>.jsonl, newest first. */
function codeChats(projects, limit = 400) {
  const files = [];
  for (const d of U.ls(projects)) {
    const dir = path.join(projects, d);
    for (const f of U.ls(dir)) if (f.endsWith('.jsonl')) {
      const p = path.join(dir, f); let st; try { st = fs.statSync(p); } catch { continue; }
      files.push({ p, t: st.mtimeMs, size: st.size, project: d });
    }
  }
  files.sort((a, b) => b.t - a.t);
  const known = desktopTitles();
  const out = [];
  files.slice(0, limit).forEach((f, index) => {
    if (!f.size) return;
    let custom = null, ai = null, first = null, cwd = null;
    const scan = text => {
      for (const line of text.split('\n')) {
        const isTitle = line.startsWith('{"type":"custom-title"') || line.startsWith('{"type":"ai-title"')
          || (line.length < 2000 && (line.includes('"custom-title"') || line.includes('"ai-title"')));
        const needUser = first == null || cwd == null;
        const isUser = needUser && line.includes('"type":"user"');
        if (!(isTitle || isUser || (cwd == null && line.includes('"cwd"')))) continue;
        let o; try { o = JSON.parse(line); } catch { continue; }
        if (!o || typeof o !== 'object') continue;
        if (cwd == null && typeof o.cwd === 'string') cwd = o.cwd;
        if (typeof o.customTitle === 'string') custom = o.customTitle;
        if (typeof o.aiTitle === 'string') ai = o.aiTitle;
        if (first == null && isUser && o.message) {
          let t = null; const c = o.message.content;
          if (typeof c === 'string') t = c;
          else if (Array.isArray(c)) { const x = c.find(e => e && e.type === 'text'); if (x) t = x.text; }
          t = t && String(t).trim();
          if (t && !t.startsWith('<') && !t.startsWith('Caveat:')) first = t;
        }
      }
    };
    scan(U.readHead(f.p, 96000));
    scan(U.readTail(f.p, 24000));
    const sid = path.basename(f.p, '.jsonl');
    if (!custom && !ai && known[sid]) custom = known[sid];
    if (!custom && !ai && index < 60) scan(U.readTail(f.p, 400000));
    out.push({ id: f.p, sid, title: clean(custom || ai || first || 'Untitled chat'), folder: cwd || '', date: f.t, size: f.size, kind: 'code' });
  });
  return out;
}

/** Claude Desktop Code-tab chats for one signed-in account. */
function desktopChats(accountUuid) {
  const accDir = path.join(P.desktopSupport(), 'claude-code-sessions', accountUuid);
  const out = [];
  for (const org of U.ls(accDir)) {
    const dir = path.join(accDir, org);
    for (const f of U.ls(dir)) if (f.startsWith('local_') && f.endsWith('.json')) {
      const p = path.join(dir, f); const j = U.readJSON(p);
      if (!j || j.isArchived === true) continue;
      const ms = Number(j.lastActivityAt) || Number(j.createdAt) || 0;
      out.push({ id: p, sid: j.cliSessionId || '', title: clean(j.title || 'Untitled chat'), folder: j.cwd || '', date: ms, size: U.size(p), kind: 'desktop' });
    }
  }
  return out.sort((a, b) => b.date - a.date);
}

function group(chats) {
  const m = new Map();
  for (const c of chats) { if (!m.has(c.folder)) m.set(c.folder, []); m.get(c.folder).push(c); }
  return [...m.entries()].map(([folder, list]) => ({
    path: folder, name: folder ? folder.split(/[\\/]/).filter(Boolean).pop() || folder : 'No folder',
    chats: list.sort((a, b) => b.date - a.date), newest: Math.max(...list.map(c => c.date)),
  })).sort((a, b) => b.newest - a.newest);
}

/**
 * Copies Claude Code chats into another account's projects folder, keeping each one's project
 * folder name so `claude --resume` finds it there. Existing chats are never overwritten.
 */
function copyCode(ids, from, to) {
  let copied = 0, skipped = 0;
  const base = path.resolve(from) + path.sep;
  for (const id of ids) {
    const src = path.resolve(id);
    if (!src.startsWith(base) || !src.endsWith('.jsonl') || !U.exists(src)) { skipped++; continue; }
    const rel = src.slice(base.length), dest = path.join(to, rel);
    if (U.exists(dest)) { skipped++; continue; }
    try { U.mkdirp(path.dirname(dest)); fs.copyFileSync(src, dest, fs.constants.COPYFILE_EXCL); } catch { skipped++; continue; }
    // The chat's side folder (subagents, saved tool output), when it has one.
    const side = src.slice(0, -6), sideDest = dest.slice(0, -6);
    if (U.isDir(side) && !U.exists(sideDest)) { try { U.copyNoOverwrite(side, sideDest); } catch {} }
    copied++;
  }
  return { copied, skipped };
}

/** Copies Claude Desktop Code-tab chats into another account's chat list. */
function copyDesktop(ids, toUuid) {
  const sessions = path.join(P.desktopSupport(), 'claude-code-sessions');
  const base = path.resolve(sessions) + path.sep;
  const toDir = path.join(sessions, toUuid);
  const newest = org => Math.max(0, ...U.ls(path.join(toDir, org)).map(f => U.mtime(path.join(toDir, org, f))));
  const orgs = U.ls(toDir).filter(o => U.isDir(path.join(toDir, o))).sort((a, b) => newest(b) - newest(a));
  if (!orgs.length) return null;
  let copied = 0, skipped = 0;
  for (const id of ids) {
    const src = path.resolve(id);
    if (!src.startsWith(base) || !U.exists(src)) { skipped++; continue; }
    const dest = path.join(toDir, orgs[0], path.basename(src));
    if (U.exists(dest)) { skipped++; continue; }
    try { fs.copyFileSync(src, dest, fs.constants.COPYFILE_EXCL); copied++; } catch { skipped++; }
  }
  return { copied, skipped };
}

// ---------------------------------------------------------------- MCP
const desktopConfig = () => path.join(P.desktopSupport(), 'claude_desktop_config.json');

function mcpKind(c) { if (typeof c.type === 'string') return c.type === 'stdio' ? 'Local' : c.type.toUpperCase(); return c.url ? 'HTTP' : 'Local'; }
function mcpSummary(c) {
  if (typeof c.url === 'string') { try { return new URL(c.url).host; } catch { return c.url; } }
  const base = s => String(s).split(/[\\/]/).pop();
  const cmd = typeof c.command === 'string' ? base(c.command) : '';
  const arg = Array.isArray(c.args) ? (c.args.find(a => typeof a === 'string' && !a.startsWith('-')) || '') : '';
  return [cmd, arg && base(arg)].filter(Boolean).join(' ');
}

/** Every MCP connection a Claude Code account has: its own, its projects', and (shared on this PC) Claude Desktop's. */
function mcpEntries(statePath, includeCode) {
  const out = [];
  const add = (name, scope, project, config) => {
    const cfg = config && typeof config === 'object' ? config : {};
    out.push({ id: `${scope === 'project' ? 'project:' + project : scope}/${name}`, name, scope, project: project || null,
      kind: mcpKind(cfg), summary: mcpSummary(cfg), envNames: Object.keys(cfg.env || {}) });
  };
  const byName = o => Object.keys(o || {}).sort((a, b) => a.toLowerCase().localeCompare(b.toLowerCase()));
  if (includeCode && statePath) {
    const st = U.readJSON(statePath) || {};
    for (const k of byName(st.mcpServers)) add(k, 'user', null, st.mcpServers[k]);
    for (const p of Object.keys(st.projects || {}).sort()) {
      const servers = (st.projects[p] || {}).mcpServers || {};
      for (const k of byName(servers)) add(k, 'project', p, servers[k]);
    }
  }
  const d = U.readJSON(desktopConfig()) || {};
  for (const k of byName(d.mcpServers)) add(k, 'desktop', null, d.mcpServers[k]);
  return out;
}

/** The raw config of one entry (kept in the main process; never sent to the window). */
function mcpConfig(statePath, entryId) {
  const [scopePart, ...rest] = entryId.split('/'); const name = rest.join('/');
  if (scopePart === 'desktop') return { scope: 'desktop', name, config: ((U.readJSON(desktopConfig()) || {}).mcpServers || {})[name] };
  const st = U.readJSON(statePath) || {};
  if (scopePart === 'user') return { scope: 'user', name, config: (st.mcpServers || {})[name] };
  if (scopePart.startsWith('project:')) {
    // Project paths can contain "/" on other systems; re-split on the last "/".
    const i = entryId.lastIndexOf('/'); const project = entryId.slice('project:'.length, i); const nm = entryId.slice(i + 1);
    return { scope: 'project', project, name: nm, config: (((st.projects || {})[project] || {}).mcpServers || {})[nm] };
  }
  return null;
}

/** Adds the connections to another Claude Code account. Ones it already has by that name are left alone. */
function mcpSend(fromState, entryIds, toState) {
  const st = U.readJSON(toState) || {};
  const user = st.mcpServers && typeof st.mcpServers === 'object' ? st.mcpServers : {};
  const projects = st.projects && typeof st.projects === 'object' ? st.projects : {};
  let added = 0, skipped = 0;
  for (const id of entryIds) {
    const e = mcpConfig(fromState, id);
    if (!e || !e.config) { skipped++; continue; }
    if (e.scope === 'project') {
      const proj = projects[e.project] || {}; const servers = proj.mcpServers || {};
      if (servers[e.name] != null) { skipped++; continue; }
      servers[e.name] = e.config; proj.mcpServers = servers; projects[e.project] = proj; added++;
    } else {
      if (user[e.name] != null) { skipped++; continue; }
      user[e.name] = e.config; added++;
    }
  }
  if (added > 0) {
    st.mcpServers = user;
    if (Object.keys(projects).length) st.projects = projects;
    U.writeJSONWithBackup(st, toState);
  }
  return { added, skipped };
}

// ---------------------------------------------------------------- environment
const PARTS = ['model', 'permissions', 'mcp', 'plugins', 'skills', 'hooks', 'memory', 'env'];
const PART_TITLES = { model: 'Model', permissions: 'Permissions', mcp: 'MCP servers', plugins: 'Plugins', skills: 'Skills', hooks: 'Hooks', memory: 'Memory', env: 'Environment' };

function environment(a, model) {
  const out = [];
  const count = (n, one) => (n === 0 ? 'None' : `${n} ${one}${n === 1 ? '' : 's'}`);
  const names = list => (list.length ? list.slice().sort().slice(0, 6).join(', ') + (list.length > 6 ? '…' : '') : null);
  const fact = (icon, title, value, detail = null, part = null) => out.push({ icon, title, value, detail, part });
  if (a.service === 'claude') {
    const dir = model.configDir(a);
    const state = U.readJSON(model.claudeState(a)) || {};
    const oauth = state.oauthAccount || {};
    const settings = U.readJSON(path.join(dir, 'settings.json')) || {};
    const perms = settings.permissions || {};
    const mcp = Object.keys(state.mcpServers || {});
    const plugins = Object.entries(settings.enabledPlugins || {}).filter(([, v]) => v === true).map(([k]) => k.split('@')[0]);
    const skills = U.ls(path.join(dir, 'skills')).filter(f => !f.startsWith('.'));
    const hooks = Object.keys(settings.hooks || {});
    const env = Object.keys(settings.env || {});                 // names only, never values
    const status = settings.statusLine;
    const statusText = !status ? 'Off' : String(status.command || '').includes('claude-status.ps1') ? 'AccountDeck limits' : 'Your own';
    fact('user', 'Signed in', oauth.emailAddress || 'Not signed in', oauth.organizationName || null);
    fact('folder', 'Config folder', P.short(dir), a.isDefault ? 'Default (CLAUDE_CONFIG_DIR unset)' : 'CLAUDE_CONFIG_DIR');
    fact('cpu', 'Model', settings.model || 'Default', null, 'model');
    fact('shield', 'Permissions', perms.defaultMode || 'Ask each time', count((perms.allow || []).length, 'allow rule'), 'permissions');
    fact('plug', 'MCP servers', count(mcp.length, 'server'), names(mcp), 'mcp');
    fact('puzzle', 'Plugins', count(plugins.length, 'plugin'), names(plugins), 'plugins');
    fact('sparkle', 'Skills', count(skills.length, 'skill'), names(skills), 'skills');
    fact('bolt', 'Hooks', count(hooks.length, 'event'), names(hooks), 'hooks');
    fact('book', 'Memory', U.exists(path.join(dir, 'CLAUDE.md')) ? 'CLAUDE.md' : 'No CLAUDE.md', null, 'memory');
    fact('terminal', 'Environment', count(env.length, 'variable'), names(env), 'env');
    fact('gauge', 'Status line', statusText);
  } else if (a.service === 'codex') {
    const dir = model.configDir(a);
    const toml = U.readText(path.join(dir, 'config.toml')) || '';
    const lines = toml.split(/\r?\n/);
    const m = lines.find(l => /^model\s*=/.test(l));
    const mdl = m ? m.split('=').slice(1).join('=').trim().replace(/^"|"$/g, '') : null;
    const mcp = [...new Set(lines.filter(l => l.startsWith('[mcp_servers.')).map(l => l.slice(13).replace(/\]\s*$/, '').split('.')[0].replace(/^"|"$/g, '')))];
    let sessions = 0;
    const walk = (d, depth) => { if (depth > 5) return; for (const f of U.ls(d)) { const p = path.join(d, f); if (f.endsWith('.jsonl')) sessions++; else if (U.isDir(p)) walk(p, depth + 1); } };
    walk(path.join(dir, 'sessions'), 0);
    fact('user', 'Signed in', model.details[a.id] || 'Not signed in');
    fact('folder', 'Config folder', P.short(dir), a.isDefault ? 'Default (CODEX_HOME unset)' : 'CODEX_HOME');
    fact('cpu', 'Model', mdl || 'Default');
    fact('plug', 'MCP servers', count(mcp.length, 'server'), names(mcp));
    fact('chat', 'Sessions', count(sessions, 'session'), 'Saved in sessions\\');
  } else if (a.service === 'desktop') {
    const saved = model.isActive(a) || model.desktopSlotHasLogin(a);
    const cfg = U.readJSON(desktopConfig()) || {};
    const mcp = Object.keys(cfg.mcpServers || {});
    fact('user', 'Login', model.isActive(a) ? 'Open in Claude now' : (saved ? 'Saved, ready to switch' : 'Sign in after switching'));
    fact('folder', 'Saved login folder', P.short(a.dir), 'Cookies and app settings only');
    fact('folder', 'Claude data folder', P.short(P.desktopSupport()), P.desktopInstallKind() === 'msix' ? 'Microsoft Store install' : 'Direct install');
    fact('plug', 'MCP servers', count(mcp.length, 'server'), names(mcp) ? `Shared by all accounts: ${names(mcp)}` : null);
    fact('chat', 'Bring last chat', model.settings.carryChat ? 'On' : 'Off', 'When you switch accounts');
  } else if (a.service === 'chatgpt') {
    fact('globe', 'Browser profile', P.short(a.dir), 'Its own cookies and history');
    fact('clock', 'Status', model.details[a.id] || '');
  }
  return out;
}

/**
 * Copies parts of one Claude Code account's setup into another. Merges, never removes: what the
 * destination already has stays (the model is the one exception: it is replaced). Each changed
 * file is backed up first. Logins are never touched.
 */
function envCopy(parts, fromDir, toDir, fromState, toState) {
  const report = [];
  const src = U.readJSON(path.join(fromDir, 'settings.json')) || {};
  const dst = U.readJSON(path.join(toDir, 'settings.json')) || {};
  let changed = false;
  const mergeKeys = (d, s) => { const o = d && typeof d === 'object' ? { ...d } : {}; let n = 0; for (const [k, v] of Object.entries(s || {})) if (o[k] === undefined) { o[k] = v; n++; } return [o, n]; };
  const plural = (n, w) => `${n} ${w}${n === 1 ? '' : 's'}`;
  for (const part of PARTS) {
    if (!parts.includes(part)) continue;
    if (part === 'model') {
      if (src.model != null) { dst.model = src.model; changed = true; report.push('model'); } else report.push('no model to send');
    } else if (part === 'permissions') {
      const p = { ...(dst.permissions || {}) }, sp = src.permissions || {}; let added = 0;
      for (const key of ['allow', 'deny', 'ask', 'additionalDirectories']) {
        const have = Array.isArray(p[key]) ? p[key] : [];
        const more = (Array.isArray(sp[key]) ? sp[key] : []).filter(x => !have.includes(x));
        if (more.length) { p[key] = have.concat(more); added += more.length; }
      }
      if (p.defaultMode == null && sp.defaultMode != null) { p.defaultMode = sp.defaultMode; added++; }
      if (added) { dst.permissions = p; changed = true; }
      report.push(plural(added, 'permission rule'));
    } else if (part === 'plugins') {
      const [ep, n] = mergeKeys(dst.enabledPlugins, src.enabledPlugins);
      const [mk, n2] = mergeKeys(dst.extraKnownMarketplaces, src.extraKnownMarketplaces);
      if (n) dst.enabledPlugins = ep; if (n2) dst.extraKnownMarketplaces = mk;
      if (n || n2) changed = true;
      report.push(plural(n, 'plugin'));
    } else if (part === 'hooks') {
      const h = { ...(dst.hooks || {}) }; let added = 0;
      for (const [event, list] of Object.entries(src.hooks || {})) {
        const have = Array.isArray(h[event]) ? h[event].slice() : [];
        const seen = new Set(have.map(x => JSON.stringify(sortDeep(x))));
        for (const entry of Array.isArray(list) ? list : []) if (!seen.has(JSON.stringify(sortDeep(entry)))) { have.push(entry); added++; }
        h[event] = have;
      }
      if (added) { dst.hooks = h; changed = true; }
      report.push(plural(added, 'hook'));
    } else if (part === 'env') {
      const [e, n] = mergeKeys(dst.env, src.env);
      if (n) { dst.env = e; changed = true; }
      report.push(plural(n, 'variable'));
    } else if (part === 'mcp') {
      const state = U.readJSON(toState) || {};
      const [m, n] = mergeKeys(state.mcpServers, (U.readJSON(fromState) || {}).mcpServers);
      if (n) { state.mcpServers = m; U.writeJSONWithBackup(state, toState); }
      report.push(plural(n, 'MCP server'));
    } else if (part === 'skills') {
      const from = path.join(fromDir, 'skills'), to = path.join(toDir, 'skills'); let n = 0;
      for (const name of U.ls(from)) if (!name.startsWith('.')) { try { U.mkdirp(to); if (U.copyNoOverwrite(path.join(from, name), path.join(to, name))) n++; } catch {} }
      report.push(plural(n, 'skill'));
    } else if (part === 'memory') {
      const s = path.join(fromDir, 'CLAUDE.md'), d = path.join(toDir, 'CLAUDE.md');
      if (!U.exists(s)) report.push('no CLAUDE.md to send');
      else if (U.exists(d)) report.push('CLAUDE.md kept (it has its own)');
      else { U.mkdirp(toDir); fs.copyFileSync(s, d, fs.constants.COPYFILE_EXCL); report.push('CLAUDE.md'); }
    }
  }
  if (changed) U.writeJSONWithBackup(dst, path.join(toDir, 'settings.json'));
  return report;
}
function sortDeep(v) {
  if (Array.isArray(v)) return v.map(sortDeep);
  if (v && typeof v === 'object') { const o = {}; for (const k of Object.keys(v).sort()) o[k] = sortDeep(v[k]); return o; }
  return v;
}

// ---------------------------------------------------------------- stats
function stats(model) {
  let chats = 0, skills = 0; const mcp = new Set();
  const claude = model.accounts.filter(a => a.service === 'claude');
  for (const a of claude) {
    const dir = model.configDir(a);
    for (const d of U.ls(path.join(dir, 'projects'))) chats += U.ls(path.join(dir, 'projects', d)).filter(f => f.endsWith('.jsonl')).length;
    skills += U.ls(path.join(dir, 'skills')).filter(f => !f.startsWith('.')).length;
    for (const e of mcpEntries(model.claudeState(a), true)) mcp.add(e.id);
  }
  if (!claude.length) for (const e of mcpEntries(null, false)) mcp.add(e.id);
  return { chats, mcp: mcp.size, skills };
}

module.exports = { codeChats, desktopChats, group, copyCode, copyDesktop, mcpEntries, mcpSend, environment, envCopy, stats, PARTS, PART_TITLES };
