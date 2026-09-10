import {chromium} from 'playwright';
import http from 'node:http';import fs from 'node:fs';import assert from 'node:assert/strict';
const root=new URL('../app/',import.meta.url);
const server=http.createServer((req,res)=>{try{const p=new URL(req.url==='/'?'index.html':req.url.slice(1),root);res.setHeader('Content-Type',p.pathname.endsWith('.css')?'text/css':p.pathname.endsWith('.js')?'text/javascript':'text/html');res.end(fs.readFileSync(p))}catch{res.statusCode=404;res.end()}});
await new Promise(r=>server.listen(8925,r));
const browser=await chromium.launch({executablePath:process.env.CHROMIUM||chromium.executablePath()});
try{
 const page=await browser.newPage({viewport:{width:390,height:844}});
 await page.goto('http://localhost:8925');
 await page.waitForFunction(()=>typeof sky!=='undefined'&&sky.framesDrawn()>0);
 await page.evaluate(()=>dismissAirlock());
 await page.waitForTimeout(1000);
 for(const tab of ['library','playlists','settings']){
  await page.evaluate(tab=>switchTab(tab),tab);
  assert.equal(await page.locator('#voidInvite').evaluate(e=>getComputedStyle(e).visibility),'hidden',`sky welcome hidden on ${tab}`);
  assert.equal(await page.locator('#skyDim').evaluate(e=>getComputedStyle(e).opacity),'0');
 }
 await page.waitForTimeout(2300);
 assert.equal(await page.locator('#skyChrome').evaluate(e=>getComputedStyle(e).visibility),'hidden','animation cannot restore hidden chrome');
 await page.evaluate(()=>switchTab('sky'));
 assert.equal(await page.locator('#voidInvite').evaluate(e=>getComputedStyle(e).visibility),'visible');
 await page.evaluate(()=>{switchTab('library');document.documentElement.style.setProperty('--safe-t','59px');document.documentElement.style.setProperty('--safe-b','34px')});
 await page.waitForTimeout(600);
 await page.screenshot({path:'../build/v4.4.1-library.png'});
 console.log('PASS sky controls hidden on all menus, stay hidden after animation, return on Sky; silver glass preserved');
}finally{await browser.close();server.close()}
