#requires -Version 5.1
[CmdletBinding()]
param(
    [ValidatePattern('^[0-9]+\.[0-9]+\.[0-9]+$')][string]$Version='2.0.0',
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
function Assert-HistoricalCatalogBinding([string]$ReportPath,[string]$HistoricalHash){
    if($ReportPath-notin @('verification/character-manager-tests.json','verification/character-manager-regression.json')){throw 'Only the two original synthetic-fixture reports may reuse their historical Catalog data binding.'}
    $acceptPath='verification/character-catalog-acceptance.json'
    $null=Assert-CodeReport $acceptPath @('installer/ZhaoHuoInstaller.psm1','installer/AppearanceManager.ps1','installer/VariantSupport.ps1','installer/CharacterCatalog.ps1','installer/CharacterState.ps1','installer/CharacterManager.ps1','installer/CharacterTransactions.ps1','VariantCatalog.json','Install.ps1','tests/Test-CharacterCatalog.ps1')
    $accept=Read-Json $acceptPath
    foreach($field in @('DataOnlyAcceptance','PackageReady','ReadOnlyPackageUnchanged')){if($accept.$field-isnot [bool]-or-not $accept.$field){throw ('Final Catalog acceptance flag is missing: '+$field)}}
    if($accept.SourceSuitesRerun-isnot [bool]-or $accept.SourceSuitesRerun-or $accept.ActualGameRun-isnot [bool]-or $accept.ActualGameRun){throw 'Catalog-only evidence must not claim a fixture-suite rerun or actual game execution.'}
    if($accept.PortraitCount-ne 312-or $accept.CustomVariantCount-ne 8-or $accept.CharacterCount-ne 3-or $accept.CatalogSha256-ne(Hash (Resolve-PackageFile 'VariantCatalog.json'))-or $accept.CatalogCodeSha256-ne(Code-Hash (Resolve-PackageFile 'VariantCatalog.json'))){throw 'Final production Catalog acceptance differs from this package.'}
    if(@($accept.ReusedReports).Count-ne 2){throw 'Both immutable historical fixture reports must be identified.'}
    $binding=@($accept.ReusedReports|Where-Object Path -eq $ReportPath)
    if($binding.Count-ne 1-or $binding[0].Sha256-ne(Hash (Resolve-PackageFile $ReportPath))-or $binding[0].HistoricalCatalogCodeSha256-ne $HistoricalHash-or $binding[0].SourceSuiteRerun-isnot [bool]-or $binding[0].SourceSuiteRerun){throw ('Historical Catalog evidence is not preserved: '+$ReportPath)}
    Require-Hash $accept.ArtworkEvidence.Path $accept.ArtworkEvidence.Sha256
    Require-Hash $accept.PromptEvidence.Path $accept.PromptEvidence.Sha256
}
function Assert-CodeReport([string]$Relative,[string[]]$RequiredPaths,[switch]$AllowHistoricalCatalog){
    $report=Read-Json $Relative
    $passed=($report.PSObject.Properties['status'] -and $report.status-eq 'passed') -or ($report.PSObject.Properties['Passed'] -and $report.Passed-is [bool] -and $report.Passed)
    if(-not $passed -or -not $report.PSObject.Properties['CodeHashes'] -or -not $report.PSObject.Properties['CodeHashAlgorithm'] -or $report.CodeHashAlgorithm-ne 'SHA256-UTF8-noBOM-LF-v1'){throw ('Current code-bound validation is required: '+$Relative)}
    $seen=@{};$historicalCatalog=$false
    $hashEntries=if($report.CodeHashes-is [Array]){@($report.CodeHashes)}else{@($report.CodeHashes.PSObject.Properties|ForEach-Object{[pscustomobject]@{Path=$_.Name;Sha256=$_.Value}})}
    foreach($entry in $hashEntries){
        $path=([string]$entry.Path).Replace('\','/')
        if($seen.ContainsKey($path)){throw ('Duplicate code hash entry: '+$path)}
        if($entry.Sha256-notmatch '^[0-9a-fA-F]{64}$'){throw ('Invalid tested source hash: '+$path)}
        if((Code-Hash (Resolve-PackageFile $path))-ne $entry.Sha256){
            if($AllowHistoricalCatalog-and $path-ceq 'VariantCatalog.json'){
                Assert-HistoricalCatalogBinding $Relative $entry.Sha256;$historicalCatalog=$true
            }else{throw ('Tested source content differs: '+$path)}
        }
        $seen[$path]=$true
    }
    foreach($path in $RequiredPaths){if(-not $seen.ContainsKey($path)){throw ('Validation report is not bound to '+$path+': '+$Relative)}}
    return [ordered]@{Path=$Relative;Sha256=(Hash (Resolve-PackageFile $Relative));CodeHashAlgorithm=$report.CodeHashAlgorithm;CodeHashCount=$seen.Count;CodeHashes=@($hashEntries);HistoricalCatalogBinding=$historicalCatalog;CatalogAcceptancePath=$(if($historicalCatalog){'verification/character-catalog-acceptance.json'}else{$null})}
}
. (Join-Path $PSScriptRoot 'Validate-CharacterRelease.ps1')
$gameVersions=@{'25953419'='release_1.0.6000.0';'25957922'='release_1.0.6000.2'}
$supported=@(& $installer {$script:SupportedGameBuilds}|ForEach-Object{if(-not $gameVersions.ContainsKey([string]$_.BuildId)){throw 'Game metadata is missing.'};[ordered]@{BuildId=[string]$_.BuildId;GameVersion=$gameVersions[[string]$_.BuildId];Hashes=$_.Hashes}})
$folderNames=@('BepInEx','Variants','Characters','Loader','Dependencies','installer','Source','Prompts','docs','verification','scripts')
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
    if($file.Extension-in @('.log','.tmp') -or $file.Name-in @('Mortal.exe','UnityPlayer.dll','Assembly-CSharp.dll','Mortal.Core.dll','Mortal.Story.dll','Fungus.dll','ActiveManifest.json','ActiveSwitch.json') -or $relative-match '/(?:\.work|\.git|Diagnostics)/'){throw ('Unexpected game/local/temp file: '+$relative)}
    if($relative-match '^verification/.*\.png$'){throw 'Game UI/fallback screenshots must remain in private verification, not public packages.'}
    if($file.Extension-in @('.md','.txt','.json','.ps1','.psm1','.cmd','.cs','.tsv')){
        $text=[IO.File]::ReadAllText($file.FullName).Replace('\\','\').Replace('\','/')
        if($text-match '(?i)[A-Z]:/(?:Users/[^/\s]+|desktop)(?:/|["''\s])'){throw ('Local private provenance path found in public text: '+$relative)}
    }
    $selected+=[pscustomobject]@{Path=$relative;Source=$file.FullName;SHA256=(Hash $file.FullName);Bytes=$file.Length}
}
if(@($selected.Path|Sort-Object -Unique).Count-ne $selected.Count){throw 'Duplicate package file path.'}
if($CheckOnly){return [pscustomobject]@{Status='passed';Version=$Version;Characters=3;CustomVariants=8;PortraitCount=312;Files=$selected.Count;NoOutputWritten=$true}}
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
    Package='ZhaoHuoPortraitManager';Version=$Version;Platform='Windows x64';SteamAppId=1859910;DefaultCharacterId='player';CatalogSchemaVersion=2;InstallationSchemaVersion=4
    Catalog=[ordered]@{Path='VariantCatalog.json';SHA256=(Hash (Resolve-PackageFile 'VariantCatalog.json'))}
    Characters=3;Variants=$variants;PortraitCount=312;SharedPluginFiles=$shared;KnownGameFingerprintGroups=$supported
    ManagerValidation=$managerValidation;RegressionValidation=$regressionValidation;CatalogDataValidation=$catalogValidation;GuiValidation=$guiValidation;CompatibilityValidation=$compatibilityValidation;ConfigurationParserValidation=$configurationValidation;SharedDllUpdateValidation=$sharedUpdateValidation;InstallationValidation=$installationValidation;ArtworkValidation=$managerArtValidation;RuntimeValidation=$runtimeValidation;PromptValidation=$promptValidation
    CompatibilityCheck=[ordered]@{Trigger='ManagerCheckOrApply';AutoRunOnGameStart=$false;NetworkRequired=$false;FastPathRequiresSteamBuildAndCompleteFingerprint=$true;UnknownBuildMode='OfflineCompatibilityProbe';ProbePath=$probePath;ProbeSHA256=(Hash (Resolve-PackageFile $probePath));BaselinePath=$baselinePath;BaselineSHA256=(Hash (Resolve-PackageFile $baselinePath))}
    Scope='Three independently selectable characters, eight custom styles and per-character original mode. Runtime, art, GUI, fixture and installation evidence have separate scopes; not a full-story or universal future-update guarantee.'
    ProvenancePrivacy='Public text/provenance omits local username/desktop paths. Runtime binaries may retain their original compiler debug-path reference.'
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
