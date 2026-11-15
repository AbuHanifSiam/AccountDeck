// The window talks to the app only through these calls.
'use strict';
const { contextBridge, ipcRenderer } = require('electron');
const call = (name, ...args) => ipcRenderer.invoke(name, ...args).then(r => { if (!r.ok) throw new Error(r.error); return r.value; });
const names = ['state', 'refresh', 'select', 'desktopConfirmText', 'add', 'signIn', 'rename', 'remove', 'reveal', 'openTerminal', 'saveSettings',
  'setLaunchAtLogin', 'enableTracking', 'stats', 'environment', 'chats', 'copyChats', 'resumeChat', 'mcp', 'mcpSend', 'envCopy', 'openCredit'];
const api = {};
for (const n of names) api[n] = (...a) => call(n, ...a);
api.on = (channel, fn) => { if (['state', 'toast', 'navigate'].includes(channel)) ipcRenderer.on(channel, (_e, v) => fn(v)); };
contextBridge.exposeInMainWorld('deck', api);
