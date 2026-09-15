import {chromium} from 'playwright';
import fs from 'node:fs';
const f = n => fs.readFileSync('/tmp/fonts/'+n).toString('base64');
const css = `
@font-face{font-family:"Clash";src:url("data:font/ttf;base64,${f('ClashDisplay-Semibold.ttf')}")}
@font-face{font-family:"ClashM";src:url("data:font/ttf;base64,${f('ClashDisplay-Medium.ttf')}")}
@font-face{font-family:"Sw";font-weight:400;src:url("data:font/ttf;base64,${f('Switzer-Regular.ttf')}")}
@font-face{font-family:"Sw";font-weight:500;src:url("data:font/ttf;base64,${f('Switzer-Medium.ttf')}")}
@font-face{font-family:"Sw";font-weight:600;src:url("data:font/ttf;base64,${f('Switzer-Semibold.ttf')}")}
@font-face{font-family:"Ar";src:url("data:font/ttf;base64,${f('Archivo.ttf')}")}`;
const screen = (title, kicker, display, note) => `
<div class="phone">
  <div class="kick">${kicker}</div>
  <div class="title" style="font-family:'${display}'">${title}</div>
  <div class="sub">0 ALBUMS</div>
  <div class="sec">PLAYBACK</div>
  <div class="opt"><div><div class="h3">Sleep timer</div><div class="body">Fades out, then stops.</div></div></div>
  <div class="chips"><span class="chip on">OFF</span><span class="chip">15 MIN</span><span class="chip">30 MIN</span></div>
  <div class="opt"><div><div class="h3">One import, one album</div><div class="body">Files picked together stay together.</div></div></div>
  <div class="big" style="font-family:'${display}'">Your sky is quiet</div>
  <div class="note">${note}</div>
</div>`;
const html = `<style>${css}
body{background:#000;margin:0;padding:24px;display:flex;gap:26px;font-family:'Sw',system-ui;color:#fff}
.phone{width:390px;border:1px solid #ffffff18;border-radius:28px;padding:26px}
.kick{font:600 10px 'Sw';letter-spacing:.22em;color:#ffffff70;text-transform:uppercase}
.title{font-size:44px;letter-spacing:-0.025em;margin-top:14px;line-height:1.02}
.sub{font:600 10px 'Sw';letter-spacing:.22em;color:#ffffff70;margin-top:12px}
.sec{font:600 10px 'Sw';letter-spacing:.22em;color:#ffffff70;margin-top:34px}
.opt{padding:16px 0;border-bottom:1px solid #ffffff12}
.h3{font:600 15px 'Sw';letter-spacing:-0.008em}
.body{font:400 12.5px 'Sw';color:#ffffff73;margin-top:5px;line-height:1.45}
.chips{display:flex;gap:8px;margin:14px 0 4px}
.chip{font:600 10px 'Sw';letter-spacing:.18em;padding:9px 14px;border-radius:99px;border:1px solid #ffffff14;color:#ffffff73}
.chip.on{background:#fff;color:#000;border-color:#fff}
.big{font-size:30px;letter-spacing:-0.022em;margin-top:40px;text-align:center}
.note{font:600 9px 'Sw';letter-spacing:.2em;color:#ffffff40;margin-top:26px;text-transform:uppercase}
</style>
${screen('Settings','AEON / PREFERENCES','Clash','Clash Display Semibold + Switzer')}
${screen('Settings','AEON / PREFERENCES','ClashM','Clash Display Medium + Switzer')}
${screen('Settings','AEON / PREFERENCES','Ar','current: Archivo expanded')}`;
const b = await chromium.launch();
const p = await b.newPage({viewport:{width:1360,height:900},deviceScaleFactor:2});
await p.setContent(html); await p.waitForTimeout(1200);
await p.screenshot({path:'/tmp/fonts/pairing.png',fullPage:true});
await b.close(); console.log('ok');
