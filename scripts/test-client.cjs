#!/usr/bin/env node
// Test the actual ArkTS settings, HTTP parser and serialized VPN lifecycle.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const ts = require(path.join(process.env.HARMONY_CLT_HOME, 'sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript'));
const root = path.resolve(__dirname, '../app/entry/src/main/ets');
const files = new Map();
const timers = new Map();
let timerId = 0;
const calls = {create: [], protect: [], start: [], stop: [], close: [], destroys: 0};
let connectPending;
let connectValue = 0xa5200001;
let stats = {state: 'running', txBytes: 40, rxBytes: 20, errno: 0};
let listening;
let listenersCreated = 0, listenCalls = 0;
const io = {OpenMode: {CREATE:1,WRITE_ONLY:2,TRUNC:4},
 readTextSync(p) {if (!files.has(p)) throw new Error('ENOENT'); return files.get(p);},
 openSync:p=>({fd:p}), writeSync:(p,v)=>files.set(p,v), closeSync() {},
 renameSync(p,q){files.set(q,files.get(p));files.delete(p);}};
class Ability { context = {filesDir:'/app',extensionAbilityInfo:{bundleName:'com.example.tether'}}; }
const connection = {protect:async fd=>calls.protect.push(fd), create:async config=>{calls.create.push(config);return 23;}, destroy:async()=>{calls.destroys++;}};
const dnsCalls = {all:0,properties:[],vpn:[],physical:0,defaults:0};
let networks = [], networkPending;
const properties = new Map();
const networkManager = {
 getAllNets:async()=>{dnsCalls.all++;return networkPending??networks;},
 getConnectionProperties:async net=>{dnsCalls.properties.push(net.netId);return properties.get(net.netId);},
 getAddressesByName:async()=>{dnsCalls.defaults++;return [{address:'192.0.2.9',family:1}];}
};
const modules = {
 '@kit.CoreFileKit':{fileIo:io},
 '@kit.CryptoArchitectureKit':{cryptoFramework:{createRandom:()=>({generateRandomSync:n=>({data:new Uint8Array(n).fill(7)})})}},
 '@kit.PerformanceAnalysisKit':{hilog:{info(){},warn(){},error(){}}},
 '@kit.AbilityKit':{}, '@kit.BasicServicesKit': {systemDateTime:{}},
 '@kit.NetworkKit': {connection:networkManager,VpnExtensionAbility: Ability, vpnExtension:{createVpnConnection:()=>connection,stopVpnExtensionAbility:async()=>{}},socket:{constructTCPSocketServerInstance:()=>{listenersCreated++;return {on(event,cb){if(event==='connect')listening=cb;},listen:async()=>{listenCalls++;}};}}},
 'libtether.so':{default:{newSession:()=>3,createSocket:()=>11,connect:()=>connectPending??Promise.resolve(connectValue),start:(...args)=>calls.start.push(args),status:()=>JSON.stringify(stats),stop:id=>calls.stop.push(id),close:fd=>calls.close.push(fd)}}
};
const cache = new Map();
function load(relative) {
 const filename=path.resolve(root,relative);if(cache.has(filename))return cache.get(filename);
 const context={exports:{}, require:name=>modules[name]??load(path.relative(root,path.resolve(path.dirname(filename),name+'.ets'))),
   Date,JSON,Number,String,Error,Uint8Array,ArrayBuffer,Math,Promise,
   setTimeout:(cb,ms)=>{timers.set(++timerId,{cb,ms});return timerId;},clearTimeout:id=>timers.delete(id),
   setInterval:(cb,ms)=>{timers.set(++timerId,{cb,ms});return timerId;},clearInterval:id=>timers.delete(id)};
 vm.runInNewContext(ts.transpileModule(fs.readFileSync(filename,'utf8'),{compilerOptions:{target:ts.ScriptTarget.ES2021,module:ts.ModuleKind.CommonJS}}).outputText,context,{filename});
 cache.set(filename,context.exports);return context.exports;
}
const plain=x=>JSON.parse(JSON.stringify(x));
const tick=async()=>{for(let i=0;i<15;++i)await Promise.resolve();};
const id='12345678-1234-4234-8234-123456789012';
async function main(){
 const settings=load('common/Settings.ets');
 assert.equal(settings.loadSettings('/app').ipv6,false);
 for(const local of [false,true]){
  assert.equal(settings.decodeRelayPolicy(42,local).effectiveIpv6,false);
  assert.equal(settings.decodeRelayPolicy(0xa5200001,local).effectiveIpv6,local);
  assert.equal(settings.decodeRelayPolicy(0xa5600001,local).effectiveIpv6,false);
  assert.equal(settings.decodeRelayPolicy(0xa5a00001,local).effectiveIpv6,true);
  assert.equal(settings.decodeRelayPolicy(0xa5800001,local).effectiveIpv6,false);
  assert.equal(settings.decodeRelayPolicy(0xa5e00001,local).effectiveIpv6,false);
 }
 assert.deepEqual(plain(settings.parseApplications('com.a.app\ncom.b.app,com.a.app')),['com.a.app','com.b.app']);
 for(const invalid of ['name','com..app','com.app/evil','a.'.repeat(200)])assert.throws(()=>settings.parseApplications(invalid));
 assert.throws(()=>settings.parseApplications(Array.from({length:64},(_,i)=>'com.example.app'+i).join('\n')));
 const prefs=new settings.TetherSettings();prefs.appMode='allow';prefs.applications=['com.example.test','com.example.tether'];
 assert.deepEqual(plain(settings.routedApplications(prefs,'com.example.tether')),['com.example.test','com.example.tether']);
 prefs.appMode='deny';assert.deepEqual(plain(settings.routedApplications(prefs,'com.example.tether')),['com.example.test']);
 settings.saveSettings('/app',prefs);assert.equal(settings.loadSettings('/app').appMode,'deny');
 const addresses=load('common/NetworkAddress.ets');
 for(const value of ['::','::1','fd00:7265:7674::2','2001:db8:1:2:3:4:5:6','::ffff:192.0.2.1'])assert.equal(addresses.validIPv6(value),true,value);
 for(const value of [':::1','1::2::3',':1','1:2:3:4:5:6:7:8:9','fe80::1%wlan0','::ffff:999.0.0.1'])assert.equal(addresses.validIPv6(value),false,value);
 assert.equal(addresses.sameAddress('::1','0:0:0:0:0:0:0:1'),true);
 const protocol=load('vpn/ControlProtocol.ets');
 assert.equal(protocol.parseConfigure(JSON.stringify({request_id:id,dns:'fd00::3'})).dns,'fd00::3');
 for(const patch of [{port:80},{dns:'example.com'},{url:'http://example.com'},{reloadSettings:'true'},{}])assert.throws(()=>protocol.parseConfigure(JSON.stringify({request_id:id,...patch})));
 assert.equal(protocol.asciiJSON({message:'已连接'}).includes('已'),false);
 const probe=load('probe/NetworkProbe.ets');
 assert.equal(probe.parseRequest(JSON.stringify({request_id:id,servers:[{host:'fd00::1',port:3478,family:6}]})).servers[0].host,'fd00::1');
 assert.throws(()=>probe.parseRequest(JSON.stringify({request_id:id,servers:[{host:'fd00::1',port:3478,family:4}]})));
 const wifi={netId:100,getAddressesByName:async()=>{dnsCalls.physical++;return [{address:'192.0.2.9',family:1}];}};
 const vpnNetwork={netId:207,getAddressesByName:async host=>{dnsCalls.vpn.push(host);return host==='only6.test'
   ? [{address:'fd42:7265:7674:51::1',family:2}] : [{address:'198.18.0.1',family:1}];}};
 properties.set(100,{interfaceName:'wlan0',linkAddresses:[{address:{address:'10.0.0.2',family:1}}]});
 properties.set(207,{interfaceName:'vpn-tun',linkAddresses:[{address:{address:'10.0.0.2',family:1}},{address:{address:'fd00:7265:7674::2',family:2}}]});
 networks=[wifi,vpnNetwork];
 const vpnProbe=new probe.ProbeRun('10.0.0.2','fd00:7265:7674::2');
 assert.equal((await vpnProbe.addressFor({host:'only6.test',port:3478,family:6})).address,'fd42:7265:7674:51::1');
 assert.equal((await vpnProbe.addressFor({host:'only4.test',port:3478,family:4})).address,'198.18.0.1');
 assert.equal(dnsCalls.all,1,'one VPN network discovery per ProbeRun');
 assert.deepEqual(dnsCalls.properties,[100,207]);
 assert.deepEqual(dnsCalls.vpn,['only6.test','only4.test']);
 assert.equal(dnsCalls.physical,0,'matching an address on Wi-Fi must not select the physical resolver');
 assert.equal(dnsCalls.defaults,0,'VPN domain probes never use the default resolver');
 const literalProbe=new probe.ProbeRun('10.0.0.2','fd00:7265:7674::2');
 assert.equal((await literalProbe.addressFor({host:'fd42::1',port:3478,family:6})).family,2);
 assert.equal(dnsCalls.all,1,'literal IP addresses do not discover networks');
 networks=[wifi];
 await assert.rejects(new probe.ProbeRun('10.0.0.2').addressFor({host:'only6.test',port:3478,family:6}),/vpn_dns_unavailable/);
 assert.equal(dnsCalls.defaults,0,'missing VPN fails explicitly without a default-network fallback');
 const legacyProbe=new probe.ProbeRun();
 assert.equal((await legacyProbe.addressFor({host:'legacy.test',port:3478})).address,'192.0.2.9');
 assert.equal(dnsCalls.defaults,1,'legacy foreground probing retains its default-network resolver');
 let finishNetwork;
 networkPending=new Promise(resolve=>finishNetwork=resolve);
 const canceledProbe=new probe.ProbeRun('10.0.0.2');
 const canceledLookup=canceledProbe.addressFor({host:'only6.test',port:3478,family:6});
 canceledProbe.cancel();finishNetwork([vpnNetwork]);
 await assert.rejects(canceledLookup,/probe_canceled/);
 networkPending=new Promise(resolve=>finishNetwork=resolve);
 const timedLookup=new probe.ProbeRun('10.0.0.2').addressFor({host:'only6.test',port:3478,family:6});
 for(const item of [...timers.values()].filter(item=>item.ms===1000))item.cb();
 await assert.rejects(timedLookup,/vpn_dns_timeout/);
 finishNetwork([vpnNetwork]);await tick();networkPending=undefined;
 assert.deepEqual(dnsCalls.vpn,['only6.test','only4.test'],'late or canceled discovery cannot start a DNS query');
 const auth=load('common/ControlAuth.ets'); const token=auth.ensureControlToken('/app');
 assert.equal(token.length,64);assert.equal(auth.matchesControlToken(token,'Bearer '+token),true);
 assert.equal(auth.matchesControlToken(token,'Bearer '+token+'0'),false);
 assert.equal(probe.validRequestId(auth.newRequestId()),true);
 const {VpnControlServer}=load('vpn/VpnControlServer.ets');
 let probes=0,configured=0,stopped=0,catalogs=0,resolveProbe;
 const handler={applicationsPending:()=>123,applications:()=>{catalogs++;},status:()=>({protocol_version:2,state:'connected',port:41417}),token:()=>token,
 probe:async()=>{probes++;return new Promise(resolve=>resolveProbe=resolve);}, configure:async()=>{configured++;},stop:async()=>{stopped++;}};
 const server=new VpnControlServer(handler);await server.begin();
 function openClient(){
  const state={response:'',closed:false,events:{}};
  const client={on:(e,cb)=>state.events[e]=cb,close:async()=>{state.closed=true;state.events.close?.();},send:async({data})=>{state.response+=data;}};
  listening(client);return state;
 }
 async function rawRequest(raw,split){
  const client=openClient();
  for(const part of split ? [raw.substring(0,split),raw.substring(split)] : [raw]) {
   client.events.message?.({message:Uint8Array.from(Buffer.from(part)).buffer});await tick();
  }
  return client.response;
 }
 async function request(method,route,body='',authorized=true,extra=''){
  const raw=method+' '+route+' HTTP/1.1\r\n'+(authorized?'Authorization: Bearer '+token+'\r\n':'')+
   'Content-Type: application/json\r\nContent-Length: '+body.length+'\r\n'+extra+'\r\n'+body;
  return rawRequest(raw);
 }
 assert.match(await request('GET','/v1/applications/request','',false),/^HTTP\/1.1 401/);
 assert.match(await request('GET','/v1/applications/request'),/"request":123/);
 assert.match(await request('POST','/v1/applications',JSON.stringify({request:123,applications:[]})),/^HTTP\/1.1 200/);
 assert.equal(catalogs,1);
 assert.match(await request('POST','/v1/applications',JSON.stringify({request:122,applications:[]})),/^HTTP\/1.1 409/);
 assert.equal(catalogs,1,'canceled or expired reads cannot replace the catalog');
 const largeCatalog=JSON.stringify({request:123,applications:Array.from({length:200},(_,i)=>({bundleName:'com.example.app'+i,label:'Application '+i}))});
 assert.match(await request('POST','/v1/applications',largeCatalog),/^HTTP\/1.1 200/);
 assert.equal(configured,0);assert.equal(stopped,0,'catalog import never changes VPN lifecycle');
 assert.match(await request('POST','/v1/applications',JSON.stringify({request:123,applications:[],error:'read_failed'})),/^HTTP\/1.1 200/);
 assert.match(await request('POST','/v1/applications',JSON.stringify({request:123,applications:[],error:'arbitrary'})),/^HTTP\/1.1 400/);
 assert.match(await request('GET','/v1/status','',false),/^HTTP\/1.1 200/);
 assert.match(await request('POST','/v1/stop',JSON.stringify({request_id:id}),false),/^HTTP\/1.1 401/);assert.equal(stopped,0);
 assert.match(await request('POST','/v1/configure',JSON.stringify({request_id:id,port:41419})),/^HTTP\/1.1 202/);assert.equal(configured,1);
 assert.match(await request('POST','/v1/stop',JSON.stringify({request_id:id}),true,'Content-Length: 0\r\n'),/^HTTP\/1.1 400/);
 for(const raw of ['GET /v1/status HTTP/1.1\r\nContent-Length: 1\r\n\r\nx',
  'POST /v1/stop HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n0\r\n\r\n',
  'POST /v1/stop HTTP/1.1\r\nContent-Length: 4097\r\n\r\n',
  'GET /v1/status HTTP/1.1\r\n\r\nGET /v1/status HTTP/1.1\r\n\r\n',
  'GET /v1/status?token=secret HTTP/1.1\r\n\r\n',
  'OPTIONS /v1/status HTTP/1.1\r\n\r\n',
  'GET /v1/status HTTP/1.1\r\nX-Large: '+ 'x'.repeat(8192)+'\r\n\r\n']) {
   assert.match(await rawRequest(raw),/^HTTP\/1.1 400/);
 }
 assert.match(await rawRequest('GET /v1/status HTTP/1.1\r\n\r\n',8),/^HTTP\/1.1 200/,'split TCP requests reassemble');
 const originReply=await request('GET','/v1/status','',false,'Origin: https://example.com\r\n');
 assert.match(originReply,/^HTTP\/1.1 200/);assert.equal(originReply.includes('Access-Control-Allow-Origin'),false);
 assert.match(await request('GET','/v1/missing'),/^HTTP\/1.1 404/);
 assert.match(await request('GET','/v1/probe/not-a-uuid'),/^HTTP\/1.1 404/);
 for(const invalid of ['{}','null',JSON.stringify({request_id:id,port:0}),JSON.stringify({request_id:id,dns:'1.2.3.4:53'}),JSON.stringify({request_id:id,appMode:'all'})]){
  assert.match(await request('POST','/v1/configure',invalid),/^HTTP\/1.1 400/);
 }
 const idleClients=Array.from({length:4},()=>openClient());
 assert.equal(openClient().closed,true,'fifth concurrent idle connection is immediately rejected');
 for(const timer of [...timers.values()].filter(item=>item.ms===3000))timer.cb();
 assert.equal(idleClients.every(client=>client.closed),true,'incomplete headers expire');
 assert.match(await request('GET','/v1/status'),/^HTTP\/1.1 200/,'capacity is released after timeout');
 let finishConfigure;
 handler.configure=async()=>{configured++;await new Promise(resolve=>finishConfigure=resolve);};
 const configBody=JSON.stringify({request_id:id,port:41419});
 assert.match(await request('POST','/v1/configure',configBody),/^HTTP\/1.1 202/);
 assert.match(await request('POST','/v1/configure',configBody),/^HTTP\/1.1 409/,'in-flight configure is serialized');
 finishConfigure();await tick();
 handler.configure=async()=>{configured++;};
 const configuredBefore=configured;
 assert.match(await request('POST','/v1/configure',configBody),/^HTTP\/1.1 202/);
 assert.equal(configured,configuredBefore+1,'configure UUID is correlation only, no request-id replay cache');
 assert.match(await request('POST','/v1/stop',JSON.stringify({request_id:id})),/^HTTP\/1.1 202/);
 assert.match(await request('POST','/v1/stop',JSON.stringify({request_id:id})),/^HTTP\/1.1 202/);
 assert.equal(stopped,2,'stop is accepted until the extension has actually closed its control server');
 const body=JSON.stringify({request_id:id,servers:[{host:'127.0.0.1',port:3478}]});
 assert.match(await request('POST','/v1/probe',body),/^HTTP\/1.1 202/);assert.equal(probes,1);
 assert.match(await request('POST','/v1/probe',body),/^HTTP\/1.1 202/);assert.equal(probes,1);
 assert.match(await request('POST','/v1/probe',body.replace(id,id.replace('12345678','12345679'))),/^HTTP\/1.1 409/);
 assert.match(await request('GET','/v1/probe/'+id,'',false),/^HTTP\/1.1 401/);
 resolveProbe({request_id:id,path:'vpn'});await tick();
 assert.match(await request('GET','/v1/probe/'+id),/^HTTP\/1.1 200/);
 server.probeExpires=Date.now()-1;
 assert.match(await request('GET','/v1/probe/'+id),/^HTTP\/1.1 404/,'completed probes expire after their cache window');
 const {acceptPrivacy}=load('common/PrivacyConsent.ets');acceptPrivacy('/app');
 const Vpn=load('vpn/TetherVpnAbility.ets').default;
 let complete;connectPending=new Promise(resolve=>complete=resolve);
 const vpn=new Vpn();vpn.onCreate({parameters:{port:'41417'}});await tick();
 const sharedListener=listening, sharedListenerCount=listenersCreated, sharedListenCalls=listenCalls;
 assert.equal(vpn.status().controlReady,true);
 vpn.onDestroy();complete(0xa5200001);await tick();await vpn.operations;
 assert.equal(calls.create.length,0,'stopped pending connection must not create late VPN');
 assert.equal(calls.start.length,0);assert.ok(calls.close.includes(11));
 assert.equal(vpn.status().controlReady,false);
 assert.equal(await request('GET','/v1/status'),'', 'stopped extension rejects new control connections');
 connectPending=undefined;connectValue=0xa5a00001;
 prefs.ipv6=false;prefs.appMode='allow';settings.saveSettings('/app',prefs);
 const live=new Vpn();live.onCreate({parameters:{}});await tick();await live.operations;
 assert.equal(listening,sharedListener,'the same listener is reactivated when the extension is recreated');
 assert.equal(listenersCreated,sharedListenerCount);assert.equal(listenCalls,sharedListenCalls);
 let liveStatusReply=await request('GET','/v1/status','',false);
 assert.match(liveStatusReply,/^HTTP\/1.1 200/);
 assert.equal(JSON.parse(liveStatusReply.split('\r\n\r\n')[1]).controlReady,true);
 const rotation='a'.repeat(64);auth.ensureControlToken('/app',rotation);
 assert.match(await request('POST','/v1/configure',configBody),/^HTTP\/1.1 401/,'old token immediately stops authorizing requests');
 assert.match(await rawRequest('POST /v1/configure HTTP/1.1\r\nAuthorization: Bearer '+rotation+'\r\nContent-Type: application/json\r\nContent-Length: '+configBody.length+'\r\n\r\n'+configBody),/^HTTP\/1.1 202/);
 await live.operations;auth.ensureControlToken('/app',token);
 assert.equal(calls.create.at(-1).isIPv6Accepted,true,'server on overrides phone off');
 assert.equal(calls.create.at(-1).addresses[1].address.address,'fd00:7265:7674::2');
 assert.equal(calls.create.at(-1).routes[1].destination.address.address,'::');
 assert.equal(calls.create.at(-1).routes[1].destination.prefixLength,0);
 assert.deepEqual(plain(calls.create.at(-1).routes[1].gateway),{address:''});
 assert.equal(calls.create.at(-1).routes[1].hasGateway,false);
 assert.equal(calls.create.at(-1).routes[1].isDefaultRoute,false);
 assert.equal(calls.create.at(-1).routes[0].gateway.address,'0.0.0.0');
 assert.equal(calls.create.at(-1).routes[0].isDefaultRoute,true);
 assert.equal(calls.create.at(-1).trustedApplications.includes('com.example.tether'),true);
 assert.equal(calls.start.at(-1)[3],1);
 const epoch=live.status().vpnSession;const creates=calls.create.length;
 await live.configure({request_id:id,port:41419});assert.equal(calls.create.length,creates,'same effective config preserves existing VPN');
 await live.configure({request_id:id,port:41417});assert.equal(calls.create.length,creates+1);assert.ok(live.status().vpnSession>epoch);
 stats={...stats,state:'error',errno:104};live.tick();live.tick();await live.operations;
 assert.equal(live.status().reconnects,1,'one dead worker schedules one recovery');
 liveStatusReply=await request('GET','/v1/status','',false);
 const recoveringStatus=JSON.parse(liveStatusReply.split('\r\n\r\n')[1]);
 assert.equal(recoveringStatus.controlReady,true);assert.equal(recoveringStatus.state,'reconnecting');
 assert.equal(listening,sharedListener);
 assert.match(await request('POST','/v1/probe',body),/^HTTP\/1.1 409/,'recovery exposes status but refuses probes');
 assert.equal([...timers.values()].filter(t=>t.ms===1000).length>=1,true);
 const creationsBeforeRecovery=calls.create.length, destroysBeforeRecovery=calls.destroys;
 stats={...stats,state:'running',txBytes:0,rxBytes:0};
 const retry=[...timers.values()].at(-1);retry.cb();await tick();await live.operations;
 assert.equal(calls.create.length,creationsBeforeRecovery,'relay-only recovery reuses the existing OS VPN');
 assert.equal(calls.destroys,destroysBeforeRecovery,'relay-only recovery never stops OS VPN');
 assert.equal(live.status().state,'connected');
 assert.equal(JSON.parse((await request('GET','/v1/status')).split('\r\n\r\n')[1]).controlReady,true);
 stats={...stats,state:'error',errno:5,tunError:true};live.tick();await live.operations;
 assert.equal(calls.destroys,destroysBeforeRecovery+1,'real TUN failure releases the broken OS VPN');
 live.onDestroy();await live.operations;
 console.log('PASS: policy/routing, IPv6, HTTP auth/framing/capacity/timeouts, actual replay behavior, listener reuse after stop/recovery, immediate token rotation, no-op configure, serialized recovery');
}
main().catch(error=>{console.error(error);process.exitCode=1;});
