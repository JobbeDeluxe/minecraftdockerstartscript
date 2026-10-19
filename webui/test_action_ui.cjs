const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const { test } = require('node:test');

const source = fs.readFileSync(path.join(__dirname, 'static/app.js'), 'utf8');
function extract(start, end) {
  const offset = source.indexOf(start);
  assert.ok(offset >= 0);
  const limit = source.indexOf(end, offset);
  assert.ok(limit > offset);
  return source.slice(offset, limit);
}

function actionContext(outcome, refreshError) {
  const statuses = [], refreshes = [], output = [];
  const context = vm.createContext({
    selected: 'test', configDirty: false,
    liveActionLogActions: new Set(), actionLabel: value => value,
    t: (key, values = {}) => `${key} ${values.message || ''}`.trim(),
    setActionStatus: (message, type) => statuses.push({ message, type }),
    setRefreshStatus: message => refreshes.push(message),
    showOutput: message => output.push(message),
    api: async () => { if (outcome instanceof Error) throw outcome; return outcome; },
    loadServers: async () => { if (refreshError) throw refreshError; },
    translateWarning: value => value, clearInterval: () => {},
  });
  vm.runInContext(extract('async function runProfileAction(', 'document.querySelectorAll("[data-action]")'), context);
  return { context, statuses, refreshes, output };
}

test('successful start stays successful when subsequent refresh returns 404', async () => {
  const state = actionContext({ ok: true, code: 0, stdout: 'started', stderr: '' }, new Error('not found'));
  await state.context.runProfileAction('start');
  assert.equal(state.statuses.at(-1).type, 'success');
  assert.ok(state.output.at(-1).includes('started'));
  assert.ok(state.refreshes.at(-1).includes('not found'));
  assert.ok(!state.statuses.some(item => item.type === 'error'));
});

test('actual boot failure is preserved even if refresh also fails', async () => {
  const state = actionContext({ ok: false, code: 1, stdout: '', stderr: 'boot failed' }, new Error('not found'));
  await state.context.runProfileAction('start');
  assert.equal(state.statuses.at(-1).type, 'error');
  assert.equal(state.statuses.at(-1).message, 'boot failed');
  assert.ok(state.output.at(-1).includes('boot failed'));
});

test('action request failure is still shown as an action error', async () => {
  const state = actionContext(new Error('action unavailable'));
  await state.context.runProfileAction('start');
  assert.equal(state.statuses.at(-1).type, 'error');
  assert.equal(state.statuses.at(-1).message, 'action unavailable');
});

test('missing boot-log endpoint is explained locally without rejecting refresh', async () => {
  const elements = { bootState: { textContent: '' }, bootLog: { textContent: 'stale' } };
  const context = vm.createContext({
    selected: 'test', $: id => elements[id], t: key => key,
    api: async () => { throw Object.assign(new Error('not found'), { status: 404 }); },
  });
  vm.runInContext(extract('async function loadBootLog() {', 'async function loadLogs()'), context);
  await context.loadBootLog();
  assert.equal(elements.bootState.textContent, 'boot.unavailable');
  assert.equal(elements.bootLog.textContent, '');
});

test('API errors preserve HTTP status and requested path for diagnosis', async () => {
  const context = vm.createContext({
    fetch: async () => ({ ok: false, status: 404, json: async () => ({ error: 'not found' }) }),
    t: key => key,
  });
  vm.runInContext(extract('async function api(path, opt = {}) {', 'function setSelectorText('), context);
  await assert.rejects(context.api('/api/servers/test/boot-log'), error =>
    error.status === 404 && error.path === '/api/servers/test/boot-log');
});

test('status refresh updates sidebar and overview without changing profile or editors', async () => {
  const renders = [];
  const context = vm.createContext({
    servers: [{ id: 'test', name: 'preserved', status: { state: 'missing' }, players: { online: 2 } }],
    serverSnapshotRequest: null,
    api: async () => [{ id: 'test', name: 'other name', disabled: false, status: { state: 'running', running: true } }],
    renderServers: () => renders.push('sidebar'), renderOverview: () => renders.push('overview'),
    updateProfileToggle: () => {}, renderEditor: () => { throw new Error('must not redraw editor'); },
  });
  vm.runInContext(extract('function fetchServerSnapshot() {', 'function startServerStatusPolling()'), context);
  await context.refreshServerStatuses();
  assert.equal(context.servers[0].status.state, 'running');
  assert.equal(context.servers[0].name, 'preserved');
  assert.equal(context.servers[0].players.online, 2);
  assert.deepEqual(renders, ['sidebar', 'overview']);
});

