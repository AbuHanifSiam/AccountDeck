// Usage limits, read only from files on this PC.
//  • Claude Code: its status line receives the 5-hour and weekly limits as JSON on stdin; a tiny
//    PowerShell hook (claude-status.ps1) saves that JSON to <config>\.accountdeck-status\<session>.json.
//    Turned on only when you click Turn On, and never over a status line you already have.
//  • Codex: every session log records rate_limits; the newest one is read.
//  • Claude Desktop: plan-usage-history.json in its data folder, when it exists.
'use strict';
const fs = require('fs');
const path = require('path');
const P = require('./paths');
const U = require('./util');

const SCRIPT_NAME = 'claude-status.ps1';
const scriptPath = () => path.join(P.root, SCRIPT_NAME);

// Prints nothing, so the status line stays empty. Writes UTF-8 without a BOM.
const SCRIPT = `# AccountDeck: saves Claude Code's usage limits for the tray menu, per session. Prints nothing.
$ErrorActionPreference = 'SilentlyContinue'
[Console]::InputEncoding = [System.Text.Encoding]::UTF8
$in = [Console]::In.ReadToEnd()
$d = $env:CLAUDE_CONFIG_DIR
if (-not $d) { $d = Join-Path $env:USERPROFILE '.claude' }
$enc = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllText((Join-Path $d '.accountdeck-status.json'), $in, $enc)
if ($in -match '"session_id"\\s*:\\s*"([A-Za-z0-9_-]+)"') {
  $dir = Join-Path $d '.accountdeck-status'
  New-Item -ItemType Directory -Force -Path $dir | Out-Null
  [System.IO.File]::WriteAllText((Join-Path $dir ($Matches[1] + '.json')), $in, $enc)
  Get-ChildItem -Path $dir -Filter '*.json' | Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-8) } | Remove-Item -Force
}
`;
// Forward slashes work in both Git Bash (which Claude Code uses on Windows) and cmd.exe.
const hookCommand = () => `powershell -NoProfile -ExecutionPolicy Bypass -File "${scriptPath().replace(/\\/g, '/')}"`;

function windowName(minutes) {
  const m = Math.round(minutes);
  if (m === 300) return '5-hour';
  if (m === 10080) return 'Weekly';
  if (m === 43200) return 'Monthly';
  return m >= 1440 ? `${Math.round(m / 1440)}-day` : `${Math.round(m / 60)}-hour`;
}

/** The limit to show: "auto" (5-hour, or weekly when that's the only one), "5h" or "weekly". */
function viewUsage(u, pref) {
  if (!u || !u.second || pref === 'auto') return u;
  const mainFive = u.window === '5-hour', secFive = u.second.window === '5-hour';
  const swap = (pref === '5h' && !mainFive && secFive) || (pref === 'weekly' && mainFive && !secFive);
  if (!swap) return u;
  return { ...u, percent: u.second.percent, resetsAt: u.second.resetsAt, window: u.second.window,
    second: { percent: u.percent, resetsAt: u.resetsAt, window: u.window } };
}

function short(s) {
  if (s <= 60) return 'now';
  if (s < 3600) return `${Math.floor(s / 60)}m`;
  if (s < 86400) return `${Math.floor(s / 3600)}h`;
  return `${Math.floor(s / 86400)}d`;
}
function long(s) {
  const h = Math.floor(s / 3600), m = Math.floor((s % 3600) / 60);
  if (h >= 48) return `${Math.floor(h / 24)} days`;
  return h > 0 ? `${h}h ${m}m` : `${Math.max(m, 1)}m`;
}
function badgeText(u, now = Date.now()) {
  if (!u) return '';
  let t = `${Math.round(u.percent)}%`;
  if (u.resetsAt) t += ` · ${u.estimated ? '~' : ''}${short((u.resetsAt - now) / 1000)}`;
  return t;
}
function tooltip(u, now = Date.now()) {
  if (!u) return '';
  let t = `${u.window} limit: ${Math.round(u.percent)}% used`;
  if (u.resetsAt) t += `, resets in ${u.estimated ? 'about ' : ''}${long((u.resetsAt - now) / 1000)}`;
  if (u.second) {
    t += `\n${u.second.window} limit: ${Math.round(u.second.percent)}% used`;
    if (u.second.resetsAt) t += `, resets in ${long((u.second.resetsAt - now) / 1000)}`;
  }
  if (u.estimated) {
    t += "\nFrom Claude Desktop's usage history";
    if (u.asOf) t += ` (${long((now - u.asOf) / 1000)} ago)`;
    t += '. The reset time is an estimate.';
  }
  return t;
}

