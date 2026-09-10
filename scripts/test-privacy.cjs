#!/usr/bin/env node
// Exercise the real non-UI ArkTS entry points, with network APIs instrumented.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const clt = process.env.HARMONY_CLT_HOME;
if (!clt) throw new Error('Set HARMONY_CLT_HOME');
const ts = require(path.join(clt, 'sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript'));
const root = path.resolve(__dirname, '../app/entry/src/main/ets');
const files = new Map();
const calls = { vpn: 0, connection: 0, native: 0, probe: 0, listener: 0, background: 0, stop: 0 };
let failWrite = false;
const io = {
  OpenMode: { CREATE: 1, WRITE_ONLY: 2, TRUNC: 4 },
  readTextSync: p => { if (!files.has(p)) throw new Error('ENOENT'); return files.get(p); },
  openSync: p => ({ fd: p }),
  writeSync: (p, value) => { if (failWrite) throw new Error('EIO'); files.set(p, value); },
  closeSync: () => {},
  renameSync: (p, target) => { files.set(target, files.get(p)); files.delete(p); }
};
class Ability {
  context = { filesDir: '/app', abilityInfo: { bundleName: 'com.linloir.hrevtether' },
    terminateSelf: async () => {}, moveAbilityToBackground: async () => {} };
}
const modules = {
  '@kit.AbilityKit': { UIAbility: Ability },
  '@kit.CoreFileKit': { fileIo: io },
  '@kit.PerformanceAnalysisKit': { hilog: { info() {}, error() {}, warn() {} } },
  '@kit.NetworkKit': {
    VpnExtensionAbility: Ability,
    vpnExtension: {
      startVpnExtensionAbility: async want => { calls.vpn++; calls.want = want; },
      stopVpnExtensionAbility: async () => { calls.stop++; },
      createVpnConnection: () => { calls.connection++; throw new Error('instrumented'); }
    }
  },
  '@kit.BackgroundTasksKit': { backgroundTaskManager: {
    requestSuspendDelay: () => { calls.background++; return { requestId: 1, actualDelayTime: 20000 }; },
    cancelSuspendDelay: () => {}
  } },
  'libtether.so': { default: { newSession: () => { calls.native++; return 1; }, stop() {} } }
};
const cache = new Map();
function load(relative) {
  const filename = path.resolve(root, relative);
  if (cache.has(filename)) return cache.get(filename);
  const context = { exports: {}, require: name => {
    if (modules[name]) return modules[name];
    if (name === './NetworkProbe') return {
      parseRequest: () => ({ request_id: 'test' }),
      ProbeRun: class { run() { calls.probe++; return Promise.resolve({}); } cancel() {} }
    };
    if (name === './ProbeResultServer') return {
      probeResultServer: { begin: async () => { calls.listener++; }, finish() {}, end() {} }
    };
    return load(path.relative(root, path.resolve(path.dirname(filename), name + '.ets')));
  }, Date, Number, JSON, String, Error, setTimeout: () => 1, setInterval: () => 1,
  clearTimeout() {}, clearInterval() {} };
  const output = ts.transpileModule(fs.readFileSync(filename, 'utf8'), {
    compilerOptions: { target: ts.ScriptTarget.ES2021, module: ts.ModuleKind.CommonJS }
  }).outputText;
  vm.runInNewContext(output, context, { filename });
  cache.set(filename, context.exports);
  return context.exports;
}

async function main() {
  const { hasPrivacyConsent, acceptPrivacy } = load('common/PrivacyConsent.ets');
  const { PRIVACY_VERSION } = load('common/PrivacyContent.ets');
  const Entry = load('entryability/EntryAbility.ets').default;
  const Vpn = load('vpn/TetherVpnAbility.ets').default;
  const Probe = load('probe/ProbeAbility.ets').default;
  const request = { parameters: { command: 'start', port: '41419', dns: '10.0.0.3' } };
  for (const record of [undefined, '', 'broken JSON', 'null', '{}',
    JSON.stringify({ version: 'old', acceptedAt: Date.now() }),
    JSON.stringify({ version: PRIVACY_VERSION, acceptedAt: 'today' }),
    JSON.stringify({ version: PRIVACY_VERSION, acceptedAt: 0 })]) {
    files.clear();
    if (record !== undefined) files.set('/app/privacy-consent.json', record);
    assert.equal(hasPrivacyConsent('/app'), false);
    const entry = new Entry();
    entry.onCreate(request);
    entry.onNewWant(request);
    new Vpn().onCreate(request);
    const probe = new Probe();
    probe.onCreate({ parameters: { request: '{}' } });
    probe.onNewWant({ parameters: { request: '{}' } });
  }
  assert.deepEqual(calls, { vpn: 0, connection: 0, native: 0, probe: 0, listener: 0, background: 0, stop: 0 });
  files.clear();
  failWrite = true;
  assert.throws(() => acceptPrivacy('/app'), /EIO/);
  assert.equal(hasPrivacyConsent('/app'), false);
  failWrite = false;
  acceptPrivacy('/app');
  assert.equal(hasPrivacyConsent('/app'), true);
  assert.equal(files.has('/app/privacy-consent.json.tmp'), false);
  // Consent alone does not trigger any network action.
  assert.equal(calls.vpn + calls.probe, 0);
  new Entry().onCreate(request);
  assert.equal(calls.vpn, 1);
  assert.equal(calls.want.parameters.port, '41419');
  assert.equal(calls.want.parameters.dns, '10.0.0.3');
  const probe = new Probe();
  probe.onCreate({ parameters: { request: '{}' } });
  await new Promise(resolve => setImmediate(resolve));
  assert.equal(calls.probe, 1);
  assert.equal(calls.listener, 1);
  // Stops remain available without consent, and a later start rechecks storage.
  files.clear();
  new Entry().onCreate({ parameters: { command: 'stop' } });
  new Entry().onNewWant(request);
  assert.equal(calls.stop, 1);
  assert.equal(calls.vpn, 1);
  assert.equal(hasPrivacyConsent('/app'), false);
  console.log('Privacy persistence, denied entry points, host parameters and post-consent actions: PASS');
}
main().catch(error => { console.error(error); process.exitCode = 1; });
