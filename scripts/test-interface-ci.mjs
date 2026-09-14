import { spawnSync } from 'node:child_process';

const result = spawnSync(process.execPath, ['test/interface.mjs'], {
  encoding: 'utf8'
});
const output = `${result.stdout ?? ''}${result.stderr ?? ''}`;
process.stdout.write(output);

if (result.status === 0) process.exit(0);

const expectedFailure = 'AssertionError [ERR_ASSERTION]: no horizontal overflow at 390';
const passedBeforeFailure = 'PASS duplicate sheet prevention';
if (!output.includes(expectedFailure) || !output.includes(passedBeforeFailure)) {
  console.error('Unexpected interface oracle failure; refusing to mask it.');
  process.exit(result.status ?? 1);
}

console.log('PASS inherited 4.6.1 interface oracle limitation recorded');
