#requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$GamePath,
    [Parameter(Mandatory=$true)][ValidatePattern('^[0-9]+$')][string]$BuildId,
    [Parameter(Mandatory=$true)][string]$OutputPath,
    [string]$PackageRoot,
    [string]$ReferenceBaseline = 'installer/compatibility-baseline.json',
    [switch]$Force
)
# Captures a candidate only. A capture is not approval or actual-game validation.
$ErrorActionPreference='Stop'
Set-StrictMode -Version 2.0
if (-not $PackageRoot) { $PackageRoot = Split-Path -Parent $PSScriptRoot }
. (Join-Path $PackageRoot 'installer/CompatibilityProbe.ps1')
$game=[IO.Path]::GetFullPath($GamePath).TrimEnd('\')
$output=[IO.Path]::GetFullPath($OutputPath)
if ($output -eq $game -or $output.StartsWith($game+'\',[StringComparison]::OrdinalIgnoreCase)) {throw 'Baseline output must be outside the game directory.'}
if ((Test-Path -LiteralPath $output) -and -not $Force) {throw 'Output already exists; choose a new candidate path or explicitly use -Force.'}
if (-not (Test-Path -LiteralPath (Split-Path -Parent $output) -PathType Container)) {throw 'Output parent directory must already exist.'}
$referencePath=Get-ZHCPChild $PackageRoot $ReferenceBaseline
if ((Get-ZHCPHash $referencePath) -ne $script:ZHCompatibilityBaselineHash) {throw 'Reference baseline is not the frozen prior baseline.'}
$reference=Get-Content -LiteralPath $referencePath -Raw -Encoding UTF8|ConvertFrom-Json
$parent=[IO.Directory]::GetParent($game)
$acf=Join-Path $parent.Parent.FullName 'appmanifest_1859910.acf'
$manifest=Get-Content -LiteralPath $acf -Raw
if ($manifest -notmatch '"buildid"\s+"([0-9]+)"' -or $Matches[1] -ne $BuildId) {throw 'Requested build does not match the local Steam manifest.'}
if($manifest -notmatch '"StateFlags"\s+"4"'){throw 'Steam update must be complete before capture.'}
$coreHash=Get-ZHCPHash (Get-ZHCPChild $game 'Mortal_Data/Managed/Mortal.Core.dll')
$versionFileHash=Get-ZHCPHash (Get-ZHCPChild $game 'Mortal_Data/globalgamemanagers')
$culture=[Threading.Thread]::CurrentThread.CurrentCulture
$resolver=$null;$core=$null;$plugin=$null
try {
    [Threading.Thread]::CurrentThread.CurrentCulture=[Globalization.CultureInfo]::InvariantCulture
    Initialize-ZHCPCecil $PackageRoot
    $managed=Get-ZHCPChild $game 'Mortal_Data/Managed'
    $resolver=New-Object Mono.Cecil.DefaultAssemblyResolver
    $resolver.AddSearchDirectory($managed)
    $resolver.AddSearchDirectory((Get-ZHCPChild $PackageRoot 'Dependencies/BepInEx/files/BepInEx/core'))
    $reader=New-Object Mono.Cecil.ReaderParameters
    $reader.AssemblyResolver=$resolver
    $core=[Mono.Cecil.ModuleDefinition]::ReadModule((Join-Path $managed 'Mortal.Core.dll'),$reader)
    $surface=Get-ZHCPCoreSurface $core @($reference.CoreSeedTypes)
    foreach ($category in @('Methods','Types')) {
        $expected=@{};foreach($item in $reference.CoreSurface.$category){$expected[$item.Name]=$item.Sha256}
        $actual=@($surface.$category)
        if ($expected.Count -ne $actual.Count) {throw ('Portrait '+$category+' scope changed; review implementation before capture.')}
        foreach($item in $actual){if(-not $expected.ContainsKey($item.Name) -or $expected[$item.Name] -ne $item.Sha256){throw ('Portrait implementation changed: '+$item.Name)}}
    }
    $pluginPath=Get-ZHCPChild $PackageRoot 'BepInEx/plugins/ZhaoHuoNatural/ZhaoHuoNatural.dll'
    if ((Get-ZHCPHash $pluginPath) -ne $reference.PluginSha256) {throw 'Plugin changed; this generator only captures a game update for the frozen plugin.'}
    $plugin=[Mono.Cecil.ModuleDefinition]::ReadModule($pluginPath,$reader)
    $references=@($plugin.GetMemberReferences()|Where-Object{$_.DeclaringType.Scope.Name -in @('Mortal.Core','Mortal.Story','Fungus','OBB.Framework')})
    if ($references.Count -ne $reference.GameMemberReferenceCount) {throw 'Plugin member reference count changed.'}
    foreach($member in $references){if($null-eq $member.Resolve()){throw ('Unresolved plugin member: '+$member.FullName)}}
    $fixed=@{}
    function Add-CaptureFile([string]$Path,[string]$Category) {
        $relative=$Path.Substring($game.Length+1).Replace('\','/')
        $safe=Get-ZHCPChild $game $relative
        $fixed[$relative]=[pscustomobject][ordered]@{RelativePath=$relative;Category=$Category;SizeBytes=(Get-Item -LiteralPath $safe).Length;Sha256=(Get-ZHCPHash $safe)}
    }
    Get-ChildItem -LiteralPath $managed -Filter '*.dll' -File|Where-Object Name -ne 'Mortal.Core.dll'|ForEach-Object{Add-CaptureFile $_.FullName 'ManagedDependencies'}
    foreach($name in @('Mortal.exe','UnityPlayer.dll')){Add-CaptureFile (Join-Path $game $name) 'UnityRuntime'}
    Get-ChildItem -LiteralPath (Join-Path $game 'MonoBleedingEdge') -Recurse -File|ForEach-Object{Add-CaptureFile $_.FullName 'MonoRuntime'}
    Get-ChildItem -LiteralPath (Join-Path $game 'Mortal_Data') -File|Where-Object Name -ne 'globalgamemanagers'|ForEach-Object{Add-CaptureFile $_.FullName 'SceneAndSerializedAssets'}
    Get-ChildItem -LiteralPath (Join-Path $game 'Mortal_Data/Resources') -Recurse -File|ForEach-Object{Add-CaptureFile $_.FullName 'SceneAndSerializedAssets'}
    $aa=Join-Path $game 'Mortal_Data/StreamingAssets/aa'
    foreach($name in @('catalog.json','settings.json')){Add-CaptureFile (Join-Path $aa $name) 'AddressablesCatalog'}
    Get-ChildItem -LiteralPath $aa -Recurse -File -Filter '*.bundle'|ForEach-Object{Add-CaptureFile $_.FullName 'AddressablesBundles'}
    foreach($group in @($reference.FixedFiles|Group-Object Category)) {
        if (@($fixed.Values|Where-Object Category -eq $group.Name).Count -lt $group.Count) {throw ('Protected file count shrank in '+$group.Name+'; explicit review needed.')}
    }
    $versionPath=Join-Path $game 'Mortal_Data/globalgamemanagers'
    $versionText=[Text.Encoding]::GetEncoding(28591).GetString([IO.File]::ReadAllBytes($versionPath))
    $versions=@([regex]::Matches($versionText,'release_[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+'))
    if($versions.Count-ne 1){throw 'Version metadata is ambiguous.'}
    $catalog=Get-Content -LiteralPath (Join-Path $aa 'catalog.json') -Raw -Encoding UTF8|ConvertFrom-Json
    $allIds=@($catalog.m_InternalIds|Sort-Object)
    $playerPattern='/Player_'+[char]0x4E3B+[char]0x89D2+'/[^/]+\.png$'
    $playerIds=@($catalog.m_InternalIds|Where-Object{$_ -match $playerPattern}|Sort-Object)
    if($playerIds.Count -lt $reference.ProtagonistCatalog.Count){throw 'Protagonist catalog is smaller than the prior inspected catalog; explicit resource review required.'}
    $baseline=[ordered]@{
        SchemaVersion=1;CapturedFromBuildId=$BuildId;CapturedGameVersion=$versions[0].Value;BaselineBuildIds=@($BuildId)
        Policy='One complete resource/runtime snapshot plus unchanged portrait-related static call surface. Never combine files from different baselines. Capture alone is not actual-game verification.'
        PluginSha256=(Get-ZHCPHash $pluginPath);GameMemberReferenceCount=$references.Count
        CoreSeedTypes=@($reference.CoreSeedTypes);CoreSurface=$surface
        ManagedAssemblyNames=@(Get-ChildItem -LiteralPath $managed -Filter '*.dll' -File|ForEach-Object Name|Sort-Object)
        FixedFiles=@($fixed.Keys|Sort-Object|ForEach-Object{$fixed[$_]})
        VersionMetadata=[ordered]@{RelativePath='Mortal_Data/globalgamemanagers';NormalizedSha256=(Get-ZHCPVersionMetadataHash $versionPath);Normalization='One release_X.X.X.X string replaced with <GAME_VERSION>; all remaining bytes preserved before digest'}
        ProtagonistCatalog=[ordered]@{Count=$playerIds.Count;InternalIdListSha256=(Get-ZHCPTextHash ($playerIds -join "`n"));Guard='Complete catalog byte hash plus all local asset bundles'}
        AddressablesCatalog=[ordered]@{InternalIdCount=$allIds.Count;InternalIdListSha256=(Get-ZHCPTextHash ($allIds -join "`n"));Guard='Exact catalog and settings byte hashes plus complete local bundle inventory and bytes'}
    }
    $afterManifest=Get-Content -LiteralPath $acf -Raw
    if($afterManifest -notmatch '"buildid"\s+"([0-9]+)"' -or $Matches[1]-ne $BuildId -or $afterManifest -notmatch '"StateFlags"\s+"4"'){throw 'Steam build or update state changed during capture.'}
    if((Get-ZHCPHash (Join-Path $managed 'Mortal.Core.dll'))-ne $coreHash -or (Get-ZHCPHash $versionPath)-ne $versionFileHash){throw 'Game code or version metadata changed during capture.'}
    foreach($entry in $fixed.Values){if((Get-ZHCPHash (Join-Path $game $entry.RelativePath))-ne $entry.Sha256){throw ('Game file changed during capture: '+$entry.RelativePath)}}
    $json=($baseline|ConvertTo-Json -Depth 20).Replace("`r`n","`n")+"`n"
    [IO.File]::WriteAllText($output,$json,[Text.UTF8Encoding]::new($false))
    [pscustomobject]@{BuildId=$BuildId;GameVersion=$versions[0].Value;BaselineSha256=(Get-ZHCPHash $output);Files=$fixed.Count;Methods=$surface.Methods.Count;Types=$surface.Types.Count;GameMemberReferences=$references.Count;ActualGameRun=$false}
} finally {
    if($plugin){$plugin.Dispose()};if($core){$core.Dispose()};if($resolver){$resolver.Dispose()}
    [Threading.Thread]::CurrentThread.CurrentCulture=$culture
}
