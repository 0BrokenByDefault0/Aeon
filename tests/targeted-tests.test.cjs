const test=require('node:test');
const assert=require('node:assert/strict');
const path=require('node:path');
const {spawnSync}=require('node:child_process');

const script=path.resolve(__dirname,'../scripts/test-targeted.mjs');

function plan(...args){
  const result=spawnSync(process.execPath,[script,...args,'--json'],{encoding:'utf8'});
  assert.equal(result.status,0,result.stderr);
  return JSON.parse(result.stdout);
}

test('routes production paths to the responsible areas',()=>{
  const result=plan(
    '--file=ios/App/App/Import/LibraryImporter.swift',
    '--file=ios/App/App/Features/Library/LibraryScreen.swift'
  );
  assert.deepEqual(result.areas,['import','library']);
  assert(result.commands.some(command=>command.includes('tests/capacitor-compat.test.cjs')));
  assert(result.commands.some(command=>command.includes('tests/aeon-core.test.cjs')));
});

test('deduplicates native selectors across areas and defaults to one iPhone',()=>{
  const result=plan('--area=library','--area=playlists','--tier=native');
  assert.equal(result.family,'iphone');
  assert.equal(result.commands.length,1);
  const selectors=result.commands[0].filter(value=>value.startsWith('-only-testing:'));
  assert.equal(selectors.length,new Set(selectors).size);
  assert(selectors.includes('-only-testing:AppTests/CatalogRepositoryTests'));
  assert(selectors.includes('-only-testing:AppUITests/LibraryFlowTests'));
});

test('shared native infrastructure safely routes to every area',()=>{
  const result=plan('--file=ios/App/App/AeonApp.swift');
  assert.deepEqual(result.areas,['import','playback','library','sky','chrome','playlists','settings']);
});

test('documentation-only changes use configuration checks and no native simulator',()=>{
  const cheap=plan('--file=docs/development-workflow.md');
  assert.equal(cheap.configOnly,true);
  assert(cheap.commands[1].includes('tests/targeted-tests.test.cjs'));
  const native=plan('--file=docs/development-workflow.md','--tier=native');
  assert.deepEqual(native.commands,[]);
});

test('rejects unknown areas',()=>{
  const result=spawnSync(process.execPath,[script,'--area=unknown','--json'],{encoding:'utf8'});
  assert.equal(result.status,2);
  assert.match(result.stderr,/Unknown area/);
});