test('overlapping status requests share one snapshot and can fetch again afterwards', async () => {
  let resolve, calls = 0;
  const context = vm.createContext({
    serverSnapshotRequest: null,
    api: () => { calls++; return new Promise(done => { resolve = done; }); },
  });
  vm.runInContext(extract('function fetchServerSnapshot() {', 'async function refreshServerStatuses()'), context);
  const first = context.fetchServerSnapshot();
  const second = context.fetchServerSnapshot();
  assert.equal(first, second);
  assert.equal(calls, 1);
  resolve([]);
  await first;
  const third = context.fetchServerSnapshot();
  assert.equal(calls, 2);
  resolve([]);
  await third;
});

test('polling retries after a failed request instead of leaving a stale status forever', async () => {
  const timers = [];
  let calls = 0;
  const context = vm.createContext({
    serverStatusTimer: null,
    document: { hidden: false, addEventListener: () => {} },
    refreshServerStatuses: async () => { calls++; if (calls === 1) throw new Error('offline'); },
    setTimeout: (callback, delay) => { assert.equal(delay, 5000); timers.push(callback); return timers.length; },
  });
  vm.runInContext(extract('function startServerStatusPolling() {', 'async function loadServers()'), context);
  context.startServerStatusPolling();
  context.startServerStatusPolling();
  assert.equal(timers.length, 1);
  await timers[0]();
  await timers[1]();
  assert.equal(calls, 2);
  assert.equal(timers.length, 3);
});

test('plugin restart uses shared action workflow and retains original target after selection changes', async () => {
  const restarts = [];
  let refreshes = 0;
  const context = vm.createContext({
    selected: 'original', pluginsDirty: false,
    t: key => key, showOutput: () => {}, confirm: () => true,
    setInterval: () => 1, clearInterval: () => {},
    api: async requested => {
      assert.equal(requested, '/api/servers/original/action');
      context.selected = 'other';
      return { ok: true, code: 0, stdout: '', stderr: '' };
    },
    refreshServerStatuses: async () => { refreshes++; },
    runProfileAction: async (...args) => restarts.push(args),
  });
  vm.runInContext(extract('async function updatePlugins() {', '$("saveProperties").onclick'), context);
  await context.updatePlugins();
  assert.deepEqual(restarts, [['restart', 'original']]);
  assert.equal(refreshes, 2);
});

function playerContext() {
  const nodes = {};
  for (const id of ['players', 'playerName', 'targetPlayer', 'onlinePlayerNames', 'playerFeedback', 'playerSummary', 'result']) {
    nodes[id] = { value: '', textContent: '', children: [], append(child) { this.children.push(child); },
      focus() {}, select() { this.wasSelected = true; } };
    Object.defineProperty(nodes[id], 'innerHTML', { set() { this.children = []; } });
  }
  const context = vm.createContext({
    selected: 'test', playerRequestSerial: 0, servers: [{ id: 'test' }],
    $: id => nodes[id], t: key => key, el: (tag, attrs) => ({ tag, ...attrs }),
    renderServers: () => {}, renderOverview: () => {}, navigator: {}, document: { execCommand: () => false },
    api: async () => ({ players: ['Alex', 'Steve'], online: 2, max: 20 }),
  });
  vm.runInContext(extract('function clearPlayerSelection() {', 'async function loadVersions('), context);
  vm.runInContext(extract('function selectedPlayer()', 'async function sendShortcut('), context);
  return { context, nodes };
}

test('manually entered recipient wins over an old list selection', () => {
  const { context, nodes } = playerContext();
  nodes.players.value = 'Alex';
  nodes.playerName.value = 'Steve';
  assert.equal(context.selectedPlayer(), 'Steve');
  context.usePlayerAsTarget();
  assert.equal(nodes.targetPlayer.value, 'Steve');
});

