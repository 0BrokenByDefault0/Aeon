import {readFileSync, readdirSync} from 'node:fs';

// A UI case owns a fresh simulator invocation and its own 600-second deadline.
// Build once; do not spend every case's budget recompiling the app.
const selectors = ['AppTests'];
for (const file of readdirSync('ios/App/AppUITests').filter(name => name.endsWith('.swift')).sort()) {
  const source = readFileSync(`ios/App/AppUITests/${file}`, 'utf8');
  const type = source.match(/\bclass\s+(\w+)\s*:\s*XCTestCase\b/)?.[1];
  if (!type) continue;
  for (const match of source.matchAll(/\bfunc\s+(test\w+)\s*\(/g)) {
    selectors.push(`AppUITests/${type}/${match[1]}`);
  }
}
console.log(JSON.stringify({include: ['iphone', 'ipad'].flatMap(family =>
  selectors.map((selector, index) => ({family, selector, shard: `${family}-${index}`}))
)}));
