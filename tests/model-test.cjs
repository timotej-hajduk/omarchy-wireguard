const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const root = path.join(__dirname, '..');
const model = vm.createContext({});
vm.runInContext(fs.readFileSync(path.join(root, 'Model.js'), 'utf8').replace('.pragma library', ''), model);
const now = 10000;
const current = {publicKey:'recent', handshake:now-5, keepalive:25};
const idle = {publicKey:'idle', handshake:1, keepalive:null};
const stale = {publicKey:'stale', handshake:1, keepalive:25};
assert.equal(model.state({up:false, peers:[current]}, now), 'down');
assert.equal(model.state({up:true, peers:null}, now), 'up');
assert.equal(model.state({up:true, peers:[current]}, now), 'connected');
assert.equal(model.state({up:true, peers:[idle]}, now), 'idle');
assert.equal(model.state({up:true, peers:[current, idle]}, now), 'partial');
assert.equal(model.state({up:true, peers:[current, stale]}, now), 'stale');
assert.equal(model.state({up:true, peers:[{handshake:now-190,keepalive:300}]}, now), 'idle');
const unknown = {handshake:now+60,keepalive:25};
assert.equal(model.state({up:true,peers:[unknown,stale]},now),'stale');
assert.equal(model.state({up:true,peers:[stale,unknown]},now),'stale');
const healthyTunnel = {up:true,peers:[current]};
const idleTunnel = {up:true,peers:[idle]};
const waitingTunnel = {up:true,peers:[]};
const staleTunnel = {up:true,peers:[stale]};
for (const uncertain of [idleTunnel,waitingTunnel,{up:true,peers:null},{up:true,peers:[unknown]}]) {
  assert.notEqual(model.overall([healthyTunnel,uncertain],now),'connected');
  assert.notEqual(model.overall([uncertain,healthyTunnel],now),'connected');
  assert.equal(model.overall([uncertain,staleTunnel],now),'stale');
  assert.equal(model.overall([staleTunnel,uncertain],now),'stale');
}
assert.equal(model.overall([healthyTunnel,{up:false}],now),'connected');
assert.equal(model.fresh(true,false,1000,1005,5), true);
assert.equal(model.fresh(true,true,1000,1005,5), false);
assert.equal(model.fresh(true,false,1000,1020,5), false);
assert.equal(model.fresh(true,false,1000,999,5), false);
assert.match(model.tooltip([],now,{}, {},true,false,false), /unavailable/);
assert.match(model.tooltip([{name:'wg0',up:true,peers:[current,stale]}],now,{}, {},true,true,true), /^DEMO/);
assert.equal(model.parse('{"ok":false,"now":1000,"tunnels":[]}'), null);
assert.equal(model.parse('{"ok":true,"now":1000,"tunnels":[{"name":"../a"}]}'), null);
assert.equal(model.label({name:'constructor'}, {}), 'constructor');
assert.equal(model.probeHost({name:'constructor',dns:[]}, {}), '');

const panel = fs.readFileSync(path.join(root, 'Panel.qml'), 'utf8');
function load(name, context) {
  const start = panel.indexOf('  function ' + name + '(');
  assert(start >= 0);
  const end = panel.indexOf('\n  }', start) + 4;
  vm.runInContext(panel.slice(start, end), context);
}
const notices=[];
const context=vm.createContext({Model:model, labels:{}, notifyChanges:true, everLoaded:true,
  lastStates:{wg0:'up'}, lastTunnels:{wg0:{name:'wg0',drivenAt:null}},
  notify:(...args)=>notices.push(args)});
load('announce', context);
context.announce({now,tunnels:[]});
assert.equal(notices.length,1);
assert.equal(notices[0][1],'down');
context.announce({now:now+2,tunnels:[]});
assert.equal(notices.length,1);

context.lastStates={wg0:'up'};
context.lastTunnels={wg0:{name:'wg0',drivenAt:null}};
context.announce({now,tunnels:[{name:'wg1',up:true,drivenAt:now-1}]});
assert.equal(notices.length,2, 'An action on another tunnel must not hide a disappearance');
context.lastStates={wg0:'up'};
context.lastTunnels={wg0:{name:'wg0',drivenAt:now-1}};
context.announce({now,tunnels:[]});
assert.equal(notices.length,2);

const sample=vm.createContext({Model:model, Date:{now:()=>1000000}, previous:{}, rates:{}, history:{},
  historyLength:60, refreshSeconds:5, announce(){}, status:null, everLoaded:false, failed:false});
load('ingest', sample);
sample.ingest({ok:true,now:1000,tunnels:[{name:'wg0',up:true,rx:100,tx:20,ifindex:8}]});
sample.Date.now=()=>1002000;
sample.ingest({ok:true,now:1002,tunnels:[{name:'wg0',up:true,rx:300,tx:40,ifindex:8}]});
assert.equal(sample.rates.wg0.rx,100);
sample.Date.now=()=>1004000;
sample.ingest({ok:true,now:1004,tunnels:[{name:'wg0',up:true,rx:500,tx:60,ifindex:9}]});
assert.equal(sample.rates.wg0,null);
sample.Date.now=()=>1100000;
sample.ingest({ok:true,now:1100,tunnels:[{name:'wg0',up:true,rx:900,tx:90,ifindex:9}]});
assert.equal(sample.rates.wg0,null);

// Completion requires both EOF and a successful exit, in either signal order.
const finishStart=panel.indexOf('    function finish() {',panel.indexOf('id: statusProc'));
const finishEnd=panel.indexOf('\n    }',finishStart)+6;
let ingestions=0;
const processContext=vm.createContext({Model:model,outputReady:false,exitReady:false,collecting:true,expired:false,code:0,
  output:'{"ok":true,"now":1000,"tunnels":[]}',statusWatchdog:{stop(){}},wg:{ingest(){ingestions++},failed:false}});
vm.runInContext(panel.slice(finishStart,finishEnd),processContext);
processContext.outputReady=true; processContext.finish();
assert.equal(ingestions,0);
processContext.exitReady=true; processContext.finish();
assert.equal(ingestions,1);
processContext.outputReady=false; processContext.finish();
assert.equal(ingestions,1);
processContext.outputReady=true; processContext.finish();
assert.equal(ingestions,2);
processContext.outputReady=true; processContext.code=1; processContext.finish();
assert.equal(ingestions,2);
assert.equal(processContext.wg.failed,true);
processContext.code=0; processContext.expired=true; processContext.finish();
assert.equal(ingestions,2);
console.log('model-test: health, freshness, demo labeling, disappeared-interface notifications and rate resets passed');
