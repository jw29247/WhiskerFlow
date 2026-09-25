const test = require('node:test');
const assert = require('node:assert/strict');
const vm = require('node:vm');
const fs = require('node:fs');

test('no captions or DOM needed; recording gate, source identity, stale and disabled sources fail closed', async () => {
  let now = 2000, tick, message, onCollection;
  const sent = [], sources = new Map();
  const peer = {connectionState: 'connected', addEventListener() {}, createDataChannel() { return {label:'collections',addEventListener(_,fn) {onCollection=fn;}}; },getReceivers() {return [{track:{kind:'audio'},getContributingSources() {return [{source:42,audioLevel:0.2,timestamp:now}];}}];}};
  const context = {Map,Set,WeakSet,Proxy,Reflect,Date,Number,Math,location:{origin:'https://meet.google.com',pathname:'/abc-defg-hij'},performance:{now:()=>now,timeOrigin:100000},setInterval(fn){tick=fn;},RTCPeerConnection:function(){return peer;},fetch:async()=>({url:''}),addEventListener(_,fn){message=fn;},postMessage(x){sent.push(x);},KualiMeetProtocol:{orderedAsyncHandler:fn=>fn,decodeCollectionPacket:async()=>({users:[{deviceId:'p1',displayName:'Example Person'}],deviceOutputs:[{deviceId:'p1',streamId:'42',outputType:1,disabled:false}]}),indexDeviceOutput(_,bySource,row){sources.set(row.streamId,row);bySource.set(row.streamId,row);}}};
  context.window=context;context.globalThis=context;
  vm.runInNewContext(fs.readFileSync(__dirname+'/observe.js','utf8'),context);
  const p = new context.RTCPeerConnection();p.createDataChannel('collections');
  await onCollection({data:new Uint8Array(1)});
  await new Promise(resolve => setImmediate(resolve));
  tick(); assert.equal(sent.at(-1).samples.length,0);
  message({source:context,origin:context.location.origin,data:{type:'wf-meet-capture-state',enabled:true}});
  // vm contextifies window; deliver through its own window reference.
  vm.runInNewContext('',context);
  // Call stored callback inside context so event.source equals window.
  context.enable = message;
  vm.runInNewContext("enable({source:window,origin:location.origin,data:{type:'wf-meet-capture-state',enabled:true}})",context);
  for(let i=0;i<8;i++){now+=250;tick();}
  assert.ok(sent.at(-1).samples.some(s=>s.displayName==='Example Person'));
  sources.get('42').disabled=true;
  for(let i=0;i<8;i++){now+=250;tick();}
  for(let i=0;i<8;i++){now+=250;tick();}
  assert.equal(sent.at(-1).samples.length,0);
});

const flush = () => new Promise(resolve => setImmediate(resolve));
function harness({timestamp = now => now, decode} = {}) {
  const state = {now: 2000, sent: [], peers: [], level: 0.2, active: true};
  const context = {Map,Set,WeakSet,Proxy,Reflect,Date,Number,Math,location:{origin:'https://meet.google.com',pathname:'/abc-defg-hij'},performance:{now:()=>state.now,timeOrigin:1.7e12},setInterval(fn){state.tick=fn;},fetch:async()=>({url:''}),addEventListener(_,fn){state.message=fn;},postMessage(x){state.sent.push(x);}};
  context.RTCPeerConnection = function() {
    const peer = {connectionState:'connected',addEventListener() {},createDataChannel() { return {label:'collections',addEventListener(_,fn) {state.onCollection=fn;}}; },getReceivers() {return [{track:{kind:'audio'},getContributingSources() {return state.active ? [{source:42,audioLevel:state.level,timestamp:timestamp(state.now)}] : [];}}];}};
    state.peers.push(peer); return peer;
  };
  context.KualiMeetProtocol = {orderedAsyncHandler:fn=>fn,decodeCollectionPacket:decode ?? (async()=>({users:[{deviceId:'p1',displayName:'Example Person'}],deviceOutputs:[{deviceId:'p1',streamId:'42',outputType:1,disabled:false}]})),indexDeviceOutput(_,bySource,row){bySource.set(row.streamId,row);}};
  context.window=context;context.globalThis=context;
  vm.runInNewContext(fs.readFileSync(__dirname+'/observe.js','utf8'),context);
  const p = new context.RTCPeerConnection();p.createDataChannel('collections');
  context.enable = state.message;
  vm.runInNewContext("enable({source:window,origin:location.origin,data:{type:'wf-meet-capture-state',enabled:true}})",context);
  state.run = count => { for (let i = 0; i < count; i++) { state.now += 250; state.tick(); } };
  state.named = () => state.sent.at(-1).samples.some(s => s.displayName === 'Example Person');
  return state;
}

test('epoch-scale CSRC timestamps (webrtc-pc timeOrigin + now clock) are fresh; samples use wall-clock time', async () => {
  const state = harness({timestamp: now => 1.7e12 + now});
  state.onCollection({data:new Uint8Array(1)}); await flush();
  state.run(10);
  assert.ok(state.named());
  assert.ok(Math.abs(state.sent.at(-1).samples[0].atMs - Date.now()) < 5000);
});

test('a speaker pausing for more than a second is named again when they resume', async () => {
  const state = harness();
  state.onCollection({data:new Uint8Array(1)}); await flush();
  state.run(10); assert.ok(state.named());
  state.active = false; state.run(16); assert.equal(state.sent.at(-1).samples.length, 0);
  state.active = true; state.run(10); assert.ok(state.named());
});

test('an undecodable packet withholds names until the mapping is re-sent', async () => {
  let fail = false;
  const good = {users:[{deviceId:'p1',displayName:'Example Person'}],deviceOutputs:[{deviceId:'p1',streamId:'42',outputType:1,disabled:false}]};
  const state = harness({decode: async () => { if (fail) throw new Error('drift'); return good; }});
  state.onCollection({data:new Uint8Array(1)}); await flush();
  state.run(10); assert.ok(state.named());
  // The lost packet may have rebound stream 42 to another participant.
  fail = true;
  state.onCollection({data:new Uint8Array(1)}); await flush();
  state.run(20); assert.equal(state.named(), false);
  fail = false;
  state.onCollection({data:new Uint8Array(1)}); await flush();
  state.run(10); assert.ok(state.named());
});

test('a packet dropped under overload also invalidates mappings from packets queued before it', async () => {
  const good = {users:[{deviceId:'p1',displayName:'Example Person'}],deviceOutputs:[{deviceId:'p1',streamId:'42',outputType:1,disabled:false}]};
  const state = harness({decode: async () => good});
  for (let i = 0; i < 40; i++) state.onCollection({data:new Uint8Array(1)});
  await flush();
  state.run(10); assert.equal(state.named(), false);
  state.onCollection({data:new Uint8Array(1)}); await flush();
  state.run(10); assert.ok(state.named());
});

test('closed peers are pruned even though close() fires no state event', async () => {
  const state = harness();
  state.onCollection({data:new Uint8Array(1)}); await flush();
  state.peers[0].connectionState = 'closed';
  state.run(10);
  assert.equal(state.sent.at(-1).active, false);
});
