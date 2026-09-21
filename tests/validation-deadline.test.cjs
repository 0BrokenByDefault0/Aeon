const {test} = require('node:test');
const assert = require('node:assert/strict');
const {spawnSync} = require('node:child_process');
const {mkdtempSync, readFileSync, rmSync} = require('node:fs');
const {tmpdir} = require('node:os');
const {join} = require('node:path');
const runner = join(__dirname, '../scripts/validation-deadline.py');

test('watchdog preserves failure and kills a TERM-resistant owned descendant at deadline', t => {
  const root = mkdtempSync(join(tmpdir(), 'aeon-deadline-'));
  t.after(() => rmSync(root, {recursive: true, force: true}));
  const report = join(root, 'report.json');
  const failed = spawnSync('python3', [runner, '--stage', 'failure fixture', '--',
    'python3', '-c', 'raise SystemExit(7)'], {encoding: 'utf8', timeout: 5000});
  assert.equal(failed.status, 7);
  // Deliberate deadline fixture, not a timeout of the enclosing validation stage.
  const expired = spawnSync('python3', [runner, '--stage', 'deadline fixture', '--seconds', '0.2',
    '--report', report, '--', 'python3', '-c',
    'import os,signal,time; pid=os.fork(); signal.signal(signal.SIGTERM,signal.SIG_IGN) if pid == 0 else None; time.sleep(60)'],
    {encoding: 'utf8', timeout: 5000});
  assert.equal(expired.status, 124, expired.stderr);
  const evidence = JSON.parse(readFileSync(report));
  assert.equal(evidence.timed_out, true);
  assert(evidence.elapsed_seconds < 4);
  const inherited = spawnSync('python3', [runner, '--stage', 'expired inherited budget', '--',
    'python3', '-c', 'print("MUST NOT START")'], {encoding: 'utf8', timeout: 5000,
    env: {...process.env, AEON_VALIDATION_DEADLINE: '0'}});
  assert.equal(inherited.status, 124);
  assert(!inherited.stdout.startsWith('MUST NOT START'));
});
