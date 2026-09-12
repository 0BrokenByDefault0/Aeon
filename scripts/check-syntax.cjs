const fs = require("node:fs");
const vm = require("node:vm");

const html = fs.readFileSync("app/index.html", "utf8");
const scripts = [...html.matchAll(/<script(?![^>]*\bsrc\s*=)(?:\s[^>]*)?>([\s\S]*?)<\/script>/gi)];

if (!scripts.length) throw new Error("app/index.html contains no inline JavaScript");

scripts.forEach((match, index) => {
  new vm.Script(match[1], { filename: `app/index.html#script-${index + 1}` });
});
new vm.Script(fs.readFileSync("app/native-audio.js", "utf8"), { filename: "app/native-audio.js" });
new vm.Script(fs.readFileSync("app/sw.js", "utf8"), { filename: "app/sw.js" });

console.log(`JavaScript syntax OK: ${scripts.length} inline script, native adapter, and service worker`);
