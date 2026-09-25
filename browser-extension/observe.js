/* WhiskerFlow: observe metadata only. Never enable captions or modify audio frames. */
(() => {
  const protocol = globalThis.KualiMeetProtocol;
  if (!protocol || !globalThis.RTCPeerConnection) return;
  const users = new Map(), devices = new Map(), sources = new Map(), peers = new Set();
  const seenChannels = new WeakSet();
  let enabled = false, queued = [], lastTick = 0, pendingPackets = 0;
  window.addEventListener('message', event => {
    if (event.source === window && event.origin === location.origin && event.data?.type === 'wf-meet-capture-state') {
      enabled = event.data.enabled === true;
      if (!enabled) queued = [];
    }
  });
  function updateUsers(rows) {
    for (const row of rows.slice(0, 500)) users.set(row.deviceId, row);
    if (users.size > 1000) users.clear();
  }
  const collections = protocol.orderedAsyncHandler(async data => {
    // Bound work before decoding; malformed/unsupported data never affects Meet.
    if ((data?.byteLength ?? data?.size ?? 0) > 1024 * 1024) return;
    try {
      const update = await protocol.decodeCollectionPacket(data);
      updateUsers(update.users);
      for (const output of update.deviceOutputs.slice(0, 1000)) {
        if (output.outputType === 1) protocol.indexDeviceOutput(devices, sources, {...output, updatedAt: performance.now()});
      }
      if (sources.size > 2000) { sources.clear(); devices.clear(); }
    } catch { sources.clear(); devices.clear(); /* Protocol drift leaves names unavailable. */ }
  });
  function observeChannel(channel) {
    if (seenChannels.has(channel) || channel.label !== 'collections') return;
    seenChannels.add(channel);
    channel.addEventListener('message', event => {
      if (pendingPackets >= 8) { devices.clear(); sources.clear(); return; }
      pendingPackets += 1;
      void collections(event.data).finally(() => { pendingPackets -= 1; });
    });
  }
  const Original = window.RTCPeerConnection;
  window.RTCPeerConnection = new Proxy(Original, {
    construct(target, args) {
      const peer = Reflect.construct(target, args);
      peers.add(peer);
      peer.addEventListener('datachannel', event => observeChannel(event.channel));
      const create = peer.createDataChannel;
      peer.createDataChannel = function(...params) {
        const channel = Reflect.apply(create, this, params); observeChannel(channel); return channel;
      };
      peer.addEventListener('connectionstatechange', () => {
        if (peer.connectionState === 'closed') peers.delete(peer);
      });
      return peer;
    }
  });
  const fetchOriginal = window.fetch;
  window.fetch = async function(...args) {
    const response = await Reflect.apply(fetchOriginal, this, args);
    if (response.url === 'https://meet.google.com/$rpc/google.rtc.meetings.v1.MeetingSpaceService/SyncMeetingSpaceCollections') {
      void response.clone().text().then(value => {
        if (value.length < 2 * 1024 * 1024) updateUsers(protocol.decodeSyncUsersBase64(value));
      }).catch(() => {});
    }
    return response;
  };
  const activity = new Map();
  setInterval(() => {
    const now = performance.now();
    const connected = [...peers].filter(peer => peer.connectionState === 'connected');
    const active = connected.length > 0 && /^[a-z]{3}-[a-z]{4}-[a-z]{3}$/.test(location.pathname.slice(1));
    // Always publish connection status; the isolated relay asks the native host
    // whether a recording is armed before forwarding any participant metadata.
    if (now - lastTick > 1800) {
      window.postMessage({type: 'wf-meet-batch', active, meetingCode: location.pathname.slice(1), samples: enabled ? queued.splice(0, 64) : []}, location.origin);
      queued = []; lastTick = now;
    }
    if (!enabled || !active) return;
    const unique = new Map();
    for (const peer of connected) for (const receiver of peer.getReceivers()) {
      if (receiver.track?.kind !== 'audio') continue;
      for (const source of receiver.getContributingSources()) {
        if (now - source.timestamp > 300 || source.timestamp > now + 100) continue;
        const key = String(source.source >>> 0), output = sources.get(key);
        const previous = activity.get(key);
        activity.set(key, {at: now, requiredUpdate: previous && now - previous.at > 1000 ? previous.at : (previous?.requiredUpdate ?? 0)});
        if (!Number.isFinite(source.audioLevel) || source.audioLevel < 0.01 || !output || output.disabled || output.updatedAt < activity.get(key).requiredUpdate) continue;
        const raw = users.get(output.deviceId), user = users.get(raw?.parentDeviceId) || raw;
        if (!user || user.isCurrentUser) continue;
        const name = (user.displayName || user.fullName || '').trim();
        if (!name || name.length > 100) continue;
        unique.set(user.deviceId, {atMs: Math.round(performance.timeOrigin + now), participantID: user.deviceId, displayName: name});
      }
    }
    queued.push(...unique.values());
    if (queued.length > 64) queued = []; // Fail closed under overload.
  }, 250);
})();
