'use strict';
// A worker that ends — an uncaught error, its own process.exit — with a
// threadsafe function's answer queued for it. The answer's callback still
// runs, from the ending environment's last loop spin, where every property
// set fails; node-addon-api, with C++ exceptions off, turned that into
// "FATAL ERROR: Error::ThrowAsJavaScriptException napi_throw" and took the
// whole process with it (Node 18). Every such callback now asks
// CALCanCallIntoJS first and drops the answer. Exits 0 when the process
// outlives every worker.
//
// notificationSettings is the answer queued here: in a bare node process
// (no app bundle) it is queued on the calling thread inside the call, so it
// is always in flight as the worker ends, and it touches no system state.
// The answers that come from a framework's own thread (the calendar reads
// and writes, the permission requests) take the same guard, but on Node 18
// that thread's call can land after the ending worker has freed the
// function — a separate crash, not exercised here.

const { Worker, isMainThread, workerData } = require('worker_threads');

const RUNS = 200;

if (isMainThread) {
  let done = 0;
  const next = () => {
    if (done === RUNS) {
      console.log(`ending-worker OK: ${RUNS} workers ended with an answer in flight`);
      return;
    }
    const w = new Worker(__filename, { workerData: done % 2 ? 'exit' : 'throw' });
    w.on('error', () => {}); // the 'throw' workers'; the process living on is what is checked
    w.on('exit', () => {
      done++;
      next();
    });
  };
  next();
} else {
  const { native } = require('..');
  for (let i = 0; i < 8; i++) native.notificationSettings(() => {});
  if (workerData === 'exit') {
    setImmediate(() => process.exit(0));
  } else {
    setImmediate(() => {
      throw new Error('thrown on purpose');
    });
  }
}
