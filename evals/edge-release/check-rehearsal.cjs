// Verify the completed rehearsal's event ledger against independent wire and store observations.
const fs = require('node:fs');
const assert = require('node:assert/strict');
const events = fs.readFileSync(process.argv[2], 'utf8').trim().split('\n').map(line => JSON.parse(line));
const byKind = kind => events.filter(e => e.kind === kind);
const [summary] = byKind('summary');
assert.equal(summary?.profile, 'rehearsal');
assert(summary.elapsedSeconds >= 3600);
assert.equal(summary.invariantFailures, 0);
assert.equal(byKind('invariant_failure').length, 0);
assert.equal(byKind('aborted').length + byKind('safety_stop').length, 0);
assert.equal(byKind('checkpoint').length, summary.cycles);
const waits = byKind('traffic_wait'), exercises = byKind('retention_exercise');
assert.equal(waits.length, Math.floor(summary.cycles / 4));
assert.equal(exercises.length, Math.floor(summary.cycles / 10));
assert(waits.length > 1 && exercises.length > 1);
let failures = 0, bodies = 0, sessions = 0, reports = 0;
const totals = {delivered503: 0, removedBodies: 0, removedSessions: 0};
for (const event of events) {
  switch (event.kind) {
    case 'traffic_wait':
      assert.equal(event.registered, true);
      assert.equal(event.outcome, 'matched');
      assert.equal(event.matched, 1);
      assert.equal(event.delivered503, 4);
      failures += event.delivered503;
      totals.delivered503 += event.delivered503;
      break;
    case 'retention_exercise':
      assert.equal(event.bodyOnly, true);
      assert(event.removedBodies > 0 && event.removedSessions > 0);
      bodies += event.removedBodies;
      sessions += event.removedSessions;
      totals.removedBodies += event.removedBodies;
      totals.removedSessions += event.removedSessions;
      break;
    case 'interval_report':
      assert.equal(event.failureTransitions, failures, 'Failure transitions at cycle ' + event.cycle);
      assert.equal(event.removedBodies, bodies, 'Body removals at cycle ' + event.cycle);
      assert.equal(event.removedSessions, sessions, 'Session removals at cycle ' + event.cycle);
      failures = bodies = sessions = 0;
      reports++;
      break;
  }
}
assert.equal(failures + bodies + sessions, 0);
assert.equal(byKind('user_clear').length, exercises.length);
assert(byKind('user_clear').every(e => e.qualified));
console.log(JSON.stringify({cycles: summary.cycles, seconds: summary.elapsedSeconds, registeredWaits: waits.length,
  intervalReports: reports, retentionExercises: exercises.length, invariantFailures: 0, ...totals}, null, 2));
