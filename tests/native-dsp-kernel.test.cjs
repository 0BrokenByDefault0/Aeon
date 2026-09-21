const {test}=require('node:test');
const assert=require('node:assert/strict');
const {spawnSync}=require('node:child_process');
const {mkdtempSync,rmSync}=require('node:fs');
const {tmpdir}=require('node:os');
const path=require('node:path');
test('production C++ kernel preserves unity and bounds hot multichannel changes', {timeout:600000}, ()=>{
  const directory=mkdtempSync(path.join(tmpdir(),'aeon-dsp-'));
  try {
    const binary=path.join(directory,'kernel');
    const compile=spawnSync('c++',['-std=c++14','-O2','-Wall','-Wextra','tests/native-dsp-kernel.cpp','-o',binary],{encoding:'utf8',timeout:60000});
    assert.equal(compile.status,0,compile.stderr);
    const run=spawnSync(binary,[],{encoding:'utf8',timeout:60000});
    assert.equal(run.status,0,run.stdout+run.stderr);
    console.log(run.stdout.trim());
  } finally { rmSync(directory,{recursive:true,force:true}); }
});
