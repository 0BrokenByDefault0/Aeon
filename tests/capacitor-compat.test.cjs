const assert = require("node:assert/strict");
const fs = require("node:fs");
const test = require("node:test");

test("patches Capacitor 6's tar import for patched tar 7 and is idempotent", () => {
  const script = "scripts/patch-capacitor-tar.cjs";
  assert.ok(fs.existsSync(script), "the Capacitor tar compatibility patch must exist");
  const { patchSource } = require("../" + script);
  const legacy = [
    'const tar_1 = tslib_1.__importDefault(require("tar"));',
    "async function extractTemplate(src, dir) {",
    "    await tar_1.default.extract({ file: src, cwd: dir });",
    "}",
  ].join("\n");
  const patched = patchSource(legacy);
  assert.match(patched, /const tar_1 = require\("tar"\)/);
  assert.match(patched, /await tar_1\.extract\(/);
  assert.equal(patchSource(patched), patched);
});
