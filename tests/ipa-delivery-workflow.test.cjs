const assert = require('node:assert/strict');
const {test} = require('node:test');
const {readFileSync, writeFileSync, mkdirSync, mkdtempSync, rmSync} = require('node:fs');
const {join} = require('node:path');
const {tmpdir} = require('node:os');
const {spawnSync} = require('node:child_process');

const root = join(__dirname, '..');
const workflow = readFileSync(join(root, '.github/workflows/ios-ipa.yml'), 'utf8');
const blocks = workflow.split(/(?=^      - )/m);
function step(name) {
  const block = blocks.find(value => value.startsWith(`      - name: ${name}\n`));
  assert.ok(block, `Missing workflow step: ${name}`);
  return block;
}
function script(name) {
  const body = step(name).split('        run: |\n')[1];
  assert.ok(body, `Missing shell script: ${name}`);
  return body.split('\n').map(line => line.replace(/^          /, '')).join('\n');
}
function fixture(t, overrides = {}) {
  const directory = mkdtempSync(join(tmpdir(), 'aeon-ipa-order-'));
  t.after(() => rmSync(directory, {recursive: true, force: true}));
  const runner = join(directory, 'runner');
  const cwd = join(directory, 'ios', 'App');
  const app = join(runner, 'AeonDerivedData/Build/Products/Release-iphoneos/App.app');
  mkdirSync(app, {recursive: true});
  mkdirSync(cwd, {recursive: true});
  // Only packaging and reporting are exercised here; this is not a device build.
  writeFileSync(join(app, 'App'), 'packaging fixture, not an executable application');
  const env = {
    ...process.env,
    RUNNER_TEMP: runner, GITHUB_WORKSPACE: directory,
    GITHUB_STEP_SUMMARY: join(directory, 'summary.md'),
    GITHUB_SHA: 'fixture-commit', GITHUB_RUN_ID: '123',
    GITHUB_SERVER_URL: 'https://github.com', GITHUB_REPOSITORY: 'example/Aeon',
    AREAS: 'import,library', NATIVE_REQUIRED: 'true', NATIVE_SKIPPED: 'false',
    IPA_URL: 'https://github.com/example/Aeon/actions/runs/123/artifacts/456',
    ...overrides
  };
  return {directory, runner, cwd, env, ipa: join(cwd, 'Aeon-5.0-unsigned.ipa')};
}
function execute(name, context) {
  const result = spawnSync('bash', ['-c', script(name)], {
    cwd: context.cwd, env: context.env, encoding: 'utf8', timeout: 10000
  });
  assert.ifError(result.error);
  assert.equal(result.status, 0, `${name}\n${result.stdout}\n${result.stderr}`);
}

test('cheap checks, device build, packaging, and upload precede native execution', () => {
  const names = ['Run cheap targeted checks', 'Build unsigned app', 'Package and label unsigned IPA', 'Upload fast IPA', 'Publish IPA download link', 'Run focused native validation'];
  const positions = names.map(name => workflow.indexOf(step(name)));
  assert.deepEqual(positions, [...positions].sort((a, b) => a - b));
  // The single bounded native entry point follows artifact publication.
  const early = workflow.slice(0, positions[5]);
  for (const line of early.split('\n').filter(line => line.includes('--tier=native'))) {
    assert.match(line, /--(?:json|list)\b/, 'Pre-upload native routing may only inspect the plan');
  }
  assert.doesNotMatch(early, /(?:npm run test:.*native|node scripts\/test-ios\.mjs|xcodebuild[^\n]*\btest(?:-without-building)?\b)/);
  for (const name of ['Run focused native validation']) {
    assert.match(step(name), /steps\.upload_ipa\.outcome == 'success'/);
  }
});

test('the uploaded IPA is immediately exposed and failures are not suppressed', () => {
  assert.match(step('Upload fast IPA'), /id: upload_ipa/);
  assert.match(step('Upload fast IPA'), /uses: actions\/upload-artifact@v4/);
  assert.match(step('Upload fast IPA'), /if-no-files-found: error/);
  assert.match(step('Publish IPA download link'), /steps\.upload_ipa\.outputs\.artifact-url/);
  assert.doesNotMatch(workflow, /continue-on-error|overwrite:\s*true|delete-artifact/);
  assert.match(step('Run focused native validation'), /exit "\$result"/);
  assert.match(step('Upload focused failure evidence'), /failure\(\) && steps\.native\.outcome == 'failure'/);
  assert.match(workflow, /skip_native:[\s\S]*?default: false/);
});

