import {chromium} from 'playwright';
import http from 'node:http';import fs from 'node:fs';import assert from 'node:assert/strict';
import {fileURLToPath} from 'node:url';
const root=fileURLToPath(new URL('../app',import.meta.url));
const server=http.createServer((req,res)=>{try{const p=root+(req.url==='/'?'/index.html':req.url.split('?')[0]);res.setHeader('Content-Type',p.endsWith('.css')?'text/css':p.endsWith('.js')?'text/javascript':p.endsWith('.png')?'image/png':'text/html');res.end(fs.readFileSync(p))}catch{res.statusCode=404;res.end()}});await new Promise(r=>server.listen(8922,r));
const browser=await chromium.launch({executablePath:process.env.CHROMIUM||chromium.executablePath()});
const page=await browser.newPage({viewport:{width:390,height:844},hasTouch:true});
const errors=[];page.on('pageerror',e=>errors.push(e.message));await page.goto('http://localhost:8922');
await page.evaluate(async()=>{
 const rate=8000,frames=rate*30,v=new DataView(new ArrayBuffer(44+frames*2));
 const text=(p,s)=>[...s].forEach((c,i)=>v.setUint8(p+i,c.charCodeAt(0)));
 text(0,'RIFF');v.setUint32(4,36+frames*2,true);text(8,'WAVEfmt ');v.setUint32(16,16,true);v.setUint16(20,1,true);v.setUint16(22,1,true);v.setUint32(24,rate,true);v.setUint32(28,rate*2,true);v.setUint16(32,2,true);v.setUint16(34,16,true);text(36,'data');v.setUint32(40,frames*2,true);
 for(let i=0;i<frames;i++)v.setInt16(44+i*2,Math.sin(i*440*2*Math.PI/rate)*6000,true);
 const blob=new Blob([v.buffer],{type:'audio/wav'});
 const a={id:'a',title:'A deliberately long album title for narrow screens',artist:'Test Artist',seq:1,trackCount:2};
 const tracks=[{id:'one',albumId:'a',idx:1,title:'The first track, with a long title',blob},{id:'two',albumId:'a',idx:2,title:'Second track',blob}];
 await dbPut('albums',a);for(const t of tracks)await dbPut('tracks',t);state.albums=[a];state.tracks.set('a',tracks);renderLibrary();switchTab('library');
});
await page.click('#listeningPlay');await page.waitForFunction(()=>!audio.paused&&audio.currentTime>.2);
await page.evaluate(async()=>{audio.currentTime=12;audio.pause();await rememberPosition()});
await page.reload();await page.waitForFunction(()=>state.queue.length===2);
await page.click('#pbPlay');await page.waitForFunction(()=>audio.currentTime>=12&&!audio.paused);
assert(await page.evaluate(()=>audio.currentTime<15));console.log('PASS exact-position resume after reload');
await page.evaluate(()=>switchTab('library'));await page.click('#viewList');assert(await page.locator('#libGrid').evaluate(e=>e.classList.contains('compact')));
await page.waitForTimeout(100);await page.reload();await page.waitForFunction(()=>state.albums.length===1);await page.evaluate(()=>switchTab('library'));assert.equal(await page.locator('#viewList').getAttribute('aria-pressed'),'true');console.log('PASS compact view persists');
await page.click('#libGrid [data-alb]');await page.click('[data-track-menu="two"]');await page.click('#trackPlayNext');
assert.equal(await page.evaluate(()=>state.queue[1].trackId),'two');assert.equal(await page.evaluate(()=>state.queue.length),3);console.log('PASS Play next uses the real queue');
await page.click('[data-track-menu="two"]');await page.click('#trackRename');await page.fill('#trackRenameInput','Renamed track');await page.click('#trackRenameForm button');await page.waitForFunction(()=>document.querySelector('#trackMenuTitle').textContent==='Renamed track');assert.equal(await page.locator('#trackMenuTitle').textContent(),'Renamed track');console.log('PASS track rename persists');
await page.evaluate(()=>{closeSheet('sheetTrack');closeSheet('sheetAlbum');openSheet('sheetNow');openSheet('sheetNow')});assert.equal(await page.evaluate(()=>sheetStack.filter(x=>x==='sheetNow').length),1);console.log('PASS duplicate sheet prevention');
for(const [width,height] of [[390,844],[320,568],[430,932]]){
 await page.setViewportSize({width,height});await page.waitForTimeout(250);
 const layout=await page.evaluate(()=>{const b=document.querySelector('#nowPlay').getBoundingClientRect(),s=document.querySelector('#sheetNow .sheet-body');return{visible:b.top>=0&&b.bottom<=innerHeight,overflow:s.scrollWidth>s.clientWidth+1,queueBottom:document.querySelector('#nowQueue').getBoundingClientRect().bottom,overs:[...s.querySelectorAll('*')].filter(e=>e.getBoundingClientRect().right>s.getBoundingClientRect().right+1).map(e=>e.id||e.className)}});
 assert(layout.visible,`transport visible at ${width}×${height}`);assert(!layout.overflow,`no horizontal overflow at ${width}`);assert(layout.queueBottom<=height,`queue action fits at ${height}: ${layout.queueBottom}`);
 console.log(`PASS player layout ${width}×${height}`);
 if(height>=844){
  await page.evaluate(()=>{document.documentElement.style.setProperty('--safe-t','59px');document.documentElement.style.setProperty('--safe-b','34px')});
  await page.waitForTimeout(100);
  const bottom=await page.locator('#nowQueue').evaluate(e=>e.getBoundingClientRect().bottom);
  assert(bottom<=height-34,`player avoids home indicator at ${height}: ${bottom}`);
  await page.evaluate(()=>{document.documentElement.style.removeProperty('--safe-t');document.documentElement.style.removeProperty('--safe-b')});
  console.log('PASS native safe areas');
 }
}
assert.deepEqual(errors,[]);console.log('PASS no page errors');
if(process.env.AEON_SCREENSHOT){await page.setViewportSize({width:390,height:844});await page.screenshot({path:process.env.AEON_SCREENSHOT})}

