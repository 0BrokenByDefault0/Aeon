import assert from 'node:assert/strict';
import fs from 'node:fs';
import http from 'node:http';
import path from 'node:path';
import {fileURLToPath} from 'node:url';
import {chromium} from 'playwright';

const here=path.dirname(fileURLToPath(import.meta.url));
const app=path.join(here,'..','app');
const requests=[];
const server=http.createServer((request,response)=>{
  requests.push(request.url);
  if(request.url==='/seed'){
    response.setHeader('content-type','text/html');
    response.end('<!doctype html><title>seed</title>');
    return;
  }
  const relative=request.url==='/'?'legacy-migration.html':request.url.split('?')[0].replace(/^\//,'');
  const file=path.join(app,relative);
  if(!file.startsWith(app+path.sep)||!fs.existsSync(file)){
    response.statusCode=404;response.end();return;
  }
  response.setHeader('content-type',file.endsWith('.js')?'text/javascript':'text/html');
  response.end(fs.readFileSync(file));
});

await new Promise(resolve=>server.listen(0,'127.0.0.1',resolve));
const address=server.address();
const origin=`http://127.0.0.1:${address.port}`;
const browser=await chromium.launch({executablePath:process.env.CHROMIUM||chromium.executablePath()});

function crc32(bytes){
  let crc=0xffffffff;
  for(const byte of bytes){
    crc^=byte;
    for(let bit=0;bit<8;bit++)crc=(crc>>>1)^((crc&1)?0xedb88320:0);
  }
  return (crc^0xffffffff)>>>0;
}

try{
  const context=await browser.newContext();
  const seed=await context.newPage();
  await seed.goto(`${origin}/seed`);
  await seed.evaluate(async()=>{
    await new Promise(resolve=>{
      const request=indexedDB.deleteDatabase('isolation-db');
      request.onsuccess=request.onerror=request.onblocked=resolve;
    });
    const database=await new Promise((resolve,reject)=>{
      const request=indexedDB.open('isolation-db',1);
      request.onupgradeneeded=()=>{
        const db=request.result;
        db.createObjectStore('albums',{keyPath:'id'});
        db.createObjectStore('tracks',{keyPath:'id'});
        db.createObjectStore('playlists',{keyPath:'id'});
        db.createObjectStore('kv',{keyPath:'k'});
      };
      request.onsuccess=()=>resolve(request.result);
      request.onerror=()=>reject(request.error);
    });
    await new Promise((resolve,reject)=>{
      const transaction=database.transaction(['albums','tracks','playlists','kv'],'readwrite');
      const albums=transaction.objectStore('albums');
      albums.put({id:'album-art',title:'Art',art:new Blob(['cover'],{type:'image/jpeg'})});
      albums.put({id:'album-plain',title:'Plain'});
      for(let index=0;index<250;index++)albums.put({id:`bulk-${String(index).padStart(3,'0')}`,title:`Bulk ${index}`});
      transaction.objectStore('tracks').put({
        id:'track-blob',albumId:'album-art',
        blob:new File(['sound'],'01 Signal.flac',{type:'audio/flac'})
      });
      transaction.objectStore('tracks').put({
        id:'track-path',albumId:'album-plain',path:'Music/Artist/Album/01 Path.m4a',bytes:42
      });
      transaction.objectStore('tracks').put({
        id:'track-path-two',albumId:'album-plain',path:'Music/Artist/Album/02 Path.m4a',bytes:84
      });
      transaction.objectStore('playlists').put({id:'playlist-1',name:'Route',items:[]});
      transaction.objectStore('kv').put({k:'settings',v:{metadataLookups:false}});
      transaction.objectStore('kv').put({k:'skySeed',v:17});
      transaction.oncomplete=resolve;
      transaction.onabort=transaction.onerror=()=>reject(transaction.error);
    });
    database.close();
  });
  await seed.close();

  const page=await context.newPage();
  await page.addInitScript(()=>{
    const calls=[];
    const modes=[];
    const mutations=[];
    let deleteCalls=0;
    const transaction=IDBDatabase.prototype.transaction;
    IDBDatabase.prototype.transaction=function(...args){
      modes.push(args[1]||'readonly');
      return transaction.apply(this,args);
    };
    const deleteDatabase=IDBFactory.prototype.deleteDatabase;
    IDBFactory.prototype.deleteDatabase=function(...args){
      deleteCalls++;
      return deleteDatabase.apply(this,args);
    };
    for(const method of ['add','clear','delete','put']){
      const original=IDBObjectStore.prototype[method];
      IDBObjectStore.prototype[method]=function(...args){
        mutations.push(method);
        return original.apply(this,args);
      };
    }
    const record=name=>async payload=>{calls.push({name,payload});return{}};
    const artifactOffsets=new Map();
    const beginArtifact=async payload=>{
      calls.push({name:'beginArtifact',payload});
      const nextOffset=artifactOffsets.get(payload.artifactID)||0;
      return{nextOffset,nextSequence:Math.floor(nextOffset/(512*1024)),complete:false};
    };
    const reportArtifactChunk=async payload=>{
      calls.push({name:'reportArtifactChunk',payload});
      const byteLength=atob(payload.bytesBase64).length;
      const nextOffset=payload.offset+byteLength;
      artifactOffsets.set(payload.artifactID,nextOffset);
      return{nextOffset,nextSequence:payload.sequence+1,complete:false};
    };
    window.migrationContract={calls,modes,mutations,get deleteCalls(){return deleteCalls}};
    window.Capacitor={Plugins:{LegacyMigration:{
      reportInventory:record('reportInventory'),
      reportPage:record('reportPage'),
      finishInventory:record('finishInventory'),
      beginArtifact,
      reportArtifactChunk,
      finishArtifact:record('finishArtifact'),
      reportFailure:record('reportFailure')
    }}};
  });
  await page.goto(`${origin}/legacy-migration.html`);
  await page.waitForFunction(()=>migrationContract.calls.filter(call=>call.name==='finishArtifact').length===2);

  const contract=await page.evaluate(()=>({
    calls:migrationContract.calls,
    modes:migrationContract.modes,
    mutations:migrationContract.mutations,
    deleteCalls:migrationContract.deleteCalls,
    pageSize:AeonLegacyMigration.pageSize,
    chunkSize:AeonLegacyMigration.chunkSize,
    stores:AeonLegacyMigration.stores
  }));
  const inventory=contract.calls.find(call=>call.name==='reportInventory').payload;
  assert.deepEqual(inventory,{
    databaseName:'isolation-db',schemaVersion:1,
    counts:{albums:252,tracks:3,playlists:1,kv:2}
  });
  assert.deepEqual(contract.stores,['albums','tracks','playlists','kv']);
  assert.equal(contract.pageSize,250);
  assert.equal(contract.chunkSize,512*1024);
  assert.equal(contract.deleteCalls,0,'migration never deletes IndexedDB');
  assert.deepEqual(contract.mutations,[],'migration never mutates an object store');
  assert.ok(contract.modes.length>=4);
  assert.ok(contract.modes.every(mode=>mode==='readonly'),'every migration transaction is readonly');
  assert.equal(contract.calls.filter(call=>call.name==='reportFailure').length,0);

  const pages=contract.calls.filter(call=>call.name==='reportPage').map(call=>call.payload);
  assert.ok(pages.every(value=>value.ids.length<=250));
  assert.deepEqual(pages.filter(value=>value.store==='albums').map(value=>value.ids.length),[250,2]);
  for(const store of contract.stores){
    const storePages=pages.filter(value=>value.store===store);
    assert.ok(storePages.at(-1).isLast,`${store} has a final page`);
    assert.deepEqual(storePages.map(value=>value.page),storePages.map((_,index)=>index));
  }
  assert.deepEqual(
    pages.find(value=>value.store==='tracks').ids,
    ['track-blob','track-path','track-path-two']
  );
  assert.deepEqual(
    contract.calls.filter(call=>call.name==='beginArtifact').map(call=>call.payload.artifactID),
    ['artwork:album-art','audio:track-blob'],
    'artwork is materialized before audio'
  );
  const chunks=contract.calls.filter(call=>call.name==='reportArtifactChunk').map(call=>call.payload);
  assert.equal(chunks.length,2);
  assert.ok(chunks.every(value=>atob(value.bytesBase64).length<=512*1024));
  assert.ok(chunks.every(value=>value.crc32===crc32(Buffer.from(value.bytesBase64,'base64'))));
  assert.deepEqual(chunks.map(value=>[value.sequence,value.offset]),[[0,0],[0,0]]);
  assert.deepEqual(
    contract.calls.filter(call=>call.name==='finishArtifact').map(call=>call.payload.byteLength),
    [5,5]
  );
  assert.deepEqual(
    contract.calls.filter(call=>call.name==='finishArtifact').map(call=>call.payload.crc32),
    [crc32(Buffer.from('cover')),crc32(Buffer.from('sound'))]
  );
  const albumRecords=pages.filter(value=>value.store==='albums').flatMap(value=>value.records);
  const trackRecords=pages.find(value=>value.store==='tracks').records;
  assert.equal(albumRecords.find(value=>value.id==='album-art').art,undefined,'artwork bytes are stripped');
  assert.equal(trackRecords.find(value=>value.id==='track-blob').blob,undefined,'audio bytes are stripped');
  assert.deepEqual(trackRecords.find(value=>value.id==='track-path-two'),{
    id:'track-path-two',albumId:'album-plain',path:'Music/Artist/Album/02 Path.m4a',bytes:84
  });
  assert.deepEqual(
    pages.flatMap(value=>value.blobs).map(value=>({
      ownerID:value.ownerID,kind:value.kind,byteLength:value.byteLength,
      mediaType:value.mediaType,fileName:value.fileName
    })),
    [
      {ownerID:'album-art',kind:'artwork',byteLength:5,mediaType:'image/jpeg',fileName:''},
      {ownerID:'track-blob',kind:'audio',byteLength:5,mediaType:'audio/flac',fileName:'01 Signal.flac'}
    ]
  );
  assert.equal(requests.includes('/index.html'),false,'the visible web application was not loaded');
  await context.close();

  console.log('PASS legacy migration bridge inventory contract');
}finally{
  await browser.close();
  await new Promise(resolve=>server.close(resolve));
}
