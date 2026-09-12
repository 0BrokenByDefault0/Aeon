import assert from 'node:assert/strict';
import {fileURLToPath} from 'node:url';
import {chromium} from 'playwright';

const adapterPath=fileURLToPath(new URL('../app/native-audio.js',import.meta.url));
const eventNames=[
  'stateChanged','positionChanged','trackChanged','queueChanged','routeChanged',
  'formatChanged','interruptionChanged','engineRecovered','mediaUnavailable','playbackError'
];

const browser=await chromium.launch({executablePath:process.env.CHROMIUM||chromium.executablePath()});
try{
  const native=await browser.newPage();
  await native.addInitScript(names=>{
    const calls=[],listeners={};
    const plugin={
      addListener:async(name,handler)=>{
        (listeners[name]??=[]).push(handler);
        return{remove:async()=>{listeners[name]=(listeners[name]||[]).filter(value=>value!==handler)}};
      }
    };
    for(const name of [
      'initialize','load','play','pause','toggle','seek','next','previous','setQueue','updateQueue',
      'setVolume','setReplayGainMode','setReplayGainPreamp','setEQEnabled','setEQBands','getState','getDiagnostics'
    ])plugin[name]=async options=>{calls.push({name,options});return name==='getDiagnostics'?{entries:[]}:{version:1,intent:'paused'}};
    window.nativeContract={calls,listeners,names,webReads:0};
    Object.defineProperty(window,'aeonWebTransport',{get(){window.nativeContract.webReads++;return null}});
    window.Capacitor={isNativePlatform:()=>true,Plugins:{NativeAudio:plugin}};
  },eventNames);
  await native.goto('data:text/html,<html></html>');
  await native.addScriptTag({path:adapterPath});

  assert.equal(await native.evaluate(()=>aeonTransport.kind),'native');
  assert.equal(await native.evaluate(()=>nativeContract.webReads),0,'native mode never reads the web transport');
  assert.deepEqual(await native.evaluate(()=>Object.keys(nativeContract.listeners).sort()),eventNames.slice().sort());

  await native.evaluate(()=>aeonTransport.play());
  assert.deepEqual(await native.evaluate(()=>nativeContract.calls.at(-1)),{name:'play',options:{}});
  await native.evaluate(()=>aeonTransport.seek(17.25));
  assert.deepEqual(await native.evaluate(()=>nativeContract.calls.at(-1)),{name:'seek',options:{seconds:17.25}});
  await native.evaluate(()=>aeonTransport.setQueue([{trackID:'A'}],0,8));
  assert.deepEqual(await native.evaluate(()=>nativeContract.calls.at(-1)),{
    name:'setQueue',options:{items:[{trackID:'A'}],index:0,revision:8}
  });

  await native.evaluate(()=>{
    for(const handler of nativeContract.listeners.stateChanged)handler({version:9,trackID:'new'});
    for(const handler of nativeContract.listeners.stateChanged)handler({version:8,trackID:'old'});
  });
  assert.equal(await native.evaluate(()=>aeonTransport.state.trackID),'new');
  assert.equal(await native.evaluate(()=>aeonTransport.state.version),9);
  await native.close();

  const web=await browser.newPage();
  await web.addInitScript(()=>{
    const calls=[];
    window.webContract={calls};
    window.Capacitor={isNativePlatform:()=>false,Plugins:{}};
    window.aeonWebTransport={play:async()=>{calls.push('play');return{version:2,intent:'playing'}}};
  });
  await web.goto('data:text/html,<html></html>');
  await web.addScriptTag({path:adapterPath});
  assert.equal(await web.evaluate(()=>aeonTransport.kind),'web');
  await web.evaluate(()=>aeonTransport.play());
  assert.deepEqual(await web.evaluate(()=>webContract.calls),['play']);
  await web.close();

  console.log('PASS native audio bridge contract');
}finally{
  await browser.close();
}
