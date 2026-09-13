'use strict';
// A worker that ends — an uncaught error, its own process.exit — with
// threadsafe functions' answers in flight for it. Two ways that took the
// whole process with it:
//
// - An answer's callback still runs, from the ending environment's last loop
//   spin, where every property set fails; node-addon-api, with C++
//   exceptions off, turned that into "FATAL ERROR:
//   Error::ThrowAsJavaScriptException napi_throw" (Node 18). Every such
//   callback asks CALCanCallIntoJS first and drops the answer.
//   notificationSettings is that answer here: in a bare node process (no app
//   bundle) it is queued on the calling thread inside the call, so it is
//   always in flight as the worker ends, and it touches no system state.
//
// - An answer from another thread lands after the environment's teardown.
//   Node without nodejs/node#55877 (18, 20, 22) has freed the function by
//   then, and the call aborted in uv_mutex_lock before any callback ran; Node
//   with it (24.14, 25.4, 26) answered napi_closing, and the release after it
//   was the same abort. Every such answer now goes through CALTsfn, whose
//   environment cleanup hook marks it before the function goes. The calendar
//   reset and read are those answers here: each from a dispatch queue, no
//   grant needed (a read without one answers an error), never a prompt.
//
// Exits 0 when the process outlives every worker.

const { Worker, isMainThread, workerData } = require('worker_threads');

const RUNS = 200;

if (isMainThread) {
  let done = 0;
  const next = () => {
    if (done === RUNS) {
      console.log(`ending-worker OK: ${RUNS} workers ended with answers in flight`);
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
  for (let i = 0; i < 8; i++) {
    native.notificationSettings(() => {});
    native.resetCalendarStore(() => {});
    native.calendars(() => {});
  }
  if (workerData === 'exit') {
    setImmediate(() => process.exit(0));
  } else {
    setImmediate(() => {
      throw new Error('thrown on purpose');
    });
  }
}
