let enabled = false;
window.addEventListener('message', event => {
  const message = event.data;
  if (event.source !== window || event.origin !== location.origin || message?.type !== 'wf-meet-batch') return;
  if (!Array.isArray(message.samples) || message.samples.length > 64 || typeof message.meetingCode !== 'string') return;
  chrome.runtime.sendMessage({active: message.active === true, meetingCode: message.meetingCode, samples: enabled ? message.samples : []}, response => {
    if (chrome.runtime.lastError) { enabled = false; } else { enabled = response?.accepted === true; }
    window.postMessage({type: 'wf-meet-capture-state', enabled}, location.origin);
  });
});
