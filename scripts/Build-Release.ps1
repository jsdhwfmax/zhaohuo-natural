#requires -Version 5.1
[CmdletBinding()]
param(
    [ValidatePattern('^[0-9]+\.[0-9]+\.[0-9]+$')][string]$Version='1.3.0',
    [string]$OutputDirectory,
    [switch]$CheckOnly
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version 2.0
$repo=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$pluginRelative='BepInEx/plugins/ZhaoHuoNatural'
$knownFingerprints=[ordered]@{
    natural='1179319D7CEE4F7D19A7FF00D8A23E1D7474A8871F601343666DF4E6624E5E66'
    handsome='E38B63E6DECA2C3837AA659D19CA8AA48FBD4D748FFEB257D6DFEE6016832A8E'
    xianxia='12BC83F70EF4C99BBD49A13ABBA4A1867998B6DD794873EFAE47B065870A9802'
}
$knownPortraitPaths=@{natural="$pluginRelative/Portraits";handsome='Variants/handsome/Portraits';xianxia='Variants/xianxia/Portraits'}
function Resolve-PackageFile([string]$Relative){
    if([string]::IsNullOrWhiteSpace($Relative) -or [IO.Path]::IsPathRooted($Relative) -or $Relative.Contains(':') -or @($Relative-split '[\\/]'|Where-Object{$_-in @('','..','.')}).Count){throw ('Unsafe package path: '+$Relative)}
    $full=[IO.Path]::GetFullPath((Join-Path $repo $Relative))
    if(-not $full.StartsWith($repo.TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase)){throw 'Package path escaped its root.'}
    return $full
}
function Hash([string]$Path){(Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash}
function Code-Hash([string]$Path){
    $content=[IO.File]::ReadAllText($Path).TrimStart([char]0xFEFF).Replace("`r`n","`n").Replace("`r","`n")
    $sha=[Security.Cryptography.SHA256]::Create()
    try{([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($content)))).Replace('-','')}finally{$sha.Dispose()}
}
function Read-Json([string]$Relative){Get-Content -LiteralPath (Resolve-PackageFile $Relative) -Raw -Encoding UTF8|ConvertFrom-Json}
function Require-Hash([string]$Relative,[string]$Expected){
    $path=Resolve-PackageFile $Relative
    if($Expected-notmatch '^[0-9a-fA-F]{64}$' -or-not(Test-Path -LiteralPath $path -PathType Leaf) -or(Hash $path)-ne $Expected){throw ('File/hash validation failed: '+$Relative)}
}
function Payload-Fingerprint([object[]]$Entries){
    $lines=[string[]]@($Entries|ForEach-Object{([string]$_.RelativePath).Replace('\','/').ToLowerInvariant()+'='+([string]$_.Sha256).ToUpperInvariant()})
    [Array]::Sort($lines,[StringComparer]::Ordinal)
    $sha=[Security.Cryptography.SHA256]::Create()
    try{([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes(($lines-join "`n"))))).Replace('-','')}finally{$sha.Dispose()}
}
function Assert-CodeReport([string]$Relative,[string[]]$RequiredPaths){
    $report=Read-Json $Relative
    $passed=($report.PSObject.Properties['status'] -and $report.status-eq 'passed') -or ($report.PSObject.Properties['Passed'] -and $report.Passed-is [bool] -and $report.Passed)
    if(-not $passed -or -not $report.PSObject.Properties['CodeHashes'] -or -not $report.PSObject.Properties['CodeHashAlgorithm'] -or $report.CodeHashAlgorithm-ne 'SHA256-UTF8-noBOM-LF-v1'){throw ('Current code-bound validation is required: '+$Relative)}
    $seen=@{}
    foreach($entry in @($report.CodeHashes)){
        $path=([string]$entry.Path).Replace('\','/')
        if($seen.ContainsKey($path)){throw ('Duplicate code hash entry: '+$path)}
        if($entry.Sha256-notmatch '^[0-9a-fA-F]{64}$' -or(Code-Hash (Resolve-PackageFile $path))-ne $entry.Sha256){throw ('Tested source content differs: '+$path)}
        $seen[$path]=$true
    }
    foreach($path in $RequiredPaths){if(-not $seen.ContainsKey($path)){throw ('Validation report is not bound to '+$path+': '+$Relative)}}
    return [ordered]@{Path=$Relative;Sha256=(Hash (Resolve-PackageFile $Relative));CodeHashAlgorithm=$report.CodeHashAlgorithm;CodeHashCount=$seen.Count;CodeHashes=$report.CodeHashes}
}
function Assert-HistoricalRuntime([string]$Id){
    $relative='verification/'+$Id+'-runtime.json';$report=Read-Json $relative
    if($report.Passed-isnot [bool] -or-not $report.Passed -or $report.Variant-ne $Id -or $report.PayloadFingerprint-ne $knownFingerprints[$Id] -or $report.Resources-ne 50 -or $report.Replaced-ne 47 -or $report.AvatarPanelReplaced-ne 2 -or-not $report.NormalSteamStartup.Passed){throw ('Historical runtime evidence mismatch: '+$Id)}
    $localOnly=0
    foreach($file in $report.EvidenceFiles){
        if($file.PSObject.Properties['IncludedInPublicPackage'] -and-not $file.IncludedInPublicPackage){
            if([IO.Path]::GetExtension([string]$file.file)-ne '.png' -or $file.sha256-notmatch '^[0-9A-Fa-f]{64}$'){throw 'Only hashed, locally reviewed screenshots may be omitted from public evidence.'}
            $localOnly++;continue
        }
        Require-Hash ('verification/'+$report.EvidenceDirectory+'/'+$file.file) $file.sha256
    }
    foreach($key in @('Evidence','Log')){
        $path='verification/'+$report.NormalSteamStartup.$key
        if(-not(Test-Path -LiteralPath (Resolve-PackageFile $path) -PathType Leaf)){throw ('Missing normal startup evidence: '+$path)}
        $hashProperty=$key+'SHA256'
        if($report.NormalSteamStartup.PSObject.Properties[$hashProperty]){Require-Hash $path $report.NormalSteamStartup.$hashProperty}
    }
    return [ordered]@{Path=$relative;Sha256=(Hash (Resolve-PackageFile $relative));BuildId=$report.GameBuild;PayloadFingerprint=$report.PayloadFingerprint;LocallyReviewedScreenshotsNotDistributed=$localOnly;Scope='Reused evidence for unchanged shared plugin and the exact frozen portrait payload; not new manager UI or transaction testing.'}
}
$catalog=Read-Json 'VariantCatalog.json'
if($catalog.SchemaVersion-ne 1 -or $catalog.PackageVersion-ne $Version -or $Version-ne '1.3.0' -or $catalog.DefaultVariantId-ne 'natural' -or $catalog.FingerprintAlgorithm-ne 'SHA256-normalized-path-hash-lines-ordinal-v1' -or @($catalog.Variants).Count-ne 3){throw 'Expected the frozen three-appearance v1.3.0 catalog.'}
$installer=Import-Module (Resolve-PackageFile 'installer/ZhaoHuoInstaller.psm1') -Force -PassThru
$portraitNames=@(& $installer {$script:PortraitNames})
if($portraitNames.Count-ne 47){throw 'Expected exactly 47 supported portrait names.'}
$shared=@(foreach($name in @('ZhaoHuoNatural.dll','portrait-map.txt','portrait-layout.tsv')){$path="$pluginRelative/$name";[pscustomobject]@{RelativePath=$path;Sha256=(Hash (Resolve-PackageFile $path))}})
Require-Hash "$pluginRelative/ZhaoHuoNatural.dll" '66F6D545562FDEDF2F5E0CAA1AA8609629A42556C5779DF1C45B61F93EA00095'
$variants=@();$seenIds=@{};$variantFiles=@{}
foreach($variant in $catalog.Variants){
    if(-not $knownFingerprints.Contains($variant.Id) -or $seenIds.ContainsKey($variant.Id) -or $variant.PayloadFingerprint-ne $knownFingerprints[$variant.Id] -or $variant.PortraitPath-ne $knownPortraitPaths[$variant.Id] -or $variant.PreviewPath-ne ($variant.PortraitPath+'/normal.png')){throw 'Catalog identity, portrait source, preview or fingerprint changed unexpectedly.'}
    $seenIds[$variant.Id]=$true
    $folder=Resolve-PackageFile $variant.PortraitPath
    if(@(Get-ChildItem -LiteralPath $folder -Recurse -File).Count-ne 47){throw ('Unexpected files in portrait source: '+$variant.Id)}
    $entries=@($shared)
    $hashes=@{}
    foreach($name in $portraitNames){$hash=Hash (Resolve-PackageFile ($variant.PortraitPath+'/'+$name+'.png'));$hashes[$name]=$hash;$entries+=[pscustomobject]@{RelativePath="$pluginRelative/Portraits/$name.png";Sha256=$hash}}
    $fingerprint=Payload-Fingerprint $entries
    if($fingerprint-ne $knownFingerprints[$variant.Id]){throw ('Frozen 50-file payload fingerprint mismatch: '+$variant.Id)}
    $variantFiles[$variant.Id]=$hashes
    $variants+=[ordered]@{Id=$variant.Id;DisplayName=$variant.DisplayName;PortraitPath=$variant.PortraitPath;PreviewPath=$variant.PreviewPath;PortraitCount=47;PayloadFileCount=50;PayloadFingerprint=$fingerprint}
}
$naturalArt=Read-Json 'verification/art-integrity.json'
if($naturalArt.result-ne 'PASS' -or @($naturalArt.images).Count-ne 47){throw 'Natural artwork integrity report is incomplete.'}
foreach($image in $naturalArt.images){$name=[IO.Path]::GetFileNameWithoutExtension($image.file);if(-not $variantFiles.natural.ContainsKey($name) -or $variantFiles.natural[$name]-ne $image.sha256){throw ('Natural artwork evidence differs: '+$name)}}
$managerArt=Read-Json 'verification/manager-art-integrity.json'
if($managerArt.Passed-isnot [bool] -or-not $managerArt.Passed -or @($managerArt.Variants).Count-ne 3){throw 'Three-appearance decoded artwork report is incomplete.'}
$artIds=@{}
foreach($art in $managerArt.Variants){
    if(-not $knownFingerprints.Contains($art.Id) -or $artIds.ContainsKey($art.Id) -or $art.Passed-isnot [bool] -or-not $art.Passed -or $art.Portraits-ne 47 -or $art.PayloadFiles-ne 50 -or $art.PayloadFingerprint-ne $knownFingerprints[$art.Id] -or @($art.Files).Count-ne 50){throw 'Decoded artwork report identity or count differs.'}
    $artIds[$art.Id]=$true;$artPaths=@{}
    foreach($file in $art.Files){
        $logical=([string]$file.RelativePath).Replace('\','/')
        if($artPaths.ContainsKey($logical)){throw 'Duplicate decoded artwork report file.'};$artPaths[$logical]=$true
        if($logical.StartsWith($pluginRelative+'/Portraits/',[StringComparison]::Ordinal)){
            $name=[IO.Path]::GetFileNameWithoutExtension($logical)
            if($logical-ne ($pluginRelative+'/Portraits/'+$name+'.png') -or-not $variantFiles[$art.Id].ContainsKey($name) -or $file.Sha256-ne $variantFiles[$art.Id][$name] -or $file.Width-le 0 -or $file.Height-le 0 -or $file.AlphaMin-ne 0 -or $file.AlphaMax-le 0){throw 'Decoded portrait result does not bind the current PNG.'}
        } else {
            $match=@($shared|Where-Object{$_.RelativePath-eq $logical})
            if($match.Count-ne 1 -or $match[0].Sha256-ne $file.Sha256){throw 'Decoded artwork report shared payload differs.'}
        }
    }
}
$managerArtValidation=[ordered]@{Path='verification/manager-art-integrity.json';SHA256=(Hash (Resolve-PackageFile 'verification/manager-art-integrity.json'));Portraits=141;Variants=3}
$naturalRuntime=Read-Json 'verification/runtime-build25957922/compatibility.json'
if($naturalRuntime.RuntimeResult-ne 'PASS' -or $naturalRuntime.PluginSha256-ne $shared[0].Sha256 -or $naturalRuntime.Resources-ne 50 -or $naturalRuntime.Replaced-ne 47 -or $naturalRuntime.AvatarReplaced-ne 2){throw 'Natural historical runtime evidence differs.'}
foreach($evidence in $naturalRuntime.EvidenceFiles){Require-Hash ('verification/runtime-build25957922/'+$evidence.Name) $evidence.Sha256}
$historicalRuntime=[ordered]@{
 natural=[ordered]@{Path='verification/runtime-build25957922/compatibility.json';Sha256=(Hash (Resolve-PackageFile 'verification/runtime-build25957922/compatibility.json'));ArtIntegritySha256=(Hash (Resolve-PackageFile 'verification/art-integrity.json'));PayloadFingerprint=$knownFingerprints.natural;Scope='Reused natural-edition evidence for unchanged frozen artwork and shared plugin.'}
 handsome=(Assert-HistoricalRuntime 'handsome')
 xianxia=(Assert-HistoricalRuntime 'xianxia')
}
$junior=Read-Json 'Prompts/xianxia-junior/index.json'
if(-not $junior.Complete -or $junior.RecordedAssets-ne 47 -or $junior.PayloadFingerprint-ne $knownFingerprints.xianxia -or $junior.GenerationMethod-ne 'builtin imagegen' -or @($junior.Assets).Count-ne 47){throw 'Junior prompt provenance does not match its frozen appearance.'}
foreach($asset in $junior.Assets){if(-not $variantFiles.xianxia.ContainsKey($asset.Name) -or $variantFiles.xianxia[$asset.Name]-ne $asset.OutputSHA256 -or $asset.OutputSHA256-ne $asset.SelectedGeneration.SHA256){throw ('Junior final generation binding differs: '+$asset.Name)}}
Require-Hash 'Dependencies/BepInEx/runtime-manifest.json' 'D4C53D568F7254ACC9754405E1EAD03BB9AEE484F3962274AFF3C497A96BA7DC'
Require-Hash 'Loader/winhttp.dll' 'D3B62F4C9C3E2196EF82603C52D6B98C043A0D6C125C081FD33D7CA3798B41B8'
$runtime=Read-Json 'Dependencies/BepInEx/runtime-manifest.json'
foreach($entry in $runtime.Files){Require-Hash ('Dependencies/BepInEx/files/'+$entry.RelativePath) $entry.Sha256}
$probePath='installer/CompatibilityProbe.ps1';$baselinePath='installer/compatibility-baseline.json'
# Git may convert script line endings. Pin exact normalized source content while
# keeping distributed file-byte hashes in the release manifest.
if((Code-Hash (Resolve-PackageFile $probePath))-ne '912A8DB738DB048637C0995F73EB4E8CE9A63BA9533D40B3CC190C4D0F4A0D81'){throw 'The frozen offline probe source changed.'}
Require-Hash $baselinePath '830863946FC21FD8B33846B9B68A2046820D839EE477B5075744B1596065246C'
$probeReport=Read-Json 'verification/compatibility-probe-tests.json'
if(-not $probeReport.Passed -or $probeReport.BaselineSha256-ne(Hash (Resolve-PackageFile $baselinePath))){throw 'Offline probe validation is not tied to the current unchanged baseline.'}
$managerValidation=Assert-CodeReport 'verification/appearance-manager-tests.json' @('installer/ZhaoHuoInstaller.psm1','installer/VariantSupport.ps1','installer/AppearanceManager.ps1','VariantCatalog.json','tests/Test-AppearanceManager.ps1')
$regressionValidation=Assert-CodeReport 'verification/appearance-manager-regression.json' @('installer/ZhaoHuoInstaller.psm1','installer/VariantSupport.ps1','installer/AppearanceManager.ps1','VariantCatalog.json','tests/Test-Installer.ps1')
if((Read-Json 'verification/appearance-manager-regression.json').assertionCount-ne 74){throw 'Expected the complete 74-assertion installer regression report.'}
$guiValidation=Assert-CodeReport 'verification/appearance-manager-gui.json' @('installer/Gui.ps1','Install.ps1','Install.cmd','Uninstall.cmd','打开美化管理器.cmd')
$copiedInstallationValidation=Assert-CodeReport 'verification/copied-manager-switch.json' @('installer/ZhaoHuoInstaller.psm1','installer/VariantSupport.ps1','installer/AppearanceManager.ps1','VariantCatalog.json')
$copiedInstallation=Read-Json 'verification/copied-manager-switch.json'
# Xianxia is the chosen final state of this release acceptance run, not a limit
# on the manager's supported install/switch destinations.
if($copiedInstallation.Passed-isnot [bool] -or-not $copiedInstallation.Passed -or $copiedInstallation.ExecutionMode-ne 'CopiedActualInstallation' -or $copiedInstallation.FinalVariantId-ne 'xianxia' -or $copiedInstallation.InitialInstallationPreserved-isnot [bool] -or-not $copiedInstallation.InitialInstallationPreserved -or $copiedInstallation.OriginalBackupsPreserved-isnot [bool] -or-not $copiedInstallation.OriginalBackupsPreserved -or $copiedInstallation.OriginalSourceUnmodified-isnot [bool] -or-not $copiedInstallation.OriginalSourceUnmodified){throw 'The copied-installation acceptance did not finish with verified source and original-backup preservation.'}
$copiedInstallationValidation.Scope='CopiedActualInstallation: file transactions in an isolated copy of an actual managed installation; the running source game was not modified.'
$gameVersions=@{'25953419'='release_1.0.6000.0';'25957922'='release_1.0.6000.2'}
$supported=@(& $installer {$script:SupportedGameBuilds}|ForEach-Object{if(-not $gameVersions.ContainsKey([string]$_.BuildId)){throw 'Game metadata is missing.'};[ordered]@{BuildId=[string]$_.BuildId;GameVersion=$gameVersions[[string]$_.BuildId];Hashes=$_.Hashes}})
$folderNames=@('BepInEx','Variants','Loader','Dependencies','installer','Source','Prompts','docs','verification','scripts')
$rootNames=@('打开美化管理器.cmd','Install.cmd','Uninstall.cmd','Install.ps1','Uninstall.ps1','VariantCatalog.json','README.md','LICENSE','ARTWORK-NOTICE.md','THIRD_PARTY_NOTICES.md','CHANGELOG.md')
$sourceFiles=@()
foreach($folderName in $folderNames){
    $folder=Resolve-PackageFile $folderName
    if(-not(Test-Path -LiteralPath $folder -PathType Container)){throw ('Missing package directory: '+$folderName)}
    foreach($entry in @(Get-Item -LiteralPath $folder)+@(Get-ChildItem -LiteralPath $folder -Recurse -Force)){if(($entry.Attributes-band [IO.FileAttributes]::ReparsePoint)-ne 0){throw ('Package link is not supported: '+$entry.Name)}}
    $sourceFiles+=@(Get-ChildItem -LiteralPath $folder -Recurse -File)
}
$sourceFiles+=@($rootNames|ForEach-Object{Get-Item -LiteralPath (Resolve-PackageFile $_)})
$sourceFiles+=@(Get-ChildItem -LiteralPath (Resolve-PackageFile 'tests') -File -Filter '*.ps1')
$selected=@()
foreach($file in $sourceFiles){
    $relative=$file.FullName.Substring($repo.Length+1).Replace('\','/')
    if($file.Extension-in @('.pdb','.rsp')){continue}
    if($file.Extension-in @('.log','.tmp') -or $file.Name-in @('Mortal.exe','Assembly-CSharp.dll','Mortal.Core.dll','Mortal.Story.dll','Fungus.dll','ActiveManifest.json','ActiveSwitch.json') -or $relative-match '/(?:\.work|\.git|Diagnostics)/'){throw ('Unexpected game/local/temp file: '+$relative)}
    if($relative-match '^verification/(?:handsome/|xianxia/)?runtime[^/]*/.*\.png$'){throw 'Game UI/fallback screenshots must remain in private verification, not public packages.'}
    if($file.Extension-in @('.md','.txt','.json','.ps1','.psm1','.cmd','.cs','.tsv')){
        $text=[IO.File]::ReadAllText($file.FullName).Replace('\\','\').Replace('\','/')
        if($text-match '(?i)[A-Z]:/(?:Users/[^/\s]+|desktop)(?:/|["''\s])'){throw ('Local private provenance path found in public text: '+$relative)}
    }
    $selected+=[pscustomobject]@{Path=$relative;Source=$file.FullName;SHA256=(Hash $file.FullName);Bytes=$file.Length}
}
if(@($selected.Path|Sort-Object -Unique).Count-ne $selected.Count){throw 'Duplicate package file path.'}
if($CheckOnly){return [pscustomobject]@{Status='passed';Version=$Version;Variants=$variants;PortraitCount=141;Files=$selected.Count;ManagerValidation=$managerValidation.Path;RegressionValidation=$regressionValidation.Path;GuiValidation=$guiValidation.Path;CopiedInstallationValidation=$copiedInstallationValidation.Path;HistoricalRuntimeEvidence='Exact unchanged artwork/plugin evidence retained; screenshots local-only';NoOutputWritten=$true}}
if(-not $OutputDirectory){$OutputDirectory=Join-Path $repo 'dist'}
$OutputDirectory=[IO.Path]::GetFullPath($OutputDirectory)
$name="ZhaoHuoPortraitManager-v$Version-win-x64"
$zip=Join-Path $OutputDirectory ($name+'.zip')
if(Test-Path -LiteralPath $zip){throw 'Release ZIP already exists; use a new output directory.'}
$stage=Join-Path (Join-Path $OutputDirectory ('staging-'+[Guid]::NewGuid().ToString('N'))) $name
New-Item -ItemType Directory -Path $stage -Force|Out-Null
foreach($file in $selected){
    $target=Join-Path $stage $file.Path
    New-Item -ItemType Directory -Path (Split-Path -Parent $target) -Force|Out-Null
    Copy-Item -LiteralPath $file.Source -Destination $target
    if((Hash $target)-ne $file.SHA256){throw ('Package source changed during staging: '+$file.Path)}
}
$manifest=[ordered]@{
    Package='ZhaoHuoPortraitManager';Version=$Version;Platform='Windows x64';SteamAppId=1859910;DefaultVariantId=$catalog.DefaultVariantId
    Catalog=[ordered]@{Path='VariantCatalog.json';SHA256=(Hash (Resolve-PackageFile 'VariantCatalog.json'))}
    Variants=$variants;PortraitCount=141;InstalledPortraitCount=47;SharedPluginFiles=$shared
    VerifiedGameBuilds=$supported;HistoricalRuntimeEvidence=$historicalRuntime;ManagerValidation=$managerValidation;RegressionValidation=$regressionValidation;GuiValidation=$guiValidation;CopiedInstallationValidation=$copiedInstallationValidation;ArtworkValidation=$managerArtValidation
    CompatibilityCheck=[ordered]@{Trigger='ManagerCheckOrApply';AutoRunOnGameStart=$false;NetworkRequired=$false;FastPathRequiresSteamBuildAndCompleteFingerprint=$true;UnknownBuildMode='OfflineCompatibilityProbe';ProbePath=$probePath;ProbeSHA256=(Hash (Resolve-PackageFile $probePath));BaselinePath=$baselinePath;BaselineSHA256=(Hash (Resolve-PackageFile $baselinePath))}
    Scope='Three selectable frozen appearance payloads with one unchanged plugin. Synthetic fixtures, copied-actual-installation transactions and GUI evidence are separate from reused historical game-runtime checks; the source game was not modified; not full-story or universal future-update verification.'
    ProvenancePrivacy='Public text/provenance omits local username/desktop paths. The unchanged shared DLL retains its original compiler debug-path reference.'
    Files=@($selected|Sort-Object Path|ForEach-Object{[ordered]@{Path=$_.Path;SHA256=$_.SHA256;Bytes=$_.Bytes}})
}
[IO.File]::WriteAllText((Join-Path $stage 'ReleaseManifest.json'),($manifest|ConvertTo-Json -Depth 14),(New-Object Text.UTF8Encoding($false)))
$sums=@(Get-ChildItem -LiteralPath $stage -Recurse -File|Sort-Object FullName|ForEach-Object{(Hash $_.FullName)+'  '+$_.FullName.Substring($stage.Length+1).Replace('\','/')})
[IO.File]::WriteAllLines((Join-Path $stage 'SHA256SUMS.txt'),$sums,(New-Object Text.UTF8Encoding($false)))
Compress-Archive -LiteralPath $stage -DestinationPath $zip -CompressionLevel Optimal
$hash=Hash $zip
[IO.File]::WriteAllText(($zip+'.sha256'),($hash+'  '+[IO.Path]::GetFileName($zip)+[Environment]::NewLine),[Text.Encoding]::ASCII)
Write-Output ('Release archive: '+$zip)
Write-Output ('SHA256: '+$hash)
Write-Output ('Inspection directory: '+$stage)
