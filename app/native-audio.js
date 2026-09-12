(function(global){
"use strict";

const EVENT_NAMES=[
  "stateChanged","positionChanged","trackChanged","queueChanged","routeChanged",
  "formatChanged","interruptionChanged","engineRecovered","mediaUnavailable","playbackError"
];
const STATE_EVENTS=new Set([
  "stateChanged","positionChanged","trackChanged","queueChanged","routeChanged",
  "formatChanged","interruptionChanged","engineRecovered"
]);
const cap=global.Capacitor;
const nativePlatform=!!(cap&&cap.isNativePlatform&&cap.isNativePlatform());
let nativePlugin=null;
if(nativePlatform){
  nativePlugin=cap.Plugins&&cap.Plugins.NativeAudio;
  if(!nativePlugin&&cap.registerPlugin&&(!cap.isPluginAvailable||cap.isPluginAvailable("NativeAudio"))){
    nativePlugin=cap.registerPlugin("NativeAudio");
  }
}
const nativeMode=!!nativePlugin;
const subscribers=new Set();
const listenerHandles=[];
let state={version:0};

function backend(){
  if(nativeMode)return nativePlugin;
  const web=global.aeonWebTransport;
  if(!web)throw new Error("Aeon web transport is not installed");
  return web;
}
function acceptSnapshot(snapshot){
  if(!snapshot||!Number.isFinite(snapshot.version))return snapshot;
  if(snapshot.version<state.version)return state;
  state={...state,...snapshot};
  return snapshot;
}
function receive(type,payload){
  if(payload&&Number.isFinite(payload.version)&&payload.version<state.version)return;
  if(STATE_EVENTS.has(type))acceptSnapshot(payload);
  const message={type,state,payload};
  for(const handler of subscribers){
    try{handler(message)}catch(error){setTimeout(()=>{throw error},0)}
  }
}
async function invoke(name,nativeOptions,webArguments=[]){
  const target=backend();
  if(typeof target[name]!=="function")throw new Error(`Aeon ${nativeMode?"native":"web"} transport does not implement ${name}`);
  const result=nativeMode?await target[name](nativeOptions):await target[name](...webArguments);
  if(name!=="getDiagnostics")acceptSnapshot(result);
  return result;
}
function queueOptions(items,index,revision){
  if(items&&!Array.isArray(items)&&typeof items==="object")return items;
  return{items,index,revision};
}

const transport={
  kind:nativeMode?"native":"web",
  get state(){return state},
  initialize(){return invoke("initialize",{},[])},
  load(options){return invoke("load",options||{},[options||{}])},
  play(){return invoke("play",{},[])},
  pause(){return invoke("pause",{},[])},
  toggle(){return invoke("toggle",{},[])},
  seek(seconds){return invoke("seek",{seconds},[seconds])},
  next(){return invoke("next",{},[])},
  previous(){return invoke("previous",{},[])},
  setQueue(items,index,revision){
    const options=queueOptions(items,index,revision);
    return invoke("setQueue",options,[options.items,options.index,options.revision]);
  },
  updateQueue(items,index,revision){
    const options=queueOptions(items,index,revision);
    return invoke("updateQueue",options,[options.items,options.index,options.revision]);
  },
  setVolume(value){return invoke("setVolume",{value},[value])},
  setReplayGainMode(mode){return invoke("setReplayGainMode",{mode},[mode])},
  setReplayGainPreamp(db){return invoke("setReplayGainPreamp",{db},[db])},
  setEQEnabled(enabled){return invoke("setEQEnabled",{enabled},[enabled])},
  setEQBands(bands){return invoke("setEQBands",{bands},[bands])},
  getState(){return invoke("getState",{},[])},
  getDiagnostics(){return invoke("getDiagnostics",{},[])},
  subscribe(handler){
    if(typeof handler!=="function")throw new TypeError("Aeon transport subscriber must be a function");
    subscribers.add(handler);
    return()=>subscribers.delete(handler);
  }
};

if(nativeMode&&typeof nativePlugin.addListener==="function"){
  for(const name of EVENT_NAMES){
    Promise.resolve(nativePlugin.addListener(name,payload=>receive(name,payload)))
      .then(handle=>{if(handle&&typeof handle.remove==="function")listenerHandles.push(handle)})
      .catch(()=>{});
  }
}

global.aeonTransport=transport;
})(window);
