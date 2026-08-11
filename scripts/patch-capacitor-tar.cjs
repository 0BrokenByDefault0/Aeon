const fs = require("node:fs");
const path = require("node:path");

const legacyImport = 'const tar_1 = tslib_1.__importDefault(require("tar"));';
const patchedImport = 'const tar_1 = require("tar");';
const legacyCall = "await tar_1.default.extract(";
const patchedCall = "await tar_1.extract(";

function patchSource(source) {
  if (source.includes(patchedImport) && source.includes(patchedCall)) return source;
  if (!source.includes(legacyImport) || !source.includes(legacyCall)) {
    throw new Error("Unsupported @capacitor/cli template loader; review the tar compatibility patch");
  }
  return source.replace(legacyImport, patchedImport).replace(legacyCall, patchedCall);
}

function main() {
  const target = path.join(
    process.cwd(),
    "node_modules",
    "@capacitor",
    "cli",
    "dist",
    "util",
    "template.js",
  );
  const source = fs.readFileSync(target, "utf8");
  const patched = patchSource(source);
  if (patched !== source) fs.writeFileSync(target, patched);
}

if (require.main === module) main();

module.exports = { patchSource };
