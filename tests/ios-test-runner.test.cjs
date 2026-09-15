const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');

const runner = path.resolve(__dirname, '../scripts/test-ios.mjs');
const selection = '-only-testing:AppUITests/FixtureTests';

// Exercise the real runner and its arguments without requiring Xcode. Only the
// external commands are replaced; no simulator or native-test success is implied.
function run(t, args = [], overrides = {}) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'aeon-ios-runner-'));
  t.after(() => fs.rmSync(root, { recursive: true, force: true }));
  const bin = path.join(root, 'bin');
  const uiTests = path.join(root, 'ios/App/AppUITests');
  fs.mkdirSync(bin);
  fs.mkdirSync(uiTests, { recursive: true });
  fs.writeFileSync(path.join(uiTests, 'FixtureTests.swift'),
    'final class FixtureTests: XCTestCase {}\n');
  const log = path.join(root, 'commands.jsonl');
  const command = `#!/usr/bin/env node
const fs = require('node:fs');
const name = require('node:path').basename(process.argv[1]);
if (name === 'xcrun') {
  console.log(JSON.stringify({ devices: { 'com.apple.CoreSimulator.SimRuntime.iOS-18-0': [
    { name: 'iPhone Test', udid: 'phone-id', isAvailable: true },
    { name: 'iPad Test', udid: 'pad-id', isAvailable: true }
  ] } }));
} else if (name === 'xcodebuild') {
  fs.appendFileSync(process.env.AEON_TEST_COMMAND_LOG,
    JSON.stringify(process.argv.slice(2)) + '\\n');
  process.exit(Number(process.env.AEON_TEST_XCODE_EXIT || '0'));
}
`;
  for (const name of ['npx', 'xcrun', 'xcodebuild']) {
    fs.writeFileSync(path.join(bin, name), command, { mode: 0o755 });
  }
  const env = { ...process.env };
  for (const key of Object.keys(env)) {
    if (key.startsWith('AEON_IOS_') || key.startsWith('AEON_TEST_')) delete env[key];
  }
  const result = spawnSync(process.execPath, [runner, ...args], {
    cwd: root,
    env: {
      ...env,
      PATH: `${bin}${path.delimiter}${path.dirname(process.execPath)}${path.delimiter}${env.PATH || ''}`,
      AEON_TEST_COMMAND_LOG: log,
      ...overrides
    },
    encoding: 'utf8',
    timeout: 10000
  });
  assert.ifError(result.error);
  const commands = fs.existsSync(log)
    ? fs.readFileSync(log, 'utf8').trim().split('\n').map(line => JSON.parse(line))
    : [];
  return { ...result, commands };
}

function destinations(result) {
  return result.commands.map(args => args[args.indexOf('-destination') + 1]);
}

const phone = 'platform=iOS Simulator,id=phone-id';
const pad = 'platform=iOS Simulator,id=pad-id';

for (const args of [[], ['--family=all']]) {
  test(`full run retains both families and every shard: ${args.join(' ') || 'default'}`, t => {
    const result = run(t, args);
    assert.equal(result.status, 0, result.stderr);
    assert.deepEqual(destinations(result), [phone, phone, pad, pad]);
    assert.deepEqual(result.commands.map(args => args.filter(arg => arg.startsWith('-only-testing:'))),
      [['-only-testing:AppTests'], [selection], ['-only-testing:AppTests'], [selection]]);
  });
}

for (const [family, destination] of [['iphone', phone], ['ipad', pad]]) {
  test(`appended ${family} selection overrides npm's --family=all`, t => {
    const result = run(t, ['--family=all', `--family=${family}`, selection], {
      AEON_IOS_RESULT_BUNDLE_PATH: '/tmp/aeon-test/result.xcresult'
    });
    assert.equal(result.status, 0, result.stderr);
    assert.deepEqual(destinations(result), [destination]);
    const args = result.commands[0];
    assert(args.includes(selection));
    assert(!args.some(arg => arg.startsWith('--family=')));
    assert.equal(args[args.indexOf('-resultBundlePath') + 1], '/tmp/aeon-test/result.xcresult');
  });
}

test('invalid appended family fails instead of silently running all devices', t => {
  const result = run(t, ['--family=all', '--family=watch', selection]);
  assert.notEqual(result.status, 0);
  assert.match(result.stderr, /Unsupported simulator family: watch/);
  assert.deepEqual(result.commands, []);
});

test('environment family is used without a command-line family', t => {
  const result = run(t, [selection], { AEON_IOS_DEVICE_FAMILY: 'ipad' });
  assert.equal(result.status, 0, result.stderr);
  assert.deepEqual(destinations(result), [pad]);
});

test('explicit family takes precedence over environment family', t => {
  const result = run(t, ['--family=iphone', selection], { AEON_IOS_DEVICE_FAMILY: 'ipad' });
  assert.equal(result.status, 0, result.stderr);
  assert.deepEqual(destinations(result), [phone]);
});

test('failed native commands still fail the run and do not skip remaining shards', t => {
  const result = run(t, ['--family=all'], { AEON_TEST_XCODE_EXIT: '65' });
  assert.equal(result.status, 1);
  assert.deepEqual(destinations(result), [phone, phone, pad, pad]);
  assert.match(result.stderr, /4 of 4 shards failed/);
});
