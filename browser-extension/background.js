const calls = new Map();
let uniqueTab, stableSince = 0;
chrome.runtime.onMessage.addListener((message, sender, respond) => {
  if (sender.frameId !== 0 || !sender.tab || new URL(sender.url).origin !== 'https://meet.google.com') return;
  const now = Date.now();
  if (message.active) calls.set(sender.tab.id, now); else calls.delete(sender.tab.id);
  for (const [id, last] of calls) if (now - last > 5000) calls.delete(id);
  if (calls.size !== 1 || !message.active) { uniqueTab = undefined; stableSince = 0; respond({accepted: false}); return; }
  if (uniqueTab !== sender.tab.id) { uniqueTab = sender.tab.id; stableSince = now; }
  if (now - stableSince < 5000) { respond({accepted: false}); return; }
  // Short native messages keep the service worker stateless across suspension.
  chrome.runtime.sendNativeMessage('agency.thatworks.whiskerflow.meet', {meetingCode: message.meetingCode, samples: message.samples}, response => {
    if (chrome.runtime.lastError) respond({accepted: false}); else respond(response);
  });
  return true;
});