class UsageStore {
  constructor(model) { this.model = model; this.usage = {}; this.claudeTracking = false; this.last = 0; }

  claudeDir(a) { return a.isDefault ? P.claudeHome : a.dir; }
  codexDir(a) { return a.isDefault ? P.codexHome : a.dir; }
  get desktopSessions() { return path.join(P.desktopSupport(), 'claude-code-sessions'); }

  refresh(force = false) {
    if (!force && Date.now() - this.last < 20000) return false;
    this.last = Date.now();
    // Keep the hook script current.
    if (U.exists(scriptPath()) && U.readText(scriptPath()) !== SCRIPT) this.writeScript();
    const owners = this.desktopSessionOwners();
    const out = {}, claudeId = {};
    let tracking = true, anyClaude = false;
    for (const a of this.model.accounts) {
      try {
        if (a.service === 'claude') {
          anyClaude = true;
          if (!this.hasHook(a)) tracking = false;
          claudeId[a.id] = ((U.readJSON(this.model.claudeState(a)) || {}).oauthAccount || {}).accountUuid;
          const u = this.claudeUsage(a, owners); if (u) out[a.id] = u;
        } else if (a.service === 'desktop') {
          const uuid = this.model.desktopUuid(a); claudeId[a.id] = uuid;
          if (uuid) { const u = this.desktopUsage(uuid, owners); if (u) out[a.id] = u; }
        } else if (a.service === 'codex') {
          const u = this.codexUsage(a); if (u) out[a.id] = u;
        }
      } catch { /* one unreadable account never hides the others */ }
    }
    // A Claude Code login and a Claude Desktop login can be the same Claude account, which has
    // one set of limits. Show the freshest reading on both.
    const groups = {};
    for (const [id, uuid] of Object.entries(claudeId)) if (uuid) (groups[uuid] = groups[uuid] || []).push(id);
    for (const ids of Object.values(groups)) if (ids.length > 1) {
      const best = ids.map(i => out[i]).filter(Boolean).sort((x, y) => (y.asOf || 0) - (x.asOf || 0))[0];
      if (best) for (const i of ids) out[i] = best;
    }
    this.usage = out;
    this.claudeTracking = anyClaude && tracking;
    return true;
  }

  /** CLI session id → the Claude account (uuid) whose Desktop Code-tab chat it is. */
  desktopSessionOwners() {
    const map = {};
    for (const acc of U.ls(this.desktopSessions)) for (const org of U.ls(path.join(this.desktopSessions, acc))) {
      const dir = path.join(this.desktopSessions, acc, org);
      for (const f of U.ls(dir)) if (f.startsWith('local_') && f.endsWith('.json')) {
        const j = U.readJSON(path.join(dir, f)); if (j && j.cliSessionId) map[j.cliSessionId] = acc;
      }
    }
    return map;
  }

  statusFiles(dir) {
    const sd = path.join(dir, '.accountdeck-status');
    return U.ls(sd).filter(f => f.endsWith('.json')).map(f => ({ sid: f.slice(0, -5), path: path.join(sd, f), t: U.mtime(path.join(sd, f)) }))
      .sort((a, b) => b.t - a.t);
  }

  claudeUsage(a, owners) {
    const files = this.statusFiles(this.claudeDir(a));
    for (const f of files) if (!owners[f.sid]) { const u = this.parseClaudeStatus(f.path); if (u) return u; }
    const single = path.join(this.claudeDir(a), '.accountdeck-status.json');
    const j = files.length ? null : U.readJSON(single);
    if (!j || owners[j.session_id || '']) return null;
    return this.parseClaudeStatus(single);
  }