test('refreshing players preserves the typed recipient and selection', async () => {
  const { context, nodes } = playerContext();
  nodes.playerName.value = 'Steve';
  await context.loadPlayers();
  assert.equal(nodes.playerName.value, 'Steve');
  assert.equal(nodes.players.value, 'Steve');
  nodes.playerName.value = 'OfflinePlayer';
  await context.loadPlayers();
  assert.equal(nodes.playerName.value, 'OfflinePlayer');
  assert.equal(nodes.players.value, '');
});

test('late player response cannot overwrite a different server', async () => {
  const { context, nodes } = playerContext();
  let resolve;
  context.api = () => new Promise(done => { resolve = done; });
  const request = context.loadPlayers();
  context.selected = 'other';
  nodes.playerName.value = 'OtherPlayer';
  resolve({ players: ['Alex'] });
  await request;
  assert.equal(nodes.playerName.value, 'OtherPlayer');
  assert.equal(nodes.players.children.length, 0);
});

test('copy falls back to selectable name when clipboard is unavailable on HTTP', async () => {
  const { context, nodes } = playerContext();
  nodes.playerName.value = 'Alex';
  await context.copyPlayerName();
  assert.equal(nodes.playerName.wasSelected, true);
  assert.equal(nodes.playerFeedback.textContent, 'players.copyManual');
});

test('copy writes the selected name to the clipboard when available', async () => {
  const { context, nodes } = playerContext();
  let copied;
  context.navigator.clipboard = { writeText: async text => { copied = text; } };
  nodes.playerName.value = 'Alex';
  await context.copyPlayerName();
  assert.equal(copied, 'Alex');
  assert.equal(nodes.playerFeedback.textContent, 'players.copied');
});

test('catalog search supports German, English, IDs and umlauts', () => {
  const { context } = playerContext();
  const catalog = JSON.parse(fs.readFileSync(path.join(__dirname, 'static/items.json'), 'utf8'));
  for (const query of ['Diamantschwert', 'diamond sword', 'minecraft:diamond_sword']) {
    assert.ok(context.matchingItems(catalog.items, query).some(item => item.id === 'minecraft:diamond_sword'));
  }
  const example = [{ id: 'minecraft:example', de: 'Glück', en: 'Luck' }];
  assert.equal(context.matchingItems(example, 'gluck').length, 1);
  assert.equal(context.matchingItems(example, 'not-an-item').length, 0);
});

function deferred() {
  let resolve, reject;
  const promise = new Promise((yes, no) => { resolve = yes; reject = no; });
  return { promise, resolve, reject };
}
function concurrentActivityContext() {
  const nodes = Object.fromEntries(['result', 'actionStatus', 'refreshStatus', 'activityServer'].map(id =>
    [id, { textContent: '', hidden: true, scrollHeight: 100, scrollTop: 0 }]));
  const timers = new Map(), requests = [];
  let timerId = 0;
  const context = vm.createContext({
    selected: 'a', configDirty: false, pluginsDirty: false, serverActivity: new Map(),
    servers: ['a', 'b', 'c'].map(id => ({ id, name: `Server ${id}` })),
    $: id => nodes[id], t: (key, values = {}) => `${key} ${values.message || ''}`.trim(),
    liveActionLogActions: new Set(['start', 'backup', 'restart']), actionLabel: value => value,
    translateWarning: value => value, confirm: () => false,
    setInterval: callback => { timers.set(++timerId, callback); return timerId; },
    clearInterval: id => timers.delete(id),
    loadServers: async () => {}, refreshServerStatuses: async () => {},
    loadManualPlugins: async () => {}, loadInstalledPlugins: async () => {}, loadBootLog: async () => {},
    api: (url, options) => {
      const request = { url, options, ...deferred() };
      requests.push(request);
      return request.promise;
    },
  });
  vm.runInContext(extract('function activityFor(', 'function waitPaint()'), context);
  vm.runInContext(extract('async function runProfileAction(', 'document.querySelectorAll("[data-action]")'), context);
  vm.runInContext(extract('async function updatePlugins()', '$("saveProperties").onclick'), context);
  return { context, nodes, timers, requests };
}
const success = stdout => ({ ok: true, code: 0, stdout, stderr: '' });

