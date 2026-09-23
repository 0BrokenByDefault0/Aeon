import {spawnSync} from 'node:child_process';
import {enforceValidationBudget} from './validation-budget.mjs';

const areaNames=['import','playback','library','sky','chrome','playlists','settings'];

const routes={
  import:{
    cheap:[['node','--test','tests/capacitor-compat.test.cjs']],
    native:['LibraryImporterTests','AudioTagReaderTests','MetadataEnricherTests','MetadataProbeTests','ImportPickerTests','ImportedFolderStoreTests','ArchiveCompatibilityTests','ImportPickerPresentationTests']
  },
  playback:{
    cheap:[['node','--test','tests/playback.test.cjs','tests/native-dsp-kernel.test.cjs','tests/correction-catalog.test.cjs']],
    native:['ParametricDSPTests','PlaybackModelsTests','PlaybackCoordinatorTests','PlaybackControllerTests','PlaybackStateStoreTests','QueueSchedulerTests','QueueControllerTests','AudioSessionPolicyTests','AudioEngineGraphTests','AudioIntegrationTests','RecoveryTests','ReplayGainAndEQTests','SpectrumAnalyzerTests','PlayerNavigationTests','PlaybackFlowTests']
  },
  library:{
    cheap:[['node','--test','tests/aeon-core.test.cjs']],
    native:['CatalogDatabaseTests','CatalogRepositoryTests','LibraryControllerTests','LibraryFlowTests']
  },
  sky:{
    cheap:[['node','--test','tests/sky-world-clearance.test.cjs']],
    native:['SkyComposerTests','SkyCameraTests','SkyHitTestingTests','PlanetModelTests','SkyInteractionTests']
  },
  chrome:{
    cheap:[],
    native:['DesignTokenTests','AdaptiveChromeTests','AeonAccessibilityTests','AeonScreenMatrixTests']
  },
  playlists:{
    cheap:[['node','--test','tests/aeon-core.test.cjs']],
    native:['PlaylistTests','CatalogRepositoryTests','LibraryFlowTests','SettingsFlowTests']
  },
  settings:{
    cheap:[],
    native:['DesignTokenTests','CatalogRepositoryTests','SettingsFlowTests']
  }
};

