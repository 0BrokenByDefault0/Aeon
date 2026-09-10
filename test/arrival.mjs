import {chromium} from 'playwright';
import http from 'node:http';import fs from 'node:fs';import assert from 'node:assert/strict';
const root=new URL('../app/',import.meta.url);
const server=http.createServer((req,res)=>{try{const p=new URL(req.url==='/'?'index.html':req.url.slice(1),root);res.setHeader('Content-Type',p.pathname.endsWith('.css')?'text/css':p.pathname.endsWith('.js')?'text/javascript':'text/html');res.end(fs.readFileSync(p))}catch{res.statusCode=404;res.end()}});
await new Promise(r=>server.listen(8924,r));
const browser=await chromium.launch({executablePath:process.env.CHROMIUM||chromium.executablePath()});
try{
 const page=await browser.newPage({viewport:{width:390,height:844}});
 const errors=[];page.on('pageerror',e=>errors.push(e.message));
 await page.addInitScript(()=>{window.Capacitor={isNativePlatform:()=>true,convertFileSrc:x=>x,Plugins:{Filesystem:{getUri:async()=>({uri:'file:///Documents/Music'}),mkdir:async()=>{},readdir:async()=>({files:[]})}}}});
 await page.goto('http://localhost:8924');
 assert.equal(await page.locator('#airlock').count(),1,'launch has a spaceship door');
 if(process.env.AEON_CAPTURE)await page.screenshot({path:'../build/v4.2-door.png'});
 await page.waitForFunction(()=>document.querySelector('#airlock').hidden,{timeout:7000});
 console.log('PASS opening door clears itself');
 await page.evaluate(()=>openSheet('sheetImport'));await page.click('#btnImportFolder');
 assert(await page.locator('#sheetFolder').evaluate(e=>e.classList.contains('open')),'native folder button opens usable import route');
 await page.click('#folderScan');await page.waitForFunction(()=>!document.querySelector('#folderScan').disabled);
 assert((await page.locator('#folderStatus').textContent()).includes('No audio'),'empty native folder gives visible result');
 console.log('PASS native folder button, scan and empty status');
 await page.evaluate(()=>{closeSheet('sheetFolder');closeSheet('sheetImport');switchTab('sky');skySeed=11;state.albums=Array.from({length:400},(_,i)=>({id:'world-'+i,title:'Record '+i,artist:'Artist '+(i%16),genre:'Electronic',seq:i+1}));sky.rebuild();const p=sky.worlds()[0];p.x=0;p.y=0;p.r=400;sky.ceremonyPlanet(0)});
 assert.equal(await page.locator('#cvWorld').evaluate(e=>getComputedStyle(e).filter),'none','planets retain color');
 await page.waitForFunction(()=>sky.worlds()[0]?.sprite?.width>=640);
 const worlds=await page.evaluate(()=>sky.worlds().map(p=>({style:p.revealStyle,seed:p.seed})));
 assert.equal(new Set(worlds.map(p=>p.style)).size,8,'eight world reveals');
 console.log('PASS full-color HD world and eight distinct reveal families');
 if(process.env.AEON_CAPTURE){
  await page.evaluate(()=>{sky.worlds().forEach(p=>{p.x=0;p.y=0;p.r=400;p.born=0})});
  await page.waitForFunction(()=>sky.worlds().every(p=>p.sprite?.width>=640));
  const png=await page.evaluate(()=>{const c=document.createElement('canvas');c.width=1280;c.height=2560;const x=c.getContext('2d');x.fillStyle='#000';x.fillRect(0,0,c.width,c.height);sky.worlds().forEach((p,i)=>x.drawImage(p.sprite,i%2*640,Math.floor(i/2)*640,640,640));return c.toDataURL().split(',')[1]});
  fs.writeFileSync('../build/v4.2-worlds.png',Buffer.from(png,'base64'));
 }

 await page.evaluate(()=>{for(const p of sky.worlds())sky.burst(p)});
 assert(await page.evaluate(()=>sky.motes()>0&&sky.motes()<=192));
 await page.waitForTimeout(2800);assert.equal(await page.evaluate(()=>sky.motes()),0);
 console.log('PASS planet effects are bounded and expire');
 assert.deepEqual(errors,[]);console.log('PASS no page errors');
 await page.close();
 const reduced=await browser.newPage({reducedMotion:'reduce'});await reduced.goto('http://localhost:8924');
 await reduced.waitForFunction(()=>document.querySelector('#airlock').hidden,{timeout:3000});
 console.log('PASS reduced-motion arrival');await reduced.close();
 const denied=await browser.newPage();await denied.addInitScript(()=>{window.showDirectoryPicker=async()=>{throw new DOMException('Denied','NotAllowedError')}});await denied.goto('http://localhost:8924');
 await denied.waitForFunction(()=>document.querySelector('#airlock').hidden);await denied.evaluate(()=>openSheet('sheetImport'));await denied.click('#btnImportFolder');
 assert(await denied.locator('#sheetFolder').evaluate(e=>e.classList.contains('open')));
 assert((await denied.locator('#folderStatus').textContent()).includes('Denied'));console.log('PASS folder errors offer recovery');await denied.close();
}finally{await browser.close();server.close()}