test('three parallel actions retain separate output and status across server switches', async () => {
  const { context: c, nodes, timers, requests } = concurrentActivityContext();
  const actions = ['a', 'b', 'c'].map(id => c.runProfileAction('start', id));
  c.selected = 'b'; c.renderActivity();
  const polls = [...timers.values()].map(poll => poll());
  requests.filter(r => r.url.endsWith('/action-log')).forEach(r =>
    r.resolve({ content: `progress ${r.url.split('/')[3]}` }));
  await Promise.all(polls);
  assert.match(nodes.result.textContent, /progress b/);
  assert.equal(nodes.activityServer.textContent, 'Server b');
  requests[0].resolve(success('A complete'));
  requests[2].resolve({ ok: false, code: 1, stdout: '', stderr: 'C failed' });
  await Promise.all([actions[0], actions[2]]);
  assert.match(nodes.result.textContent, /progress b/);
  assert.equal(nodes.actionStatus.className, 'action-status info');
  c.selected = 'a'; c.renderActivity();
  assert.match(nodes.result.textContent, /A complete/);
  assert.equal(nodes.actionStatus.className, 'action-status success');
  c.selected = 'c'; c.renderActivity();
  assert.match(nodes.result.textContent, /C failed/);
  assert.equal(nodes.actionStatus.className, 'action-status error');
  requests[1].resolve(success('B complete')); await actions[1];
  assert.match(nodes.result.textContent, /C failed/);
  c.selected = 'b'; c.renderActivity();
  assert.match(nodes.result.textContent, /B complete/);
  assert.equal(timers.size, 0);
});

test('late action log cannot replace completion and slow polls do not overlap', async () => {
  const { context: c, nodes, timers, requests } = concurrentActivityContext();
  const action = c.runProfileAction('start');
  const poll = [...timers.values()][0];
  const pending = poll(); await poll();
  assert.equal(requests.length, 2);
  requests[0].resolve(success('final output')); await action;
  requests[1].resolve({ content: 'old progress' }); await pending;
  assert.match(nodes.result.textContent, /final output/);
  assert.doesNotMatch(nodes.result.textContent, /old progress/);
});

test('background plugin failure keeps its own output without borrowing the visible server text', async () => {
  const { context: c, nodes, timers, requests } = concurrentActivityContext();
  const action = c.updatePlugins();
  c.selected = 'b'; c.showOutput('B stays visible');
  const pending = [...timers.values()][0]();
  requests[0].resolve({ ok: false, code: 1, stdout: 'A plugin error', stderr: '' });
  await action;
  requests[1].resolve({ content: 'stale A progress' }); await pending;
  assert.equal(nodes.result.textContent, 'B stays visible');
  c.selected = 'a'; c.renderActivity();
  assert.match(nodes.result.textContent, /A plugin error/);
  assert.match(nodes.result.textContent, /message.pluginUpdateFailed/);
  assert.doesNotMatch(nodes.result.textContent, /B stays visible|stale A progress/);
});

test('refresh failures and clear output belong only to the selected server', async () => {
  const { context: c, nodes, requests } = concurrentActivityContext();
  c.loadServers = async () => { throw new Error('refresh unavailable'); };
  const action = c.runProfileAction('start');
  c.selected = 'b'; c.showOutput('B output');
  requests[0].resolve(success('A output')); await action;
  assert.equal(nodes.refreshStatus.hidden, true);
  c.showOutput('');
  c.selected = 'a'; c.renderActivity();
  assert.match(nodes.result.textContent, /A output/);
  assert.match(nodes.refreshStatus.textContent, /refresh unavailable/);
  c.selected = 'b'; c.renderActivity();
  assert.equal(nodes.result.textContent, '');
  assert.equal(nodes.refreshStatus.hidden, true);
});

test('saving a dirty profile during start cannot steal selection or change action target', async () => {
  const { context: c, nodes, requests } = concurrentActivityContext();
  c.configDirty = true; c.formData = () => ({ id: 'a' }); c.setConfigDirty = () => {};
  vm.runInContext(extract('async function saveCurrentProfile()', 'async function reloadCurrentProfile()'), c);
  const action = c.runProfileAction('start');
  c.selected = 'b'; c.showOutput('B output');
  requests[0].resolve({ id: 'a' });
  await new Promise(resolve => setImmediate(resolve));
  assert.equal(c.selected, 'b');
  assert.equal(requests[1].url, '/api/servers/a/action');
  requests[1].resolve(success('A started')); await action;
  assert.equal(nodes.result.textContent, 'B output');
});
