// Small file helpers. Everything stays on this PC.
'use strict';
const fs = require('fs');
const path = require('path');

function exists(p) { try { fs.accessSync(p); return true; } catch { return false; } }
function isDir(p) { try { return fs.statSync(p).isDirectory(); } catch { return false; } }
function mtime(p) { try { return fs.statSync(p).mtimeMs; } catch { return 0; } }
function size(p) { try { return fs.statSync(p).size; } catch { return 0; } }
function ls(p) { try { return fs.readdirSync(p); } catch { return []; } }
function mkdirp(p) { fs.mkdirSync(p, { recursive: true }); }

function readJSON(p) {
  try {
    let t = fs.readFileSync(p, 'utf8');
    if (t.charCodeAt(0) === 0xfeff) t = t.slice(1);      // files saved by Notepad/PowerShell may have a BOM
    const v = JSON.parse(t);
    return v && typeof v === 'object' && !Array.isArray(v) ? v : null;
  } catch { return null; }
}
function readText(p) { try { return fs.readFileSync(p, 'utf8'); } catch { return null; } }

function stamp(d = new Date()) {
  const z = n => String(n).padStart(2, '0');
  return `${d.getFullYear()}${z(d.getMonth() + 1)}${z(d.getDate())}-${z(d.getHours())}${z(d.getMinutes())}${z(d.getSeconds())}`;
}

/** Writes JSON after keeping a dated copy of the old file next to it. */
function writeJSONWithBackup(obj, p) {
  if (exists(p)) { try { fs.copyFileSync(p, `${p}.accountdeck-${stamp()}`); } catch {} }
  writeJSON(obj, p);
}
/** Writes JSON atomically (temp file, then rename). Keys sorted like the Mac app. */
function writeJSON(obj, p, { sort = true } = {}) {
  mkdirp(path.dirname(p));
  const tmp = `${p}.accountdeck-tmp`;
  fs.writeFileSync(tmp, JSON.stringify(sort ? sortKeys(obj) : obj, null, 2), 'utf8');
  fs.renameSync(tmp, p);
}
function sortKeys(v) {
  if (Array.isArray(v)) return v.map(sortKeys);
  if (v && typeof v === 'object') { const o = {}; for (const k of Object.keys(v).sort()) o[k] = sortKeys(v[k]); return o; }
  return v;
}

function readHead(p, bytes) {
  let fd; try { fd = fs.openSync(p, 'r'); const b = Buffer.alloc(bytes); const n = fs.readSync(fd, b, 0, bytes, 0); return b.subarray(0, n).toString('utf8'); }
  catch { return ''; } finally { if (fd !== undefined) try { fs.closeSync(fd); } catch {} }
}
function readTail(p, bytes) {
  let fd; try { fd = fs.openSync(p, 'r'); const s = fs.fstatSync(fd).size; const start = Math.max(0, s - bytes); const len = s - start;
    const b = Buffer.alloc(len); fs.readSync(fd, b, 0, len, start); return b.toString('utf8'); }
  catch { return ''; } finally { if (fd !== undefined) try { fs.closeSync(fd); } catch {} }
}

/** Recursive copy that never overwrites existing files. */
function copyNoOverwrite(src, dst) {
  if (exists(dst)) return false;
  fs.cpSync(src, dst, { recursive: true, errorOnExist: true, force: false });
  return true;
}

/** Email from a JWT's payload. Only the email claim is kept; the token itself is never stored or shown. */
function jwtEmail(jwt) {
  try {
    const part = String(jwt).split('.')[1]; if (!part) return null;
    const obj = JSON.parse(Buffer.from(part.replace(/-/g, '+').replace(/_/g, '/'), 'base64').toString('utf8'));
    return typeof obj.email === 'string' ? obj.email : null;
  } catch { return null; }
}

module.exports = { exists, isDir, mtime, size, ls, mkdirp, readJSON, readText, writeJSON, writeJSONWithBackup, stamp,
  readHead, readTail, copyNoOverwrite, jwtEmail };
