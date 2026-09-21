import {spawnSync} from 'node:child_process';
import {readFileSync,readdirSync} from 'node:fs';
import {enforceValidationBudget} from './validation-budget.mjs';

enforceValidationBudget('native validation including preparation and result collection');

const copy=spawnSync('npx',['--no-install','cap','copy','ios'],{stdio:'inherit'});
if(copy.error)throw copy.error;
if(copy.status!==0)process.exit(copy.status??1);

// npm's test:ios script supplies --family=all before caller arguments. The last
// explicit family must win so focused jobs do not run both device families.
const familyArgument=process.argv.slice(2).filter(value=>value.startsWith('--family=')).pop();
const family=familyArgument?.slice('--family='.length)??process.env.AEON_IOS_DEVICE_FAMILY??'all';
if(!['all','iphone','ipad'].includes(family))throw new Error(`Unsupported simulator family: ${family}`);
const forwardedArguments=process.argv.slice(2).filter(value=>!value.startsWith('--family='));
const requested=process.env.AEON_IOS_SIMULATOR_ID;

const lookup=spawnSync('xcrun',['simctl','list','devices','available','-j'],{encoding:'utf8'});
if(lookup.error)throw lookup.error;
if(lookup.status!==0)process.exit(lookup.status??1);
const runtimes=JSON.parse(lookup.stdout).devices;
const available=Object.entries(runtimes).flatMap(([runtime,devices])=>
  devices.filter(device=>device.isAvailable).map(device=>({...device,runtime}))
);

function rank(left,right){
  const runtimeOrder=right.runtime.localeCompare(left.runtime,undefined,{numeric:true});
  if(runtimeOrder)return runtimeOrder;
  const leftPreferred=/ Pro(?: |$)/.test(left.name)?0:1;
  const rightPreferred=/ Pro(?: |$)/.test(right.name)?0:1;
  const leftLarge=/13-inch|Max/.test(left.name)?0:1;
  const rightLarge=/13-inch|Max/.test(right.name)?0:1;
  return leftPreferred-rightPreferred||leftLarge-rightLarge||left.name.localeCompare(right.name,undefined,{numeric:true});
}

function firstDevice(prefix){
  const candidates=available.filter(device=>device.name.startsWith(prefix)).sort(rank);
  if(!candidates.length)throw new Error(`No available ${prefix} simulator`);
  return candidates[0];
}

function selectedDevice(prefix, identifier){
  if(!identifier)return firstDevice(prefix);
  const device=available.find(value=>value.udid===identifier&&value.name.startsWith(prefix));
  if(!device)throw new Error(`Requested ${prefix} simulator is unavailable: ${identifier}`);
  return device;
}

let destinations;
if(requested){
  const device=available.find(value=>value.udid===requested);
  if(!device)throw new Error(`Requested simulator is unavailable: ${requested}`);
  destinations=[device];
}else if(family==='iphone'){
  destinations=[selectedDevice('iPhone',process.env.AEON_IOS_IPHONE_SIMULATOR_ID)];
}else if(family==='ipad'){
  destinations=[selectedDevice('iPad',process.env.AEON_IOS_IPAD_SIMULATOR_ID)];
}else{
  destinations=[
    selectedDevice('iPhone',process.env.AEON_IOS_IPHONE_SIMULATOR_ID),
    selectedDevice('iPad',process.env.AEON_IOS_IPAD_SIMULATOR_ID)
  ];
}

console.log(`Testing on ${destinations.map(device=>`${device.name} (${device.runtime})`).join(' and ')}`);
const resultBundle=process.env.AEON_IOS_RESULT_BUNDLE_PATH;
const derivedData=process.env.AEON_IOS_DERIVED_DATA_PATH;
const hasExplicitSelection=forwardedArguments.some(value=>
  value.startsWith('-only-testing:')||value.startsWith('-skip-testing:')
);
const uiClasses=readdirSync('ios/App/AppUITests')
  .filter(file=>file.endsWith('.swift'))
  .flatMap(file=>[...readFileSync(`ios/App/AppUITests/${file}`,'utf8').matchAll(/\bclass\s+(\w+Tests)\s*:\s*XCTestCase\b/g)])
  .map(match=>match[1])
  .sort();
const shards=hasExplicitSelection?[{name:'focused',arguments:forwardedArguments}]:[
  {name:'unit',arguments:['-only-testing:AppTests']},
  ...uiClasses.map(name=>({name:`ui-${name.toLowerCase()}`,arguments:[`-only-testing:AppUITests/${name}`]}))
];

function evidencePath(device,shard){
  if(!resultBundle)return undefined;
  const suffix=[
    ...(destinations.length>1?[device.name.startsWith('iPad')?'ipad':'iphone']:[]),
    ...(shards.length>1?[shard.name]:[])
  ].join('-');
  if(!suffix)return resultBundle;
  return resultBundle.endsWith('.xcresult')
    ?`${resultBundle.slice(0,-'.xcresult'.length)}-${suffix}.xcresult`
    :`${resultBundle}-${suffix}.xcresult`;
}

// Every shard runs even after one fails. Stopping at the first failure hides whatever
// is behind it, so a suite with several broken shards takes one full CI round per
// shard to diagnose. The run still fails, just with the whole picture.
const failures=[];
for(const device of destinations){
  for(const shard of shards){
    console.log(`Running ${shard.name} on ${device.name}`);
    const evidence=evidencePath(device,shard);
    const result=spawnSync('xcodebuild',[
      '-workspace','ios/App/App.xcworkspace',
      '-scheme','App',
      '-destination',`platform=iOS Simulator,id=${device.udid}`,
      ...(derivedData?['-derivedDataPath',derivedData]:[]),
      ...(evidence?['-resultBundlePath',evidence]:[]),
      'test',
      '-parallel-testing-enabled', 'NO',
      '-test-timeouts-enabled', 'YES',
      '-default-test-execution-time-allowance', '600',
      '-maximum-test-execution-time-allowance', '600',
      ...shard.arguments
    ],{stdio:'inherit'});
    if(result.error)throw result.error;
    if(result.status!==0)failures.push(`${device.name}: ${shard.name}`);
  }
}

if(failures.length){
  console.error(`\n${failures.length} of ${destinations.length*shards.length} shards failed:`);
  for(const failure of failures)console.error(`  ${failure}`);
  process.exit(1);
}
console.log(`\nAll ${destinations.length*shards.length} shards passed.`);
