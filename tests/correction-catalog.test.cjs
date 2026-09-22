const {test}=require('node:test');
const assert=require('node:assert/strict');
const {readFileSync}=require('node:fs');
const {join}=require('node:path');
const root=join(__dirname,'../ios/App/App/Audio/CorrectionCatalog');
const catalog=JSON.parse(readFileSync(join(root,'profiles.json'),'utf8'));
const records=new Map(JSON.parse(readFileSync(join(root,'source-records.json'),'utf8')).map(x=>[x.path,x.data]));

test('offline catalogue retains every source filter, exact model, preamp and creator', {timeout:10000}, ()=>{
  assert.equal(catalog.version,1);
  assert.equal(catalog.profiles.length,9);
  assert.equal(new Set(catalog.profiles.map(x=>x.profile.id)).size,9);
  for(const entry of catalog.profiles){
    const path=entry.sourceURL.split('/0b88ecd4e2bef7cf69fd5d50f1d06fb586c10865/')[1];
    assert.ok(path,'pinned revision');
    const source=records.get(path);
    assert.ok(source);
    assert.equal(entry.model,records.get(path.split('/eq/')[0]+'/info.json').name);
    assert.equal(entry.creator,source.author);
    assert.equal(entry.target,source.details);
    assert.equal(entry.originalURL,source.link);
    assert.equal(entry.license,'CC BY-SA 4.0');
    assert.equal(entry.profile.preampDB,source.parameters.gain_db);
    assert.equal(entry.profile.bands.length,source.parameters.bands.length);
    assert.ok(entry.profile.bands.length<=10);
    entry.profile.bands.forEach((band,i)=>{
      const original=source.parameters.bands[i];
      assert.deepEqual([band.frequency,band.q,band.gainDB],[original.frequency,original.q,original.gain_db]);
      assert.equal(band.type,{peak_dip:'bell',low_shelf:'lowShelf',high_shelf:'highShelf'}[original.type]);
      assert.equal(band.version,2);
      assert.equal(band.enabled,true);
      assert.ok(band.frequency>=20&&band.frequency<=24000);
      assert.ok(band.q>=0.1&&band.q<=20);
      assert.ok(band.gainDB>=-96&&band.gainDB<=24);
    });
  }
  assert.match(readFileSync(join(root,'LICENSE.md'),'utf8'),/Attribution-ShareAlike 4.0/);
  assert.equal(readFileSync(join(root,'opra-logo.png')).subarray(1,4).toString(),'PNG');
});