  desktopUsage(uuid, owners) {
    for (const f of this.statusFiles(P.claudeHome)) if (owners[f.sid] === uuid) { const u = this.parseClaudeStatus(f.path); if (u) return u; }
    return this.desktopPlanUsage(uuid);
  }

  parseClaudeStatus(p) {
    const j = U.readJSON(p); if (!j) return null;
    const rl = j.rate_limits || {};
    const win = (key, name) => {
      const w = rl[key]; if (!w || typeof w.used_percentage !== 'number') return null;
      const r = typeof w.resets_at === 'number' ? w.resets_at * 1000 : null;
      if (r && r < Date.now()) return null;     // that window has reset since
      return { percent: w.used_percentage, resetsAt: r, window: name };
    };
    const five = win('five_hour', '5-hour'), week = win('seven_day', 'Weekly');
    const asOf = U.mtime(p) || null;
    const main = five || week;
    if (!main) return { percent: 0, resetsAt: null, window: '5-hour', asOf };
    return { ...main, second: five ? week : null, asOf };
  }

  /**
   * Claude Desktop keeps a history of its plan usage (5-hour and weekly percentages) per
   * organization in plan-usage-history.json. It doesn't keep the reset time, so the 5-hour reset
   * is estimated: five hours after usage started climbing in the current window.
   */
  desktopPlanUsage(uuid) {
    const orgs = new Set(U.ls(path.join(this.desktopSessions, uuid)));
    if (!orgs.size) return null;
    const j = U.readJSON(path.join(P.desktopSupport(), 'plan-usage-history.json'));
    const all = j && Array.isArray(j.samples) ? j.samples : null; if (!all) return null;
    const samples = all.filter(s => s && orgs.has(s.org) && typeof s.t === 'number' && s.u)
      .map(s => ({ t: s.t, org: s.org, fh: Number(s.u.fh) || 0, sd: Number(s.u.sd) || 0 })).sort((a, b) => a.t - b.t);
    if (!samples.length) return null;
    const org = samples[samples.length - 1].org;
    const FIVE = 5 * 3600e3;
    let start = null, prev = null; const trusted = [];
    for (const s of samples) {
      if (s.org !== org) continue;
      if (prev && start && s.fh <= 0 && prev.fh > 0 && s.t < start + FIVE && s.sd >= prev.sd) continue;   // a false zero
      if (s.fh <= 0) start = null;
      else if (start == null || s.t >= start + FIVE || (prev && s.fh < prev.fh)) start = s.t;
      prev = s; trusted.push(s);
    }
    const last = trusted[trusted.length - 1];
    if (!last || Date.now() - last.t > 7 * 86400e3) return null;
    const weekly = this.weeklyReset(all, org);
    if (last.fh > 0 && start && start + FIVE > Date.now()) {
      return { percent: last.fh, resetsAt: start + FIVE, window: '5-hour', second: { percent: last.sd, resetsAt: weekly, window: 'Weekly' }, estimated: true, asOf: last.t };
    }
    return { percent: last.sd, resetsAt: weekly, window: 'Weekly', second: { percent: 0, resetsAt: null, window: '5-hour' }, estimated: true, asOf: last.t };
  }

  weeklyReset(raw, org) {
    const WEEK = 7 * 86400;
    let prev = null; const ranges = [];
    for (const s of raw) {
      if (!s || s.org !== org || typeof s.t !== 'number' || !s.u || typeof s.u.sd !== 'number') continue;
      const ts = s.t / 1000, sd = s.u.sd;
      if (prev && sd <= 10 && prev[1] - sd >= 3 && ts - prev[0] < 2 * 86400) ranges.push([prev[0], ts]);
      prev = [ts, sd];
    }
    if (!ranges.length) return null;
    const latest = ranges[ranges.length - 1];
    let lo = latest[0], hi = latest[1];
    for (const r of ranges.slice(0, -1)) {
      const k = Math.round((latest[0] - r[0]) / WEEK);
      const a = r[0] + k * WEEK, b = r[1] + k * WEEK;
      if (Math.max(lo, a) < Math.min(hi, b)) { lo = Math.max(lo, a); hi = Math.min(hi, b); }
    }
    let reset = (lo + hi) / 2; const now = Date.now() / 1000;
    while (reset <= now) reset += WEEK;
    return reset * 1000;
  }

