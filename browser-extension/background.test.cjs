const test = require('node:test');
const assert = require('node:assert/strict');
const vm = require('node:vm');
const fs = require('node:fs');

function load() {
  const state = {now: 1_000_000, launches: 0, posted: [], timers: new Map(), nextTimer: 1};
  const port = {
    listeners: {}, disconnected: false,
    onMessage: {addListener(fn) { port.listeners.message = fn; }},
    onDisconnect: {addListener(fn) { port.listeners.disconnect = fn; }},
    postMessage(message) { state.posted.push(message); },
    disconnect() { port.disconnected = true; },
  };
  const chrome = {runtime: {lastError: undefined,
    onMessage: {addListener(fn) { state.listener = fn; }},
    connectNative() { state.launches += 1; port.disconnected = false; return port; }},
    tabs: {onRemoved: {addListener(fn) { state.tabRemoved = fn; }}}};
  const setTimeout = (fn, ms) => { const id = state.nextTimer++; state.timers.set(id, {fn, at: state.now + ms}); return id; };
  const clearTimeout = id => { state.timers.delete(id); };
  const context = {chrome, URL, Map, Date: {now: () => state.now}, setTimeout, clearTimeout};
  state.advance = ms => {
    state.now += ms;
    for (const [id, timer] of [...state.timers]) if (timer.at <= state.now) { state.timers.delete(id); timer.fn(); }
  };
  vm.runInNewContext(fs.readFileSync(__dirname + '/background.js', 'utf8'), context);
  state.port = port;
  state.send = (tab, active) => {
    let reply;
    const keep = state.listener({active, meetingCode: 'abc-defg-hij', samples: []}, {frameId: 0, tab: {id: tab}, url: 'https://meet.google.com/abc-defg-hij'}, value => { reply = value; });
    return {keep, reply: () => reply};
  };
  return state;
}

test('an idle second Meet tab does not reset the active call stability window', () => {
  const state = load();
  state.send(1, true);
  for (let i = 0; i < 4; i++) { state.now += 1800; state.send(2, false); state.send(1, true); }
  state.now += 1800;
  state.send(2, false);
  const forwarded = state.send(1, true);
  assert.equal(forwarded.keep, true);
  assert.equal(state.posted.length > 0, true);
});

test('one native host serves every batch in order', () => {
  const state = load();
  state.send(1, true);
  state.now += 6000;
  const first = state.send(1, true);
  state.now += 1800;
  const second = state.send(1, true);
  assert.equal(state.launches, 1);
  state.port.listeners.message({accepted: true});
  state.port.listeners.message({accepted: false});
  assert.deepEqual(first.reply(), {accepted: true});
  assert.deepEqual(second.reply(), {accepted: false});
  state.send(1, false);
  assert.equal(state.port.disconnected, true, 'the host exits once no call is active');
});

test('closing the in-call tab without a final message closes the native host', () => {
  const state = load();
  state.send(1, true);
  state.now += 6000;
  state.send(1, true);
  assert.equal(state.port.disconnected, false);
  state.tabRemoved(1);
  assert.equal(state.port.disconnected, true);
});

test('a call that stops reporting closes the native host after the stale window', () => {
  const state = load();
  state.send(1, true);
  state.now += 6000;
  const batch = state.send(1, true);
  state.advance(7000);
  assert.equal(state.port.disconnected, true);
  assert.equal(batch.reply()?.accepted, false);
});

test('a host that stops answering is replaced instead of failing the rest of the call', () => {
  const state = load();
  state.send(1, true);
  state.now += 6000;
  for (let i = 0; i < 4; i++) { state.send(1, true); state.now += 1800; }
  const stalled = state.send(1, true);
  assert.equal(stalled.reply()?.accepted, false);
  for (let i = 0; i < 3; i++) { state.now += 1800; state.send(1, true); }
  assert.equal(state.launches, 2, 'the stalled host is replaced once its oldest reply times out');
  const next = state.send(1, true);
  assert.equal(next.keep, true);
});
