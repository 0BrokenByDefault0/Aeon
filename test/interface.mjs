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
assert.equal(await page.locator('#panel-settings').evaluate(e=>getComputedStyle(e).backgroundColor),'rgba(180, 186, 197, 0.98)');
assert.equal(await page.locator('#panel-settings h1').evaluate(e=>getComputedStyle(e).color),'rgb(255, 255, 255)');
console.log('PASS cool gray panels and white text');
await page.setInputFiles('#fontFile',{name:'invalid.otf',mimeType:'font/otf',buffer:Buffer.from('not a font')});
await page.waitForFunction(()=>document.querySelector('#fontStatus').textContent.includes("Couldn't load"));
assert.equal(await page.evaluate(async()=>!!await kvGet('arthemysFont')),false);console.log('PASS invalid font does not persist');
if(process.env.AEON_TEST_FONT){
 await page.setInputFiles('#fontFile',process.env.AEON_TEST_FONT);
 await page.waitForFunction(()=>document.querySelector('#fontStatus').textContent.startsWith('Arthemys active'));
 assert(await page.evaluate(()=>document.fonts.check('16px AeonArthemys')));
 await page.reload();await page.waitForFunction(()=>document.querySelector('#fontStatus').textContent.startsWith('Arthemys active'));
 assert(await page.evaluate(()=>document.fonts.check('16px AeonArthemys')));
 console.log('PASS valid font loads and restores after restart (test fixture, not bundled Arthemys)');
}
await browser.close();server.close();
