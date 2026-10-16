#requires -Version 5.1
# Dot-sourced only by Build-Release.ps1. All operations here are read-only.
$installer=Import-Module (Resolve-PackageFile 'installer/ZhaoHuoInstaller.psm1') -Force -PassThru
$catalog=& $installer {param($Root) Read-ZHCharacterCatalog $Root} $repo
if($Version-ne $releaseVersion-or $catalog.PackageVersion-ne $Version-or $catalog.RuntimeProtocol-ne 2){throw 'Expected the v2.1.0 seven-character catalog and protocol 2.'}
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
        if($frozenV20Fingerprints.ContainsKey($key)-and $variant.AssetFingerprint-ne $frozenV20Fingerprints[$key]){throw ('Previously released v2.0 artwork changed: '+$key)}
        $null=@(& $installer {param($Root,$Character,$Variant) Get-ZHCharacterAssetActions $Root $Character $Variant} $repo $character $variant)
        $map=@{};foreach($file in $variant.Files){$map[$file.Name]=$file.Sha256};$variantFiles[$key]=$map;$portraitTotal+=$map.Count
        $variants+=[ordered]@{CharacterId=$character.Id;Id=$variant.Id;DisplayName=$variant.DisplayName;SourcePath=$variant.SourcePath;PreviewPath=$variant.PreviewPath;PortraitCount=$map.Count;AssetFingerprint=$variant.AssetFingerprint;OriginalFallback=@($variant.OriginalFallback)}
    }
}
if($variants.Count-ne $releaseCustomCount-or $portraitTotal-ne $releasePortraitCount){throw 'Release requires 13 custom appearances, 7 original options and exactly 400 PNGs.'}
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
$managerArtValidation=[ordered]@{Path=$artPath;Sha256=(Hash (Resolve-PackageFile $artPath));PortraitCount=$releasePortraitCount;CustomVariants=$releaseCustomCount;PreservedV20Portraits=312}
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
$compatibilityValidation=Assert-CodeReport 'verification/character-manager-compatibility.json' @('installer/CompatibilityProbe.ps1','installer/compatibility-baseline.json','Source/Plugin.cs','Source/CharacterPolicy.cs','Source/CharacterSupport.cs','Source/build.ps1')
$configurationValidation=Assert-CodeReport 'verification/character-configuration-parser.json' @('Source/CharacterPolicy.cs','Source/CharacterConfigurationJson.cs','Source/CharacterSupport.cs','Source/build.ps1','Source/Tests/Test-CharacterConfiguration.ps1')
$configuration=Read-Json $configurationValidation.Path
if($configuration.TestCount-lt 195-or $configuration.PassedCount-ne $configuration.TestCount-or @($configuration.Tests).Count-ne $configuration.TestCount-or @($configuration.Tests|Where-Object{$_.Passed-isnot [bool]-or-not $_.Passed}).Count){throw 'The current strict managed configuration parser suite must pass completely, including both protocol versions.'}
$compatibility=Read-Json $compatibilityValidation.Path;$baselinePath='installer/compatibility-baseline.json';$probePath='installer/CompatibilityProbe.ps1';$baseline=Read-Json $baselinePath
$dll=@($shared|Where-Object RelativePath -eq ($pluginRelative+'/ZhaoHuoNatural.dll'))[0].Sha256
$sharedUpdateValidation=Assert-CodeReport 'verification/character-shared-update.json' (@($backendPaths|Where-Object{$_-ne 'VariantCatalog.json'})+@('tests/Test-CharacterManager.ps1','tests/Test-CharacterSharedUpdate.ps1'))
$sharedUpdate=Read-Json $sharedUpdateValidation.Path
if($sharedUpdate.AssertionCount-ne 13-or @($sharedUpdate.Checks).Count-ne 13-or $sharedUpdate.ProductionTargetDllSha256-ne $dll){throw 'The current shared-DLL revision requires the 13 schema4 update/rollback assertions.'}
$expansionValidation=Assert-CodeReport 'verification/character-expansion-tests.json' (@($backendPaths|Where-Object{$_-ne 'VariantCatalog.json'})+@('tests/Test-CharacterManager.ps1','tests/Test-CharacterExpansion.ps1'))
$expansion=Read-Json $expansionValidation.Path
if($expansion.AssertionCount-lt 30-or @($expansion.Checks).Count-ne $expansion.AssertionCount-or @($expansion.TemporaryFixtureAllowlists).Count){throw 'Expanded protocol migration must pass with the actual frozen resource allowlists.'}
if($compatibility.PluginSha256-ne $dll-or $baseline.PluginSha256-ne $dll-or $compatibility.BaselineSha256-ne(Hash (Resolve-PackageFile $baselinePath))-or $compatibility.FixedFileCount-ne 395-or $compatibility.GameMemberReferenceCount-ne 23-or $baseline.GameMemberReferenceCount-ne 23){throw 'Compatibility evidence must bind the new DLL and unchanged 395-file boundary.'}
$runtimePath='verification/character-runtime.json';$runtime=Read-Json $runtimePath;Require-True $runtime.Passed 'new multi-character game runtime'
Require-True $runtime.ActualGameRun 'actual new-DLL game execution; offline policy checks alone are insufficient'
if($runtime.PluginSha256-ne $dll-or @($runtime.Characters).Count-ne $releaseRoleIds.Count-or [string]::IsNullOrWhiteSpace($runtime.Scope)){throw 'Runtime evidence must bind the current DLL and all seven characters.'};$runtimeIds=@{}
foreach($entry in $runtime.Characters){if($entry.Id-notin $releaseRoleIds-or $runtimeIds.ContainsKey($entry.Id)){throw 'Unknown/duplicate runtime character.'};$runtimeIds[$entry.Id]=$true;Require-True $entry.Passed ('runtime '+$entry.Id);Require-True $entry.OriginalDisabled ('original '+$entry.Id);Require-True $entry.NonTargetUnchanged ('non-target isolation '+$entry.Id)}
if($runtime.CurrentPlayerVariant-ne 'xianxia'-or $runtime.CatalogSha256-ne(Hash (Resolve-PackageFile 'VariantCatalog.json'))){throw 'Runtime evidence must identify the actual player appearance and frozen Catalog.'}
$requiredRuntimeVariants=@('player/xianxia','tang-buyi/refined','tang-buyi/female','xiahou-lan/refined','tang-moling/refined','long-xiang/refined','yu-xiaomei/refined','tang-zheng/female')
$testedRuntime=@{}
foreach($entry in $runtime.TestedVariants){$key=$entry.CharacterId+'/'+$entry.VariantId;if(-not $counts.ContainsKey($key)-or $testedRuntime.ContainsKey($key)){throw 'Unknown/duplicate actual runtime appearance.'};Require-True $entry.Passed ('actual appearance '+$key);$testedRuntime[$key]=$true}
foreach($key in $requiredRuntimeVariants){if(-not $testedRuntime.ContainsKey($key)){throw ('Actual runtime appearance evidence is missing: '+$key)}}
if(@($runtime.EvidenceFiles).Count-lt 1){throw 'Runtime evidence file list is empty.'};$seenEvidence=@{}
foreach($file in $runtime.EvidenceFiles){if($seenEvidence.ContainsKey($file.Path)){throw 'Duplicate runtime evidence.'};$seenEvidence[$file.Path]=$true;Require-Hash $file.Path $file.Sha256}
$runtimeValidation=[ordered]@{Path=$runtimePath;Sha256=(Hash (Resolve-PackageFile $runtimePath));Scope=$runtime.Scope}
$installationValidation=Assert-CodeReport 'verification/character-installation.json' $backendPaths
$installation=Read-Json $installationValidation.Path
if($installation.ExecutionMode-notin @('ActualInstallation','CopiedActualInstallation')){throw 'Installation acceptance must disclose actual or copied scope.'}
if([string]::IsNullOrWhiteSpace($installation.Scope)){throw 'Installation acceptance must describe what was actually exercised.'}
foreach($field in @('InitialInstallationPreserved','OriginalBackupsPreserved','OtherPluginsPreserved')){Require-True $installation.$field $field}
if($installation.ExecutionMode-eq 'CopiedActualInstallation'){Require-True $installation.OriginalSourceUnmodified 'unchanged original installation'}
