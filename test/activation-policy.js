'use strict';
// The activation policy before launch, without the app's code having run
// (windowkit/appkit#64): APPKIT_ACTIVATION_POLICY, read as the app launches,
// and runMain({ activationPolicy }) for a launcher that knows it at startup.
// Each case is a child process, since a launch happens once per process.
// Exits 0 when every expectation held.

const assert = require('assert');
const path = require('path');
const { spawnSync } = require('child_process');

const lib = JSON.stringify(path.join(__dirname, '..'));
const run = (code, env = {}) => {
  const r = spawnSync(process.execPath, ['-e', code], {
    encoding: 'utf8',
    timeout: 20000,
    env: { ...process.env, ...env },
  });
  return { status: r.status, out: (r.stdout || '').trim(), err: r.stderr || '' };
};
// appended to a child's code, which has `native` already
const policies = `
  process.stdout.write(native.activationPolicy() + ' ' + native.appInfo().activationPolicy);
`;

// 1. the variable, read as a bare initApp() launches the app
let r = run(`const { native } = require(${lib}); native.initApp();${policies}`, { APPKIT_ACTIVATION_POLICY: 'accessory' });
assert.strictEqual(r.out, 'accessory accessory', `the environment's policy at launch: ${r.out} ${r.err}`);

// 2. a policy the code says before launch wins over the variable
r = run(`const { native } = require(${lib}); native.initApp({ activationPolicy: 'regular' });${policies}`, { APPKIT_ACTIVATION_POLICY: 'accessory' });
assert.strictEqual(r.out, 'regular regular', `an explicit policy over the environment: ${r.out}`);

// 3. a name nobody knows: said on stderr, the default kept
r = run(`const { native } = require(${lib}); native.initApp();${policies}`, { APPKIT_ACTIVATION_POLICY: 'agent' });
assert.strictEqual(r.out, 'regular regular', `an unknown name launches regular: ${r.out}`);
assert(/APPKIT_ACTIVATION_POLICY=agent/.test(r.err), 'and says so');

// 4. runMain({ activationPolicy }) launches with it; the worker reads it from
// the published state
r = run(`
  const { Worker, isMainThread } = require('worker_threads');
  const { native } = require(${lib});
  new Worker(\`
    const { native } = require(${lib.replace(/\\/g, '\\\\')});
    native.connect(() => {});
    // the launch is runMain's: read once it is running, not while it starts
    for (const t = Date.now(); !native.threaded() && Date.now() - t < 5000; );
    const seen = native.activationPolicy() + ' ' + native.appInfo().activationPolicy;
    require('fs').writeSync(1, seen);
    native.requestExit(seen === 'accessory accessory' ? 0 : 1);
  \`, { eval: true });
  process.exit(native.runMain({ activationPolicy: 'accessory' }) ?? 2);
`);
assert.strictEqual(r.status, 0, `runMain({ activationPolicy }): status ${r.status}, saw '${r.out}' ${r.err}`);
assert.strictEqual(r.out, 'accessory accessory', 'the worker read the policy runMain launched with');

// 5. and an unknown one is a RangeError before anything launches
r = run(`
  const { native } = require(${lib});
  try { native.runMain({ activationPolicy: 'agent' }); process.stdout.write('no error'); }
  catch (e) { process.stdout.write(e.constructor.name); }
`);
assert.strictEqual(r.out, 'RangeError', `runMain with an unknown policy: ${r.out}`);

console.log('activation-policy OK: environment at launch, explicit over environment, unknown name refused, runMain({ activationPolicy })');