const pathRules=[
  [/^tests\/screen-isolation\.test\.cjs$/,['playback','chrome']],
  [/^ios\/App\/AppTests\/CorrectionCatalogTests\.swift$/,['playback']],
  [/^ios\/App\/AppUITests\/PlaybackFlowTests\.swift$/,['playback','chrome']],
  [/^ios\/App\/AppTests\/(QueueScheduler|QueueController|AudioIntegration|AudioEngineGraph|ParametricDSP|PlaybackModels|PlaybackCoordinator|DesignToken)Tests\.swift$/,['playback']],
  [/^ios\/App\/AppTests\/(PlanetModel|SkyCamera|SkyComposer|SkyHitTesting)Tests\.swift$/,['sky']],
  [/^ios\/App\/AppUITests\/SkyInteractionTests\.swift$/,['sky']],
  [/^ios\/App\/App\/Import\//,['import']],
  [/^ios\/App\/App\/Migration\//,['import','library']],
  [/^ios\/App\/App\/(Audio|Playback)\//,['playback']],
  [/^ios\/App\/App\/Features\/Player\//,['playback']],
  [/^ios\/App\/App\/Features\/Library\//,['library']],
  [/^ios\/App\/App\/(Persistence|Domain)\//,['library','playlists']],
  [/^ios\/App\/App\/(Sky|Features\/Sky)\//,['sky']],
  [/^ios\/App\/App\/(DesignSystem|Features\/Root)\//,['chrome']],
  [/^ios\/App\/App\/Features\/Playlists\//,['playlists']],
  [/^ios\/App\/App\/Features\/Settings\//,['settings']],
  [/^tests\/playback\.test\.cjs$/,['playback']],
  [/^tests\/sky-world-clearance\.test\.cjs$/,['sky']],
  [/^tests\/capacitor-compat\.test\.cjs$/,['import']],
  [/^tests\/aeon-core\.test\.cjs$/,['library','playlists']],
  [/^test\/native-audio-contract\.mjs$/,['playback']],
  [/^test\/legacy-migration-contract\.mjs$/,['import','library']],
  [/^test\/sky-chrome\.mjs$/,['sky','chrome']],
  [/^app\//,areaNames]
];

function values(name,args){
  return args.flatMap((value,index)=>value===`--${name}`?[args[index+1]]:value.startsWith(`--${name}=`)?[value.slice(name.length+3)]:[]).filter(Boolean);
}

function changedFiles(base){
  const result=spawnSync('git',['diff','--name-only',`${base}...HEAD`],{encoding:'utf8'});
  if(result.error)throw result.error;
  if(result.status!==0)throw new Error(result.stderr.trim()||`git diff failed for ${base}`);
  return result.stdout.split('\n').filter(Boolean);
}

function selectAreas(files){
  const selected=new Set();
  let broad=false;
  for(const file of files){
    let matched=false;
    for(const [pattern,areas] of pathRules){
      if(!pattern.test(file))continue;
      matched=true;
      for(const area of areas)selected.add(area);
    }
    if(file==='ios/App/App.xcodeproj/project.pbxproj' && files.some(path=>/^ios\/App\/App\/(Audio|Features\/Player)\//.test(path)))matched=true;
    if(!matched&&(/^(ios\/|package(?:-lock)?\.json$|capacitor\.config\.json$)/.test(file)))broad=true;
    if(/^scripts\/(?!test-targeted\.mjs$|test-ios\.mjs$|validation-(?:budget\.mjs|deadline\.py)$)/.test(file))broad=true;
  }
  return broad?areaNames:[...selected];
}

function uniqueCommands(commands){
  const seen=new Set();
  return commands.filter(command=>{
    const key=JSON.stringify(command);
    if(seen.has(key))return false;
    seen.add(key);
    return true;
  });
}

function plan(args){
  const explicit=values('area',args).flatMap(value=>value.split(',')).map(value=>value.trim()).filter(Boolean);
  for(const area of explicit)if(!areaNames.includes(area))throw new Error(`Unknown area: ${area}`);
  const files=[...values('file',args)];
  const bases=values('changed-from',args);
  if(bases.length>1)throw new Error('Use only one --changed-from value');
  if(bases[0])files.push(...changedFiles(bases[0]));
  const areas=explicit.length?[...new Set(explicit)]:selectAreas(files);
  const tier=values('tier',args).at(-1)||'cheap';
  if(!['cheap','native'].includes(tier))throw new Error(`Unknown tier: ${tier}`);
  const family=values('family',args).at(-1)||'iphone';
  if(!['iphone','ipad','all'].includes(family))throw new Error(`Unsupported simulator family: ${family}`);
  const configOnly=areas.length===0;
  const dspIteration=files.some(file=>/^ios\/App\/App\/Audio\/(ParametricDSP\.swift|AeonDSPAudioUnit\.mm|AeonDSPKernel\.hpp)$/.test(file));
  // This corrective DSP iteration also requires Sky coexistence/material evidence,
  // including a compile replacement whose previous push has not delivered an IPA.
  if(dspIteration&&!areas.includes('sky'))areas.push('sky');
  const focusedDSP=['ParametricDSPTests','AudioEngineGraphTests','PlaybackModelsTests','QueueSchedulerTests','QueueControllerTests','PlaybackCoordinatorTests'];
  const profilePlayerIteration=!explicit.length&&!dspIteration&&files.includes('ios/App/App/Audio/CorrectionCatalog.swift')&&areas.every(area=>['playback','chrome','library'].includes(area));
  const profilePlayerTests={
    playback:['CorrectionCatalogTests','ParametricDSPTests','PlaybackCoordinatorTests','PlaybackModelsTests','PlaybackFlowTests/testSongMenuCreatesPlaylistAndMiniPlayerSurvivesSheetsAndTabs','PlaybackFlowTests/testBundledCorrectionRequiresExactSelectionAndPreviewBeforeApplying'],
    library:['PlaylistTests'],
    chrome:['DesignTokenTests','PlayerNavigationTests']
  };
  const modalPlayerFiles=['Audio/QueueScheduler.swift','Audio/PlaybackCoordinator.swift','Audio/DiagnosticsLog.swift','Features/Player/PlayerBar.swift','Features/Player/NowPlayingView.swift','Features/Player/QueueView.swift','Features/Root/AeonRootView.swift','Features/Library/AlbumDetailView.swift'];
  const modalPlayerIteration=!explicit.length&&(files.includes('ios/App/App/Features/Player/PlayerBar.swift')||files.includes('ios/App/App/Features/Player/NowPlayingView.swift')||files.includes('tests/screen-isolation.test.cjs'))&&
    areas.every(area=>['playback','chrome','library'].includes(area))&&
    files.filter(file=>file.startsWith('ios/App/App/')).every(file=>modalPlayerFiles.includes(file.slice('ios/App/App/'.length)));
  const modalPlayerTests=['DesignTokenTests','PlaylistTests',
    ...((files.includes('ios/App/App/Features/Player/NowPlayingView.swift')||files.includes('ios/App/App/Features/Player/PlayerBar.swift')||files.includes('tests/screen-isolation.test.cjs'))?['PlaybackFlowTests/testFullPlayerFillsViewportAndRestoresCompactBar']:[]),
    ...(files.some(file=>file.startsWith('ios/App/App/Audio/'))?['AudioEngineGraphTests','PlaybackCoordinatorTests','QueueSchedulerTests','PlaybackStateStoreTests']:[]),
    'PlaybackFlowTests/testSongMenuCreatesPlaylistAndMiniPlayerSurvivesSheetsAndTabs',
    'PlaybackFlowTests/testBundledCorrectionRequiresExactSelectionAndPreviewBeforeApplying'];
  const startupFiles=['AppContainer.swift','Audio/AudioEngineGraph.swift','Audio/PlaybackCoordinator.swift'];
  const startupIteration=!explicit.length&&files.includes('ios/App/App/AppContainer.swift')&&
    files.filter(file=>file.startsWith('ios/App/App/')).every(file=>startupFiles.includes(file.slice('ios/App/App/'.length)));
  const startupTests=['AppContainerTests','AudioEngineGraphTests','PlaybackCoordinatorTests','SpectrumAnalyzerTests','RecoveryTests','PlaybackFlowTests/testFullPlayerFillsViewportAndRestoresCompactBar'];
  const skyLabelPlayerFiles=['Features/Sky/SkyScreen.swift','Features/Player/PlayerBar.swift'];
  const skyLabelPlayerIteration=!explicit.length&&files.includes('ios/App/App/Features/Sky/SkyScreen.swift')&&
    files.includes('ios/App/App/Features/Player/PlayerBar.swift')&&
    files.filter(file=>file.startsWith('ios/App/App/')).every(file=>skyLabelPlayerFiles.includes(file.slice('ios/App/App/'.length)));
  const skyLabelPlayerTests=['SkyCameraTests','SkyComposerTests','DesignTokenTests','PlaybackFlowTests/testFullPlayerFillsViewportAndRestoresCompactBar'];
  const nativeFor=area=>skyLabelPlayerIteration?skyLabelPlayerTests:startupIteration?startupTests:modalPlayerIteration?modalPlayerTests:profilePlayerIteration?profilePlayerTests[area]:area==='playback'&&dspIteration?focusedDSP:routes[area].native;
  const commands=tier==='cheap'
    ?uniqueCommands([
      ['npm','run','check'],
      ['node','--test','tests/validation-deadline.test.cjs','tests/ios-test-runner.test.cjs','tests/targeted-tests.test.cjs'],
      ...(configOnly?[["node","--test","tests/ios-test-runner.test.cjs","tests/targeted-tests.test.cjs"]]:areas.flatMap(area=>routes[area].cheap))
    ])
    :areas.length?[['node','scripts/test-ios.mjs',`--family=${family}`,...new Set(areas.flatMap(nativeFor).map(name=>`-only-testing:${['ImportPickerPresentationTests','PlayerNavigationTests','PlaybackFlowTests','LibraryFlowTests','SkyInteractionTests','AdaptiveChromeTests','AeonAccessibilityTests','AeonScreenMatrixTests','SettingsFlowTests'].includes(name.split('/')[0])?'AppUITests':'AppTests'}/${name}`))]]:[];
  return{areas,files,tier,family,configOnly,commands};
}

function display(command){
  return command.map(value=>/[\s"']/.test(value)?JSON.stringify(value):value).join(' ');
}

const args=process.argv.slice(2);
let selected;
try{selected=plan(args)}catch(error){console.error(error.message);process.exit(2)}

if(args.includes('--json')){
  console.log(JSON.stringify(selected));
  process.exit(0);
}

console.log(`Targeted areas: ${selected.areas.join(', ')||'configuration only'}`);
console.log(`Tier: ${selected.tier}${selected.tier==='native'?` (${selected.family})`:''}`);
for(const command of selected.commands)console.log(`  ${display(command)}`);
if(args.includes('--list'))process.exit(0);

enforceValidationBudget(`${selected.tier} targeted validation`);

for(const command of selected.commands){
  const result=spawnSync(command[0],command.slice(1),{stdio:'inherit',env:process.env});
  if(result.error)throw result.error;
  if(result.status!==0)process.exit(result.status??1);
}
