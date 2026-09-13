import {spawnSync} from 'node:child_process';

const copy=spawnSync('npx',['--no-install','cap','copy','ios'],{stdio:'inherit'});
if(copy.error)throw copy.error;
if(copy.status!==0)process.exit(copy.status??1);

const requested=process.env.AEON_IOS_SIMULATOR_ID;
let simulatorID=requested;
let simulatorName='requested simulator';

if(!simulatorID){
  const lookup=spawnSync('xcrun',['simctl','list','devices','available','-j'],{encoding:'utf8'});
  if(lookup.status!==0)process.exit(lookup.status??1);
  const runtimes=JSON.parse(lookup.stdout).devices;
  const candidates=Object.entries(runtimes).flatMap(([runtime,devices])=>
    devices.filter(device=>device.isAvailable&&device.name.startsWith('iPhone'))
      .map(device=>({...device,runtime}))
  ).sort((left,right)=>{
    const runtimeOrder=right.runtime.localeCompare(left.runtime,undefined,{numeric:true});
    if(runtimeOrder)return runtimeOrder;
    const leftPro=/ Pro(?: |$)/.test(left.name)?0:1;
    const rightPro=/ Pro(?: |$)/.test(right.name)?0:1;
    return leftPro-rightPro||left.name.localeCompare(right.name,undefined,{numeric:true});
  });
  if(!candidates.length)throw new Error('No available iPhone simulator');
  simulatorID=candidates[0].udid;
  simulatorName=`${candidates[0].name} (${candidates[0].runtime})`;
}

console.log(`Testing on ${simulatorName}`);
const result=spawnSync('xcodebuild',[
  '-workspace','ios/App/App.xcworkspace',
  '-scheme','App',
  '-destination',`platform=iOS Simulator,id=${simulatorID}`,
  'test',
  ...process.argv.slice(2)
],{stdio:'inherit'});

if(result.error)throw result.error;
process.exit(result.status??1);
