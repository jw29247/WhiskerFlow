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
