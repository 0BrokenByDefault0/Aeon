import {spawnSync} from 'node:child_process';
import {fileURLToPath} from 'node:url';

// Every public validation entry point gets a watchdog before setup starts.
// Nested runners inherit the parent's deadline; they cannot renew its budget.
export function enforceValidationBudget(stage) {
  if (process.env.AEON_VALIDATION_DEADLINE) return;
  const watchdog = fileURLToPath(new URL('./validation-deadline.py', import.meta.url));
  const result = spawnSync('python3', [watchdog, '--stage', stage, '--', process.execPath,
    ...process.argv.slice(1)], {stdio: 'inherit', env: process.env});
  if (result.error) throw result.error;
  process.exit(result.status ?? 1);
}