await page.evaluate(()=>{closeSheet('sheetNow');switchTab('settings')});
const rounded=await page.evaluate(()=>[...document.querySelectorAll('body *')].filter(e=>e.getBoundingClientRect().width&&getComputedStyle(e).borderTopLeftRadius!=='0px').map(e=>e.id||e.tagName));
assert.deepEqual(rounded,[]);console.log('PASS square borders throughout visible settings');
assert.equal(await page.locator('#panel-settings').evaluate(e=>getComputedStyle(e).backgroundColor),'rgba(180, 186, 197, 0.08)');
assert.equal(await page.locator('#panel-settings h1').evaluate(e=>getComputedStyle(e).color),'rgb(255, 255, 255)');
console.log('PASS cool gray panels and white text');
assert.equal(await page.locator('#fontImport,#fontFile,#fontStatus').count(),0);
assert.equal(await page.locator('#panel-settings').innerText().then(t=>t.includes('Typography')),false);
assert.equal(await page.locator('#activityBtn').innerText(),'Listening activity');
assert.equal(/\p{Extended_Pictographic}/u.test(fs.readFileSync(new URL('../app/index.html',import.meta.url),'utf8')),false);
console.log('PASS typography controls removed and no emoji in app markup');

await page.evaluate(async()=>{
 while(sheetStack.length)closeSheet(sheetStack[sheetStack.length-1]);
 state.queue=[{albumId:'a',trackId:'one'},{albumId:'a',trackId:'two'},{albumId:'a',trackId:'one'}];
 state.qIndex=2;await playCurrent(false);await persistLastPlayedState();
});
await page.reload();await page.waitForFunction(()=>state.queue.length===3);
assert.equal(await page.evaluate(()=>state.qIndex),2);console.log('PASS exact duplicate queue occurrence restores');
await page.click('#pbPlay');await page.waitForFunction(()=>!audio.paused&&audio.currentTime>.15);
await page.evaluate(()=>openQueue());
await page.waitForFunction(()=>document.querySelector("#sheetQueue .sheet-body").getAnimations().every(a=>a.playState==="finished"));
const source=await page.evaluate(()=>audio.src);
let handle=await page.locator('[data-qdrag="2"]').boundingBox(),target=await page.locator('[data-qdrag="0"]').boundingBox();
await page.mouse.move(handle.x+20,handle.y+20);await page.mouse.down();await page.mouse.move(target.x+20,target.y+20,{steps:8});await page.waitForTimeout(60);await page.mouse.up();
assert.equal(await page.evaluate(()=>state.qIndex),0);assert.equal(await page.evaluate(()=>audio.src),source);assert(await page.evaluate(()=>!audio.paused));console.log('PASS drag reorder keeps live audio');
await page.locator('[data-qdrag="0"]').press('ArrowDown');assert.equal(await page.evaluate(()=>state.qIndex),1);console.log('PASS keyboard reorder keeps current occurrence');
await page.click('#qSave');await page.fill('#qName','Saved journey');await page.locator('#qSaveForm button').click();
await page.waitForFunction(()=>state.playlists.some(p=>p.name==='Saved journey'));
assert.deepEqual(await page.evaluate(()=>state.playlists.find(p=>p.name==='Saved journey').items.map(t=>t.trackId)),['one','one','two']);
if(process.env.AEON_SCREENSHOT)await page.screenshot({path:'../build/v4.3-queue.png'});
await page.click('#qClearNext');assert.equal(await page.evaluate(()=>state.queue.length),2);assert.equal(await page.evaluate(()=>state.playlists.find(p=>p.name==='Saved journey').items.length),3);assert(await page.evaluate(()=>!audio.paused));console.log('PASS save queue snapshot and clear upcoming preserve playback');
await page.click('[data-qrm="0"]');assert.equal(await page.evaluate(()=>state.qIndex),0);assert.equal(await page.evaluate(()=>audio.src),source);console.log('PASS removing earlier tracks preserves live audio');
await page.evaluate(()=>{closeSheet('sheetQueue');switchTab('library')});await page.fill('#libSearchIn','Renamed');
await page.waitForFunction(()=>document.querySelectorAll('[data-song-play]').length===1);
assert((await page.locator('#songResultsList').textContent()).includes('Renamed track'));
if(process.env.AEON_SCREENSHOT)await page.screenshot({path:'../build/v4.3-search.png'});
await page.click('[data-song-play="0"]');await page.waitForFunction(()=>loadedTrackId==='two'&&!audio.paused);console.log('PASS song search plays the matching track directly');
await page.fill('#libSearchIn','no-match');await page.click('#libSearchClr');await page.waitForTimeout(200);assert.equal(await page.evaluate(()=>libQuery),'');console.log('PASS clear search cancels pending debounce');
assert.deepEqual(errors,[]);
await page.evaluate(async()=>{await document.fonts.load('32px "Aeon Nocturne"');while(sheetStack.length)closeSheet(sheetStack[sheetStack.length-1]);openSheet('sheetNow');openSheet('sheetQueue')});
assert(await page.evaluate(()=>document.fonts.check('32px "Aeon Nocturne"')));console.log('PASS bundled font loads offline');
assert(await page.evaluate(()=>{const x=document.createElement('canvas').getContext('2d');x.font='64px "Aeon Nocturne"';return x.measureText('OU').width<(x.measureText('O').width+x.measureText('U').width)*.7}));console.log('PASS nested OU ligature is active');
assert.equal(await page.locator('#skyDim').evaluate(e=>getComputedStyle(e).opacity),'0');
assert.equal(await page.locator('#sheetNow').evaluate(e=>getComputedStyle(e).visibility),'hidden');
assert.equal(await page.locator('#sheetQueue .sheet-body').evaluate(e=>getComputedStyle(e).backgroundColor),'rgba(180, 186, 197, 0.08)');
await page.evaluate(()=>closeSheet('sheetQueue'));assert.equal(await page.locator('#sheetNow').evaluate(e=>getComputedStyle(e).visibility),'visible');
console.log('PASS clear silver glass and clean stacked sheets');
assert.deepEqual(errors,[]);
await browser.close();server.close();
