const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

// Exercise the shipped placement predicate, not a second implementation.
const html = fs.readFileSync(path.join(__dirname, '../app/index.html'), 'utf8');
const predicate = html.match(/const clearOfSky=\(x,y,r\)=>regions\.every\(G=>\{[\s\S]*?\n    \}\);/);
const squash = html.match(/const SQ=([\d.]+);/);
assert.ok(predicate, 'the production world-clearance predicate must be present');
assert.ok(squash, 'the production sky squash must be present');
const SQ = Number(squash[1]);
function clearance(regions) {
  return vm.runInNewContext(`${predicate[0]}\nclearOfSky`, { regions, SQ, Math });
}
const region = { lx: 0, ly: 0, r: 500 };

test('a world cannot overlap a genre name with its lower edge', () => {
  const world = { x: 400, y: -690, r: 150 };
  // This clears the region itself but intersects the existing browser
  // suite's name band. Fractional-radius padding incorrectly allowed it.
  assert.ok(Math.hypot(world.x, world.y) > region.r * 1.12 + world.r + 70);
  const top = region.ly - region.r * SQ;
  assert.ok(Math.abs(world.x - region.lx) < region.r * .9);
  assert.ok(world.y < top + world.r && world.y > top - 110 - world.r);
  assert.equal(clearance([region])(world.x, world.y, world.r), false);
});

test('a world cannot overlap a genre name with its side', () => {
  assert.ok(Math.hypot(600, -500) > region.r * 1.12 + 150 + 70);
  assert.equal(clearance([region])(600, -500, 150), false);
  assert.equal(clearance([region])(-600, -500, 150), false);
});

test('worlds beyond the full name clearance remain eligible', () => {
  const free = clearance([region]);
  assert.equal(free(400, -731, 150), true);
  assert.equal(free(626, -500, 150), true);
  assert.equal(free(-626, -500, 150), true);
});

test('region clearance and empty skies retain their behavior', () => {
  assert.equal(clearance([region])(0, 0, 150), false);
  assert.equal(clearance([region])(0, 779, 150), false);
  assert.equal(clearance([region])(0, 781, 150), true);
  assert.equal(clearance([])(0, 0, 150), true);
});

test('name clearance follows translated regions and checks every region', () => {
  const moved = { lx: 1300, ly: -850, r: 500 };
  for (const regions of [[region, moved], [moved, region]]) {
    assert.equal(clearance(regions)(moved.lx + 400, moved.ly - 690, 150), false);
  }
});

test('accepted placements clear whole world bounds across sizes and positions', () => {
  let accepted = 0;
  for (const size of [152, 500, 1000]) {
    const G = { lx: 127, ly: -83, r: size };
    const free = clearance([G]);
    const top = G.ly - G.r * SQ;
    for (const radius of [124, 150, 187]) {
      for (let dx = -size - 400; dx <= size + 400; dx += 19) {
        for (let dy = -size - 400; dy <= size + 400; dy += 23) {
          const x = G.lx + dx, y = G.ly + dy;
          if (!free(x, y, radius)) continue;
          accepted++;
          assert.ok(Math.hypot(dx, dy) >= G.r + radius);
          const overlapsName = Math.abs(dx) < G.r * .95 + radius
            && y < top + radius && y > top - 130 - radius;
          assert.equal(overlapsName, false,
            JSON.stringify({ region: G, world: { x, y, r: radius } }));
        }
      }
    }
  }
  assert.ok(accepted > 100, 'the guard must still allow usable empty sky');
});
