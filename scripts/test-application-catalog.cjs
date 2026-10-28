#!/usr/bin/env node
const assert = require('node:assert/strict'), fs = require('node:fs'), path = require('node:path'), vm = require('node:vm');
const ts = require(path.join(process.env.HARMONY_CLT_HOME,'sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript'));
const root = path.resolve(__dirname, '../app/entry/src/main/ets');
const files = new Map();
let failWrite = false, closedFiles = 0;
const modules = {'@kit.CoreFileKit': {fileIo: {
 OpenMode:{CREATE:1,WRITE_ONLY:2,TRUNC:4},
 openSync:name=>({fd:name}), closeSync:()=>{closedFiles++},
 writeSync:(name,text)=>{files.set(name,text);if(failWrite)throw Error('disk full')},
 readTextSync:name=>{if(!files.has(name))throw Error('missing');return files.get(name)},
 renameSync:(a,b)=>{files.set(b,files.get(a));files.delete(a)}
}}};
function load(relative) {
 const filename=path.resolve(root,relative),ctx={exports:{},Set,Promise,Array,Number,String,Error,JSON,Date,
 require:name=>modules[name]??load(path.relative(root,path.resolve(path.dirname(filename),name+'.ets')))};
 vm.runInNewContext(ts.transpileModule(fs.readFileSync(filename,'utf8'),{compilerOptions:{module:ts.ModuleKind.CommonJS,target:ts.ScriptTarget.ES2021}}).outputText,ctx,{filename});return ctx.exports;
}
const plain=value=>JSON.parse(JSON.stringify(value));
const c=load('common/ApplicationCatalog.ets'), self='com.example.self';
assert.equal(c.loadApplicationCatalog('/phone').applications.length,0);
c.requestApplicationCatalog('/phone');
const request=c.catalogRequest('/phone');assert.ok(request>0);
const payload={request,applications:[{bundleName:'com.example.browser',label:'浏览器'},{bundleName:'com.example.browser',label:'重复'},{bundleName:self,label:'RevTether'},{bundleName:'com.example.game',label:'Game 🎮'}]};
const catalog=c.parseApplicationCatalog(JSON.stringify(payload));assert.equal(catalog.applications.length,3);
c.saveApplicationCatalog('/phone',catalog);
assert.ok(c.loadApplicationCatalog('/phone').updatedAt>0);
const cachePath='/phone/application-catalog.json', savedCache=files.get(cachePath), closes=closedFiles;
failWrite=true;
assert.throws(()=>load('common/PersistentFile.ets').writeTextAtomic(cachePath,'partial write'),/disk full/);
failWrite=false;
assert.equal(files.get(cachePath),savedCache,'failed writes must preserve the committed cache');
assert.equal(closedFiles,closes+1,'failed writes must still close the temporary file');
assert.equal(c.parseApplicationCatalog(JSON.stringify({...payload,updatedAt:'invalid'})).updatedAt,0);
const apps=c.loadApplicationCatalog('/phone').applications;assert.equal(apps.length,3);
assert.equal(c.applicationChoices(apps,[],self,'浏览',false).length,1);
assert.equal(c.applicationChoices(apps,[],self,'BROWSER',false).length,1);
assert.equal(c.applicationChoices(apps,[],self,'anything',false).length,0);
const selected=['com.example.uninstalled','com.example.browser',self];
const missing=c.applicationChoices(apps,selected,self,'',true);assert.equal(missing.length,2);
assert.equal(missing.find(a=>a.bundleName.endsWith('uninstalled')).available,false);
assert.equal(selected.length,3);
assert.deepEqual(plain(c.toggleApplication(['com.example.browser'],'com.example.browser',self)),[]);
assert.deepEqual(plain(c.toggleApplication([],self,self)),[]);
const full=Array.from({length:63},(_,i)=>'com.example.app'+i);
assert.throws(()=>c.toggleApplication(full,'com.example.extra',self),/63/);
assert.equal(c.toggleApplication(full,full[0],self).length,62);assert.equal(full.length,63);
assert.throws(()=>c.saveApplicationCatalog('/phone',{...catalog,request:request-1}),/stale/);
for(const bad of [null,{}, {...payload,request:-1},{...payload,applications:[{bundleName:'a;bad',label:'bad'}]}, {...payload,applications:[{bundleName:self,label:'bad\n'}]}, {...payload,applications:new Array(1001).fill(payload.applications[0])}]) {
 assert.throws(()=>c.parseApplicationCatalog(JSON.stringify(bad)));
}
assert.equal(c.loadApplicationCatalog('/phone').applications.length,3,'invalid replacement retains prior cache');
assert.equal(c.pendingApplicationCatalog('/phone'),0,'completed requests do not re-enumerate');
const next=c.requestApplicationCatalog('/phone');assert.notEqual(next,request);
assert.equal(c.pendingApplicationCatalog('/phone'),next);
c.cancelApplicationCatalog('/phone',request);
assert.equal(c.pendingApplicationCatalog('/phone'),next,'older view must not cancel the current view');
c.cancelApplicationCatalog('/phone',next);
assert.equal(c.pendingApplicationCatalog('/phone'),0);
assert.throws(()=>c.saveApplicationCatalog('/phone',{...catalog,request:next}),/stale/);
files.set('/phone/application-request.json',JSON.stringify({request:Date.now()-46000}));
assert.equal(c.pendingApplicationCatalog('/phone'),0,'imports expire without leaving a background request');
assert.deepEqual(plain(c.addApplication([], ' com.example.game ', self)),['com.example.game']);
for(const invalid of ['', 'bad', 'com.a.app com.b.app', 'com.a.app,com.b.app',self]) {
 assert.throws(()=>c.addApplication([],invalid,self));
}
assert.throws(()=>c.addApplication(['com.example.game'],'com.example.game',self),/已经/);
assert.throws(()=>c.addApplication(full,'com.example.extra',self),/63/);
assert.equal(full.length,63);

console.log('Application catalog: validation, atomic cache, stale updates, search, selection, cancellation and limits passed');
