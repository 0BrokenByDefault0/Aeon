const {test}=require('node:test');
const assert=require('node:assert/strict');
const vm=require('node:vm');
const fs=require('node:fs');
const html=fs.readFileSync('app/index.html','utf8');
function player(){
  const nodes=new Map(),events={};
  class Audio {
    constructor(){this.src='';this.paused=true;this.currentTime=0;this.duration=100;this.listeners={};this.volume=1;this.playCalls=0;}
    addEventListener(n,f){(this.listeners[n]??=[]).push(f)}
    removeEventListener(n,f){this.listeners[n]=(this.listeners[n]||[]).filter(x=>x!==f)}
    fire(n){for(const f of this.listeners[n]||[])f({target:this})}
    play(){this.playCalls++;if(!this.src)return Promise.reject({name:'NotSupportedError'});this.paused=false;this.fire('play');return Promise.resolve()}
    pause(){if(!this.paused){this.paused=true;this.fire('pause')}}
    getAttribute(){return this.src}
    removeAttribute(){this.src=''}
    load(){}
  }
  class Context {
    constructor(){this.state='running';this.destination={};this.resumes=0}
    createMediaElementSource(){return {connect(){},disconnect(){}}}
    createBiquadFilter(){return {connect(){},frequency:{},Q:{},gain:{}}}
    createAnalyser(){return {connect(){},frequencyBinCount:16}}
    createGain(){return {connect(){},gain:{}}}
    resume(){this.resumes++;this.state='running';return Promise.resolve()}
    suspend(){this.state='suspended';return Promise.resolve()}
    close(){this.state='closed';return Promise.resolve()}
  }
  const albums=[{id:'a',title:'Album',artist:'Artist'}];
  const tracks=[{id:'1',title:'One',path:'one.mp3'},{id:'2',title:'Two',path:'two.mp3'},{id:'mock',title:'Mock'}];
  const state={queue:[{albumId:'a',trackId:'1'},{albumId:'a',trackId:'2'}],qIndex:0,settings:{eqGains:Array(10).fill(0),volume:.9,repeat:'off'}};
  const c=vm.createContext({Audio,window:{AudioContext:Context},state,URL:{revokeObjectURL(){}},NATIVE:false,
    document:{hidden:false,addEventListener(n,f){events[n]=f},body:{classList:{remove(){}}}},
    addEventListener(n,f){events[n]=f},navigator:{},setTimeout,clearTimeout,Uint8Array,console,
    $:s=>{if(!nodes.has(s))nodes.set(s,{classList:{add(){},remove(){},contains(){return false}},style:{}});return nodes.get(s)},
    albumById:id=>albums.find(a=>a.id===id),trackById:(a,id)=>tracks.find(t=>t.id===id),hasAudio:t=>!!t?.path,
    trackURLSync:t=>'file:'+t.path,trackURL:async t=>'file:'+t.path,
    updatePlayerUI(){},syncPlayGlyphs(){},sky:{focusAlbum(){}},kvSet:async()=>{},dbDel:async()=>{},
    toast:m=>c.messages.push(m),messages:[],clamp:(x,a,b)=>Math.max(a,Math.min(b,x)),saveSettings(){},fmtT:String});
  const start=html.search(/(?:const|let) audio=new Audio\(\);/);
  vm.runInContext(html.slice(start,html.indexOf('function markPlayingCard()',start)),c);
  c.run=s=>vm.runInContext(s,c);return c;
}
test('restored queue starts a real source on the first Play',async()=>{
  const c=player();c.run('togglePlay()');await Promise.resolve();
  assert.equal(c.run('audio.src'),'file:one.mp3');assert.equal(c.run('audio.paused'),false);
});
test('latest track wins when file lookups finish out of order',async()=>{
  const c=player(),resolve={};c.trackURLSync=()=>null;c.trackURL=t=>new Promise(r=>resolve[t.id]=r);
  const first=c.run('playCurrent(true)');c.state.qIndex=1;const second=c.run('playCurrent(true)');
  resolve['2']('file:two.mp3');await second;resolve['1']('file:one.mp3');await first;
  assert.equal(c.run('audio.src'),'file:two.mp3');
});
test('clearing playback cancels an in-flight file lookup',async()=>{
  const c=player();let resolve;c.trackURLSync=()=>null;c.trackURL=()=>new Promise(r=>resolve=r);
  const loading=c.run('playCurrent(true)');c.run('clearPlaybackSource()');resolve('file:one.mp3');await loading;
  assert.equal(c.run('audio.src'),'');assert.equal(c.run('audio.paused'),true);
});
test('a mock selection stops the previous audible track',async()=>{
  const c=player();await c.run('playCurrent(true)');c.state.queue=[{albumId:'a',trackId:'mock'}];
  await c.run('playCurrent(true)');assert.equal(c.run('audio.paused'),true);
});
test('an interrupted context is resumed by the Play button',async()=>{
  const c=player();await c.run('playCurrent(false)');c.run('actx.state="interrupted";togglePlay()');await Promise.resolve();
  assert.equal(c.run('actx.state'),'running');assert.equal(c.run('actx.resumes'),1);
});
test('an external pause clears every pending start',()=>{
  const c=player();c.run('audio.src="file:one.mp3";pendingStart={token:loadToken};audio.fire("pause");audio.fire("canplay")');
  assert.equal(c.run('audio.playCalls'),0);
});
test('native paths encode #, ?, percent signs and non-ASCII names',()=>{
  const c=vm.createContext({NATIVE:true,Capacitor:{convertFileSrc:s=>s},URL:{}});
  const a=html.indexOf('function trackURLSync(t){'),b=html.indexOf('async function trackURL(t)',a);
  vm.runInContext('const docsBase="file:///Documents";'+html.slice(a,b),c);
  const url=vm.runInContext('trackURLSync({path:"Music/100%/01 #why? café.mp3"})',c);
  assert.equal(url,'file:///Documents/Music/100%25/01%20%23why%3F%20caf%C3%A9.mp3');
});
test('a closed audio engine is replaced without losing position or listeners',async()=>{
  const c=player();await c.run('playCurrent(false)');c.run('audio.currentTime=42;actx.state="closed";togglePlay()');
  c.run('audio.fire("loadedmetadata")');await Promise.resolve();
  assert.equal(c.run('audio.currentTime'),42);assert.equal(c.run('audio.paused'),false);
  c.run('pendingStart={token:loadToken};audio.fire("pause")');assert.equal(c.run('pendingStart'),null);
});
test('a failed context recovery stops silent playback and permits a fresh retry',async()=>{
  const c=player();await c.run('playCurrent(true)');
  c.run('actx.state="suspended";actx.resume=()=>Promise.reject(new Error("interrupted"));resumeAudioContext()');
  await new Promise(r=>setImmediate(r));
  assert.equal(c.run('audio.paused'),true);assert.equal(c.run('actx'),null);
  c.run('togglePlay()');await Promise.resolve();assert.equal(c.run('audio.paused'),false);
});