test('the order regression runs in cheap checks and post-upload reporting runs on failure', () => {
  assert.match(step('Run cheap targeted checks'), /node --test tests\/ipa-delivery-workflow\.test\.cjs/);
  for (const name of ['Report post-upload native validation', 'Upload native validation report']) {
    assert.match(step(name), /always\(\) && steps\.upload_ipa\.outcome == 'success'/);
  }
  assert.match(step('Upload native validation report'), /name: Aeon-fast-native-validation-/);
});

for (const [name, overrides, expected] of [
  ['pending', {}, 'PENDING; runs on one iPhone simulator after IPA upload'],
  ['manual skip', {NATIVE_SKIPPED: 'true'}, 'SKIPPED by manual request'],
  ['configuration only', {NATIVE_REQUIRED: 'false'}, 'NOT REQUIRED for configuration-only change']
]) {
  test(`packaged manifest truthfully labels native validation: ${name}`, t => {
    const context = fixture(t, overrides);
    execute('Package and label unsigned IPA', context);
    const manifest = readFileSync(join(context.runner, 'aeon-fast/Aeon-validation.txt'), 'utf8');
    assert.ok(manifest.includes(`Focused native validation: ${expected}`));
    assert.match(manifest, /Commit: fixture-commit/);
    assert.match(manifest, /Cheap targeted checks: PASSED/);
    assert.match(manifest, /Deep regression matrix: NOT RUN\nPhysical-device acceptance: NOT RUN\nRelease status: ITERATION ONLY/);
    assert.doesNotMatch(manifest, /Focused native validation: PASSED/);
    const embedded = spawnSync('unzip', ['-p', context.ipa, 'Payload/App.app/Aeon-validation.txt'], {encoding: 'utf8'});
    assert.equal(embedded.status, 0, embedded.stderr);
    assert.equal(embedded.stdout, manifest);
  });
}

for (const [outcome, overrides, expected] of [
  ['success', {}, 'PASSED on one iPhone simulator'],
  ['failure', {}, 'FAILED; uploaded IPA remains available for iteration'],
  ['cancelled', {}, 'CANCELLED; uploaded IPA is not native-validated'],
  ['skipped', {}, 'NOT RUN; uploaded IPA is not native-validated'],
  ['skipped', {NATIVE_SKIPPED: 'true'}, 'SKIPPED by manual request'],
  ['skipped', {NATIVE_REQUIRED: 'false'}, 'NOT REQUIRED for configuration-only change']
]) {
  test(`post-upload report records ${expected} without changing the IPA`, t => {
    const context = fixture(t, {...overrides, NATIVE_OUTCOME: outcome});
    execute('Package and label unsigned IPA', context);
    const originalIPA = readFileSync(context.ipa);
    const originalManifest = readFileSync(join(context.runner, 'aeon-fast/Aeon-validation.txt'));
    execute('Report post-upload native validation', context);
    const report = readFileSync(join(context.runner, 'aeon-fast/Aeon-native-validation.txt'), 'utf8');
    assert.ok(report.includes(`Focused native validation: ${expected}`));
    assert.match(report, /Commit: fixture-commit/);
    assert.match(report, /Release status: ITERATION ONLY/);
    assert.ok(report.includes(context.env.IPA_URL));
    assert.deepEqual(readFileSync(context.ipa), originalIPA);
    assert.deepEqual(readFileSync(join(context.runner, 'aeon-fast/Aeon-validation.txt')), originalManifest);
  });
}

test('agent instructions persist IPA delivery before native testing', () => {
  const agents = readFileSync(join(root, 'AGENTS.md'), 'utf8');
  assert.match(agents, /build and upload fast unsigned IPA -> npm run test:targeted:native/);
  assert.match(agents, /Always build and upload the fast unsigned IPA before running native tests/);
  assert.doesNotMatch(agents, /gated by relevant cheap checks and one-family focused native tests/);
});