  // ---- Codex ----
  codexUsage(a) {
    const root = path.join(this.codexDir(a), 'sessions');
    const files = [];
    const walk = (d, depth) => {
      if (depth > 5 || files.length > 4000) return;
      for (const f of U.ls(d)) { const p = path.join(d, f); if (f.endsWith('.jsonl')) files.push(p); else if (U.isDir(p)) walk(p, depth + 1); }
    };
    walk(root, 0);
    // Session files are named rollout-<date>T<time>-<id>.jsonl, so the name sorts by time.
    files.sort((x, y) => (path.basename(y) > path.basename(x) ? 1 : -1));
    for (const f of files.slice(0, 6)) { const u = this.codexRateLimits(f); if (u) return u; }
    return null;
  }
  codexRateLimits(p) {
    const text = U.readTail(p, 600000);
    const lines = text.split('\n').reverse();
    for (const line of lines) {
      if (!line.includes('"rate_limits"')) continue;
      let obj; try { obj = JSON.parse(line); } catch { continue; }
      const rl = find('rate_limits', obj); if (!rl || typeof rl !== 'object') continue;
      const win = key => {
        const w = rl[key]; if (!w || typeof w.used_percent !== 'number') return null;
        let r = typeof w.resets_at === 'number' ? w.resets_at * 1000 : null;
        if (!r && typeof w.resets_in_seconds === 'number') r = Date.now() + w.resets_in_seconds * 1000;
        const name = windowName(typeof w.window_minutes === 'number' ? w.window_minutes : 300);
        if (r && r < Date.now()) return { percent: 0, resetsAt: null, window: name };
        return { percent: w.used_percent, resetsAt: r, window: name };
      };
      const main = win('primary'); if (!main) continue;
      return { ...main, second: win('secondary'), asOf: U.mtime(p) || null };
    }
    return null;
  }

  // ---- the status line hook ----
  hasHook(a) {
    const t = U.readText(path.join(this.claudeDir(a), 'settings.json'));
    return !!t && t.includes(SCRIPT_NAME);
  }
  writeScript() {
    U.mkdirp(P.root);
    fs.writeFileSync(scriptPath(), SCRIPT, 'utf8');
  }
  /**
   * Adds the status line hook to every Claude Code account that has no status line yet.
   * Returns the names of accounts skipped because they already have their own (or an unreadable settings file).
   */
  enableClaudeTracking() {
    this.writeScript();
    const skipped = [];
    for (const a of this.model.accounts) {
      if (a.service !== 'claude' || this.hasHook(a)) continue;
      const dir = this.claudeDir(a), p = path.join(dir, 'settings.json');
      U.mkdirp(dir);
      let json = {};
      if (U.exists(p)) {
        const j = U.readJSON(p); if (!j) { skipped.push(a.name); continue; }
        json = j;
        if (json.statusLine != null) { skipped.push(a.name); continue; }
        if (!U.exists(p + '.accountdeck-backup')) fs.copyFileSync(p, p + '.accountdeck-backup');
      }
      json.statusLine = { type: 'command', command: hookCommand() };
      U.writeJSON(json, p);
    }
    this.refresh(true);
    return skipped;
  }
}

function find(key, obj) {
  if (Array.isArray(obj)) { for (const v of obj) { const f = find(key, v); if (f != null) return f; } return null; }
  if (obj && typeof obj === 'object') {
    if (obj[key] != null) return obj[key];
    for (const v of Object.values(obj)) { const f = find(key, v); if (f != null) return f; }
  }
  return null;
}

module.exports = { UsageStore, viewUsage, badgeText, tooltip, short, long, SCRIPT, hookCommand, windowName };
