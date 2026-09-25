const calls = new Map();
let uniqueTab, stableSince = 0, port, pending = [], idleTimer;
// A call that stops reporting (tab closed, renderer crash) or a host that stops
// answering must not keep the native host and this worker alive.
const CALL_STALE_MS = 5000, REPLY_TIMEOUT_MS = 10000;
// One long-lived native host per active call instead of a process launch per
// ~1.8 s batch. The host answers strictly in order, so replies are FIFO.
function nativePort() {
  if (port) return port;
  const connected = chrome.runtime.connectNative('agency.thatworks.whiskerflow.meet');
  connected.onMessage.addListener(response => { pending.shift()?.respond(response); });
  connected.onDisconnect.addListener(() => {
    void chrome.runtime.lastError;
    if (port !== connected) return;
    port = undefined;
    for (const entry of pending.splice(0)) entry.respond({accepted: false});
  });
  port = connected;
  return port;
}
function closeNativePort() {
  const current = port;
  port = undefined;
  clearTimeout(idleTimer);
  idleTimer = undefined;
  current?.disconnect();
  for (const entry of pending.splice(0)) entry.respond({accepted: false});
}
function pruneCalls(now) {
  for (const [id, last] of calls) if (now - last > CALL_STALE_MS) calls.delete(id);
  if (uniqueTab !== undefined && !calls.has(uniqueTab)) { uniqueTab = undefined; stableSince = 0; }
  if (calls.size === 0) closeNativePort();
}
function scheduleIdleCheck() {
  clearTimeout(idleTimer);
  idleTimer = setTimeout(() => {
    idleTimer = undefined;
    const now = Date.now();
    if (pending.length && now - pending[0].sentAt > REPLY_TIMEOUT_MS) closeNativePort();
    pruneCalls(now);
    if (port) scheduleIdleCheck();
  }, CALL_STALE_MS + 1000);
}
chrome.tabs?.onRemoved?.addListener(tabId => {
  calls.delete(tabId);
  pruneCalls(Date.now());
});
chrome.runtime.onMessage.addListener((message, sender, respond) => {
  if (sender.frameId !== 0 || !sender.tab || new URL(sender.url).origin !== 'https://meet.google.com') return;
  const now = Date.now();
  if (message.active) calls.set(sender.tab.id, now); else calls.delete(sender.tab.id);
  for (const [id, last] of calls) if (now - last > CALL_STALE_MS) calls.delete(id);
  if (!message.active) {
    // Another Meet tab that is not in a call (home page, ended call) must not
    // reset the active call's stability window.
    if (sender.tab.id === uniqueTab) { uniqueTab = undefined; stableSince = 0; }
    if (calls.size === 0) closeNativePort();
    respond({accepted: false}); return;
  }
  if (calls.size !== 1) { uniqueTab = undefined; stableSince = 0; respond({accepted: false}); return; }
  if (uniqueTab !== sender.tab.id) { uniqueTab = sender.tab.id; stableSince = now; }
  if (now - stableSince < 5000) { respond({accepted: false}); return; }
  // A host that stopped answering is replaced rather than failing every batch.
  if (pending.length && now - pending[0].sentAt > REPLY_TIMEOUT_MS) closeNativePort();
  // A stalled host must not accumulate replies; fail closed until it catches up.
  if (pending.length >= 4) { respond({accepted: false}); return; }
  try {
    nativePort().postMessage({meetingCode: message.meetingCode, samples: message.samples});
    pending.push({respond, sentAt: now});
    scheduleIdleCheck();
  } catch {
    closeNativePort();
    respond({accepted: false}); return;
  }
  return true;
});
