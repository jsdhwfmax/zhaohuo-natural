#requires -Version 5.1
# Dot-sourced only by Build-Release.ps1. All operations here are read-only.
$installer=Import-Module (Resolve-PackageFile 'installer/ZhaoHuoInstaller.psm1') -Force -PassThru
$catalog=& $installer {param($Root) Read-ZHCharacterCatalog $Root} $repo
if($Version-ne $releaseVersion-or $catalog.PackageVersion-ne $Version-or $catalog.RuntimeProtocol-ne 2){throw 'Expected the current seven-character catalog and protocol 2.'}
if(-not $catalog.PackageReady){throw 'PackageReady=false: artwork/runtime is unfinished; no release output is allowed.'}
function Require-True([object]$Value,[string]$Label){if($Value-isnot [bool]-or-not $Value){throw ('Validation missing or failed: '+$Label)}}
$counts=$releaseCounts
$variants=@();$variantFiles=@{};$shared=@();$portraitTotal=0
foreach($file in $catalog.SharedFiles){Require-Hash ($pluginRelative+'/'+$file.Name) $file.Sha256;$shared+=[pscustomobject]@{RelativePath=($pluginRelative+'/'+$file.Name);Sha256=$file.Sha256}}
foreach($character in $catalog.Characters){
    Require-Hash $character.LayoutSourcePath $character.LayoutSha256
    foreach($variant in $character.Variants){
        if($variant.Kind-eq 'original'){continue}
        $key=$character.Id+'/'+$variant.Id
        if(-not $counts.ContainsKey($key)-or $variantFiles.ContainsKey($key)-or @($variant.Files).Count-ne $counts[$key]){throw ('Unexpected variant or count: '+$key)}
        $fallback=@($releaseFallbacks[$character.Id]);$actualFallback=@($variant.OriginalFallback)
        if($actualFallback.Count-ne $fallback.Count-or @($actualFallback|Where-Object{$_-notin $fallback}).Count){throw ('Intentional original-art fallback differs: '+$key)}
        if($frozenV21Fingerprints.ContainsKey($key)-and $variant.AssetFingerprint-ne $frozenV21Fingerprints[$key]){throw ('Previously released v2.1 artwork changed: '+$key)}
        $null=@(& $installer {param($Root,$Character,$Variant) Get-ZHCharacterAssetActions $Root $Character $Variant} $repo $character $variant)
        $map=@{};foreach($file in $variant.Files){$map[$file.Name]=$file.Sha256};$variantFiles[$key]=$map;$portraitTotal+=$map.Count
        $variants+=[ordered]@{CharacterId=$character.Id;Id=$variant.Id;DisplayName=$variant.DisplayName;SourcePath=$variant.SourcePath;PreviewPath=$variant.PreviewPath;PortraitCount=$map.Count;AssetFingerprint=$variant.AssetFingerprint;OriginalFallback=@($variant.OriginalFallback)}
    }
}
if($variants.Count-ne $releaseCustomCount-or $portraitTotal-ne $releasePortraitCount){throw 'Release requires 14 custom appearances, 7 original options and exactly 447 PNGs.'}
# Legacy 141 PNG bytes are frozen. Evaluate their historical complete payload
# fingerprints with the historical shared DLL, never claim it is the new DLL.
foreach($id in @('natural','handsome','xianxia')){
    $entries=@(foreach($name in $variantFiles['player/'+$id].Keys){[pscustomobject]@{RelativePath=($pluginRelative+'/Portraits/'+$name);Sha256=$variantFiles['player/'+$id][$name]}})
    $entries+=@(
        [pscustomobject]@{RelativePath=($pluginRelative+'/ZhaoHuoNatural.dll');Sha256='66F6D545562FDEDF2F5E0CAA1AA8609629A42556C5779DF1C45B61F93EA00095'},
        [pscustomobject]@{RelativePath=($pluginRelative+'/portrait-map.txt');Sha256='844B9A7F73CB2B16DC2F911B18418ADDD4446E9D522D4F7448EFEDD4A614614C'},
        [pscustomobject]@{RelativePath=($pluginRelative+'/portrait-layout.tsv');Sha256='DCE2CDF380008740BC6151F979251F119880605A0C370DB0C0533C088FED011A'}
    )
    if((Payload-Fingerprint $entries)-ne $knownFingerprints[$id]){throw ('Previously released artwork changed: '+$id)}
}
$artPath='verification/character-art-integrity.json';$art=Read-Json $artPath;Require-True $art.Passed 'decoded artwork'
if($art.PortraitCount-ne $releasePortraitCount-or @($art.Variants).Count-ne $releaseCustomCount){throw 'Decoded artwork report is incomplete.'};$seenArt=@{}
foreach($entry in $art.Variants){
    $key=$entry.CharacterId+'/'+$entry.Id;$definition=@($variants|Where-Object{($_.CharacterId+'/'+$_.Id)-eq $key})
    if($definition.Count-ne 1-or $seenArt.ContainsKey($key)-or $entry.SourcePath-ne $definition[0].SourcePath-or $entry.AssetFingerprint-ne $definition[0].AssetFingerprint-or $entry.PortraitCount-ne $definition[0].PortraitCount-or @($entry.Files).Count-ne $entry.PortraitCount){throw ('Artwork identity/count differs: '+$key)};$seenArt[$key]=$true;$seenFiles=@{}
    foreach($file in $entry.Files){if($seenFiles.ContainsKey($file.Name)-or-not $variantFiles[$key].ContainsKey($file.Name)-or $file.Sha256-ne $variantFiles[$key][$file.Name]-or $file.Width-le 0-or $file.Height-le 0-or $file.AlphaMin-ne 0-or $file.AlphaMax-le 0-or $file.AlphaMax-gt 255){throw ('Decoded PNG evidence differs: '+$key+'/'+$file.Name)};$seenFiles[$file.Name]=$true}
}
$managerArtValidation=[ordered]@{Path=$artPath;Sha256=(Hash (Resolve-PackageFile $artPath));PortraitCount=$releasePortraitCount;CustomVariants=$releaseCustomCount;PreservedV21Portraits=400}
$promptValidation=@();$seenPrompts=@{}
foreach($group in $releasePromptGroups){
    $promptPath=$group.Path;$prompts=Read-Json $promptPath;Require-True $prompts.Complete 'image provenance'
    if($prompts.GenerationMethod-ne 'builtin imagegen'-or @($prompts.Assets).Count-ne $group.Count){throw ('Prompt binding count differs: '+$promptPath)}
    foreach($asset in $prompts.Assets){
        $key=$asset.CharacterId+'/'+$asset.VariantId;$name=[IO.Path]::GetFileNameWithoutExtension([string]$asset.Name)+'.png';$identity=$key+'/'+$name
        if($key-notin $group.Variants-or-not $variantFiles.ContainsKey($key)-or-not $variantFiles[$key].ContainsKey($name)-or $seenPrompts.ContainsKey($identity)-or $asset.OutputSHA256-ne $variantFiles[$key][$name]){throw ('Prompt/image binding differs: '+$identity)}
        if(-not ([string]$asset.RecordPath).StartsWith('Prompts/',[StringComparison]::Ordinal)-or-not(Test-Path -LiteralPath (Resolve-PackageFile $asset.RecordPath) -PathType Leaf)){throw 'Actual prompt record must be included in Prompts.'};$seenPrompts[$identity]=$true
    }
    $promptValidation+=@([ordered]@{Path=$promptPath;Sha256=(Hash (Resolve-PackageFile $promptPath));Assets=$group.Count})
}
Require-Hash 'Dependencies/BepInEx/runtime-manifest.json' 'D4C53D568F7254ACC9754405E1EAD03BB9AEE484F3962274AFF3C497A96BA7DC'
Require-Hash 'Loader/winhttp.dll' 'D3B62F4C9C3E2196EF82603C52D6B98C043A0D6C125C081FD33D7CA3798B41B8'
foreach($file in (Read-Json 'Dependencies/BepInEx/runtime-manifest.json').Files){Require-Hash ('Dependencies/BepInEx/files/'+$file.RelativePath) $file.Sha256}
$backendPaths=@('installer/ZhaoHuoInstaller.psm1','installer/AppearanceManager.ps1','installer/VariantSupport.ps1','installer/CharacterCatalog.ps1','installer/CharacterState.ps1','installer/CharacterManager.ps1','installer/CharacterTransactions.ps1','VariantCatalog.json')
$catalogValidation=Assert-CodeReport 'verification/character-catalog-acceptance.json' ($backendPaths+@('Install.ps1','tests/Test-CharacterCatalog.ps1','scripts/CharacterReleaseRules.ps1'))
$managerValidation=Assert-CodeReport 'verification/character-manager-tests.json' ($backendPaths+@('tests/Test-CharacterManager.ps1','Install.ps1')) -AllowHistoricalCatalog
$regressionValidation=Assert-CodeReport 'verification/character-manager-regression.json' ($backendPaths+@('tests/Test-Installer.ps1')) -AllowHistoricalCatalog
if((Read-Json $regressionValidation.Path).assertionCount-ne 74){throw 'The complete 74-assertion installer regression report must pass.'}
$guiValidation=Assert-CodeReport 'verification/character-manager-gui.json' @('installer/Gui.ps1')
$compatibilityValidation=Assert-CodeReport 'verification/compatibility-probe-tests-build25987745.json' @('installer/CompatibilityProbe.ps1','installer/compatibility-baseline.json','installer/compatibility-baseline-25987745.json','Source/Plugin.cs','Source/CharacterPolicy.cs','Source/CharacterSupport.cs','Source/build.ps1')
$configurationValidation=Assert-CodeReport 'verification/character-configuration-parser.json' @('Source/CharacterPolicy.cs','Source/CharacterConfigurationJson.cs','Source/CharacterSupport.cs','Source/build.ps1','Source/Tests/Test-CharacterConfiguration.ps1')
$configuration=Read-Json $configurationValidation.Path
if($configuration.TestCount-lt 195-or $configuration.PassedCount-ne $configuration.TestCount-or @($configuration.Tests).Count-ne $configuration.TestCount-or @($configuration.Tests|Where-Object{$_.Passed-isnot [bool]-or-not $_.Passed}).Count){throw 'The current strict managed configuration parser suite must pass completely, including both protocol versions.'}
$compatibility=Read-Json $compatibilityValidation.Path;$baselinePath='installer/compatibility-baseline.json';$probePath='installer/CompatibilityProbe.ps1';$baseline=Read-Json $baselinePath
$baselinePaths=@('installer/compatibility-baseline.json','installer/compatibility-baseline-25987745.json')
Require-Hash $baselinePath '7BA8D1175F4A9C603B61E81FAF4F42DA5A9A79D14D2EEA3A12C72B04CF6F2A26'
$dll=@($shared|Where-Object RelativePath -eq ($pluginRelative+'/ZhaoHuoNatural.dll'))[0].Sha256
$sharedUpdateValidation=Assert-CodeReport 'verification/character-shared-update.json' (@($backendPaths|Where-Object{$_-ne 'VariantCatalog.json'})+@('tests/Test-CharacterManager.ps1','tests/Test-CharacterSharedUpdate.ps1'))
$sharedUpdate=Read-Json $sharedUpdateValidation.Path
if($sharedUpdate.AssertionCount-ne 13-or @($sharedUpdate.Checks).Count-ne 13-or $sharedUpdate.ProductionTargetDllSha256-ne $dll){throw 'The current shared-DLL revision requires the 13 schema4 update/rollback assertions.'}
$expansionValidation=Assert-CodeReport 'verification/character-expansion-tests.json' (@($backendPaths|Where-Object{$_-ne 'VariantCatalog.json'})+@('tests/Test-CharacterManager.ps1','tests/Test-CharacterExpansion.ps1'))
$expansion=Read-Json $expansionValidation.Path
if($expansion.AssertionCount-lt 30-or @($expansion.Checks).Count-ne $expansion.AssertionCount-or @($expansion.TemporaryFixtureAllowlists).Count){throw 'Expanded protocol migration must pass with the actual frozen resource allowlists.'}
if($compatibility.PluginSha256-ne $dll-or $compatibility.FixedFileCount-ne 395-or $compatibility.GameMemberReferenceCount-ne 23-or @($compatibility.Baselines).Count-ne 2){throw 'Compatibility evidence must bind the unchanged runtime and two complete baselines.'}
if($compatibility.TestCount-lt 23-or @($compatibility.Tests).Count-ne $compatibility.TestCount-or @($compatibility.Tests|Where-Object{$_.Passed-isnot [bool]-or-not $_.Passed}).Count){throw 'The complete dual-baseline probe and generator checks must pass.'}
$compatibilityBaselines=@()
foreach($path in $baselinePaths){
    $entry=@($compatibility.Baselines|Where-Object Path -eq $path);$data=Read-Json $path
    if($entry.Count-ne 1-or $entry[0].Sha256-ne(Hash (Resolve-PackageFile $path))-or $entry[0].FixedFileCount-ne 395-or $entry[0].GameMemberReferenceCount-ne 23-or $data.PluginSha256-ne $dll-or $data.GameMemberReferenceCount-ne 23-or @($data.FixedFiles).Count-ne 395-or (@($entry[0].BuildIds)-join ',')-cne(@($data.BaselineBuildIds)-join ',')){throw ('Complete baseline evidence differs: '+$path)}
    $compatibilityBaselines+=@([ordered]@{Path=$path;Sha256=$entry[0].Sha256;BuildIds=@($entry[0].BuildIds)})
}
$resourcePath='verification/game-resources-build25987745/resource-graph.json';$resources=Read-Json $resourcePath
foreach($field in @('Passed','SourceSharedFileUnchangedDuringInspection','ExistingAllowedMappingsAndSpriteBytesPreserved')){Require-True $resources.$field ('new game resource mapping '+$field)}
if(@($resources.Characters).Count-ne $releaseRoleIds.Count){throw 'Resource mapping evidence must cover all seven roles.'}
$resourceIds=@{};foreach($entry in $resources.Characters){if($entry.CharacterId-notin $releaseRoleIds-or $resourceIds.ContainsKey($entry.CharacterId)){throw 'Unknown/duplicate resource role.'};$resourceIds[$entry.CharacterId]=$true;Require-True $entry.AllowedExistingMappingsPreserved ('existing allowed mappings '+$entry.CharacterId)}
$added=@($resources.AddedMappings)
if($added.Count-ne 1-or $added[0].Expression-ne 'doubt'-or $added[0].CharacterId-ne 'yu-xiaomei'-or $added[0].IdentityId-ne 'girl5'){throw 'Unexpected game mapping addition requires review.'}
Require-True $added[0].OutsideCompiledCanonicalWhitelist 'new doubt portrait deliberately falls back to the original'
$newBaseline=Read-Json 'installer/compatibility-baseline-25987745.json'
$serialized=@($newBaseline.FixedFiles|Where-Object RelativePath -eq 'Mortal_Data/sharedassets2.assets')
if($resources.SourceBuildId-ne $releaseGameBuildId-or $resources.SourceGameVersion-ne $releaseGameVersion-or $resources.PluginSha256-ne $dll-or $resources.SourcePolicySha256-ne(Code-Hash (Resolve-PackageFile 'Source/CharacterPolicy.cs'))-or $serialized.Count-ne 1-or $resources.SharedAssets2Sha256-ne $serialized[0].Sha256){throw 'New game resource mapping evidence differs from the fixed baseline or runtime policy.'}
$fallbackValidation=Assert-CodeReport 'verification/game-resources-build25987745/fallback-policy-tests.json' @('Source/CharacterPolicy.cs','tests/Test-NewGameResourceFallback.ps1')
$fallback=Read-Json $fallbackValidation.Path
if($fallback.PluginSha256-ne $dll-or $fallback.TestCount-ne 11-or @($fallback.Tests).Count-ne 11-or @($fallback.Tests|Where-Object{$_.Passed-isnot [bool]-or-not $_.Passed}).Count){throw 'The new game fallback and alias protection checks must all pass.'}
$gameResourceValidation=[ordered]@{Path=$resourcePath;Sha256=(Hash (Resolve-PackageFile $resourcePath));GameBuildId=$releaseGameBuildId;FallbackPolicyValidation=$fallbackValidation;ActualGameRun=$false}
# Retain v2.1.0 actual execution evidence unchanged and explicitly historical.
# Its frozen catalog describes the unchanged 400 portraits, not the new hardman.
$historicalRuntimePath='verification/character-runtime.json'
Require-Hash $historicalRuntimePath '67A27B8079D7027F12A4132BB38EAE8BBFF80BC256731CADFFA8C2F9476BFF45'
$historicalInstallationPath='verification/character-installation.json'
Require-Hash $historicalInstallationPath '2A3AFBD4A8C0470E23DBB191617C2C65FA9C8CC7189B3B5765BD6C710709DCFC'
function Assert-RuntimeEvidence([string]$Path,[string]$CatalogHash,[string]$BuildId,[string[]]$RequiredVariants){
    $runtime=Read-Json $Path;Require-True $runtime.Passed ('runtime '+$Path);Require-True $runtime.ActualGameRun ('actual game '+$Path)
    if($runtime.PluginSha256-ne $dll-or $runtime.RuntimeVersion-ne $releaseRuntimeVersion-or $runtime.GameBuildId-ne $BuildId-or $runtime.CatalogSha256-ne $CatalogHash-or @($runtime.Characters).Count-ne $releaseRoleIds.Count-or [string]::IsNullOrWhiteSpace($runtime.Scope)){throw ('Runtime identity, version, catalog or character coverage differs: '+$Path)}
    $seen=@{};foreach($entry in $runtime.Characters){if($entry.Id-notin $releaseRoleIds-or $seen.ContainsKey($entry.Id)){throw 'Unknown/duplicate runtime character.'};$seen[$entry.Id]=$true;Require-True $entry.Passed ('runtime '+$entry.Id);Require-True $entry.OriginalDisabled ('original '+$entry.Id);Require-True $entry.NonTargetUnchanged ('isolation '+$entry.Id)}
    $tested=@{};foreach($entry in $runtime.TestedVariants){$key=$entry.CharacterId+'/'+$entry.VariantId;if(-not $counts.ContainsKey($key)-or $tested.ContainsKey($key)){throw 'Unknown/duplicate tested runtime appearance.'};Require-True $entry.Passed ('actual appearance '+$key);$tested[$key]=$true}
    foreach($key in $RequiredVariants){if(-not $tested.ContainsKey($key)){throw ('Actual runtime appearance missing: '+$key)}}
    if(@($runtime.EvidenceFiles).Count-lt 1){throw 'Runtime evidence list is empty.'};$seen=@{}
    foreach($file in $runtime.EvidenceFiles){if($seen.ContainsKey($file.Path)){throw 'Duplicate runtime evidence.'};$seen[$file.Path]=$true;Require-Hash $file.Path $file.Sha256}
    return $runtime
}
$previousRuntimeVariants=@('player/xianxia','tang-buyi/refined','tang-buyi/female','xiahou-lan/refined','tang-moling/refined','long-xiang/refined','yu-xiaomei/refined','tang-zheng/female')
$historicalRuntime=Assert-RuntimeEvidence $historicalRuntimePath '837151A8455BF7618645FFC93532CF54C6BF46504E0A46435698D29C9D91ED3E' '25957922' $previousRuntimeVariants
$historicalRuntimeValidation=[ordered]@{Path=$historicalRuntimePath;Sha256=(Hash (Resolve-PackageFile $historicalRuntimePath));Historical=$true;GameBuildId='25957922';UnchangedPortraits=400;Scope=$historicalRuntime.Scope}
$runtimePath='verification/runtime-build25987745/compatibility-runtime.json'
$runtime=Assert-RuntimeEvidence $runtimePath (Hash (Resolve-PackageFile 'VariantCatalog.json')) $releaseGameBuildId ($previousRuntimeVariants+@('player/hardman'))
if($runtime.GameVersion-ne $releaseGameVersion){throw 'Current runtime evidence must identify release_1.0.6000.3.'}
$normal=$runtime.NormalSteamStartup
foreach($field in @('Passed','StillRunning','Responding','PluginReady')){Require-True $normal.$field ('normal Steam startup '+$field)}
if($normal.SelftestArgumentPresent-isnot [bool]-or $normal.SelftestArgumentPresent-or $normal.ObservedSeconds-lt 90-or $normal.PluginErrorLines-ne 0){throw 'Current normal Steam startup evidence is incomplete.'}
$runtimeValidation=[ordered]@{Path=$runtimePath;Sha256=(Hash (Resolve-PackageFile $runtimePath));GameBuildId=$releaseGameBuildId;RuntimeVersion=$releaseRuntimeVersion;Scope=$runtime.Scope}
$installationValidation=Assert-CodeReport 'verification/character-release-upgrade.json' (@($backendPaths|Where-Object{$_-ne 'VariantCatalog.json'})+@('tests/Test-CharacterManager.ps1','tests/Test-CharacterReleaseUpgrade.ps1'))
$installation=Read-Json $installationValidation.Path
if($installation.ExecutionMode-ne 'IsolatedPreviousReleaseInstallation'-or $installation.FromVersion-ne '2.1.0'-or $installation.ToVersion-ne $Version-or $installation.RuntimeVersion-ne $releaseRuntimeVersion-or $installation.RuntimeProtocol-ne 2-or $installation.ProductionPluginSha256-ne $dll-or $installation.ActualGameRun-isnot [bool]-or $installation.ActualGameRun-or $installation.AssertionCount-lt 19-or @($installation.Checks).Count-ne $installation.AssertionCount){throw 'Release upgrade must be genuinely tested from the previous installer with isolated fixtures.'}
foreach($field in @('InitialInstallationPreserved','OriginalBackupsPreserved','OtherPluginsPreserved','AllExistingSelectionsPreserved')){Require-True $installation.$field $field}
$historicalInstallationValidation=[ordered]@{Path=$historicalInstallationPath;Sha256=(Hash (Resolve-PackageFile $historicalInstallationPath));Historical=$true;Scope='Original v2.1.0 installation acceptance, preserved without relabeling its source hashes as current.'}
