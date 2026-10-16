#requires -Version 5.1
[CmdletBinding()]
param(
    [string]$PackageRoot,
    [Parameter(Mandatory=$true)][string]$OutputPath
)
# Final production-data acceptance. This does not replay or rewrite the earlier
# synthetic installer suites. Their original reports remain byte-for-byte intact.
$ErrorActionPreference='Stop';Set-StrictMode -Version 2.0
if(-not $PackageRoot){$PackageRoot=Split-Path -Parent $PSScriptRoot}
$root=[IO.Path]::GetFullPath($PackageRoot).TrimEnd('\','/')
$output=[IO.Path]::GetFullPath($OutputPath)
if($output.StartsWith($root+'\',[StringComparison]::OrdinalIgnoreCase)-or $output-eq $root){throw 'Write the new evidence outside the frozen candidate, then copy it into verification after review.'}
if(Test-Path -LiteralPath $output){throw 'Evidence output already exists.'}
$checks=New-Object 'System.Collections.Generic.List[string]';$inputs=@{};$started=[DateTime]::UtcNow
function Hash([string]$Path){(Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash}
function CodeHash([string]$Path){
    $text=[IO.File]::ReadAllText($Path).TrimStart([char]0xFEFF).Replace("`r`n","`n").Replace("`r","`n")
    $sha=[Security.Cryptography.SHA256]::Create()
    try{([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($text)))).Replace('-','')}finally{$sha.Dispose()}
}
function Resolve-Input([string]$Relative){
    if([IO.Path]::IsPathRooted($Relative)-or $Relative.Contains(':')-or @($Relative-split '[\/]'|Where-Object{$_-in @('','..','.')}).Count){throw ('Unsafe input path: '+$Relative)}
    $path=[IO.Path]::GetFullPath((Join-Path $root $Relative))
    if(-not $path.StartsWith($root+'\',[StringComparison]::OrdinalIgnoreCase)){throw 'Input escaped package root.'}
    $path
}
function Track([string]$Relative){
    $path=Resolve-Input $Relative;$hash=Hash $path
    if($inputs.ContainsKey($Relative)-and $inputs[$Relative]-ne $hash){throw ('Input changed while checking: '+$Relative)}
    $inputs[$Relative]=$hash;$path
}
function Read-Json([string]$Relative){Get-Content -LiteralPath (Track $Relative) -Raw -Encoding UTF8|ConvertFrom-Json}
function Assert([bool]$Passed,[string]$Name){if(-not $Passed){throw ('FAIL: '+$Name)};$checks.Add($Name);Write-Host ('PASS: '+$Name)}
function Entries([object]$Hashes){if($Hashes-is [Array]){@($Hashes)}else{@($Hashes.PSObject.Properties|ForEach-Object{[pscustomobject]@{Path=$_.Name;Sha256=$_.Value}})}}
$backend=@('installer/ZhaoHuoInstaller.psm1','installer/AppearanceManager.ps1','installer/VariantSupport.ps1','installer/CharacterCatalog.ps1','installer/CharacterState.ps1','installer/CharacterManager.ps1','installer/CharacterTransactions.ps1','VariantCatalog.json','Install.ps1')
$bound=@($backend)+@('tests/Test-CharacterCatalog.ps1')
foreach($path in $bound){$null=Track $path}
$module=Import-Module (Resolve-Input 'installer/ZhaoHuoInstaller.psm1') -Force -PassThru
& $module {param($Root,$Output) Assert-ZHNoLink $Root;Assert-ZHNoLink $Output} $root $output
$catalog=& $module {param($Root) Read-ZHCharacterCatalog $Root} $root
Assert ($catalog.PackageReady-is [bool]-and $catalog.PackageReady) 'Final production catalog is ready and passes the strict schema/runtime pins'
$display=Get-PortraitCharacters -PackageRoot $root
$options=@($display.Characters|ForEach-Object{$_.Variants})
Assert (@($display.Characters).Count-eq 3-and $options.Count-eq 11-and @($options|Where-Object{-not $_.Available-or-not $_.Ready}).Count-eq 0) 'All 11 choices are available under the three independent roles'
Assert (@($options|Where-Object Kind -eq 'original').Count-eq 3) 'Each role exposes one original option without bundled original game images'
$expected=@{'player/natural'=47;'player/handsome'=47;'player/xianxia'=47;'player/white'=47;'player/black'=47;'player/veteran'=47;'tang-buyi/refined'=15;'xiahou-lan/refined'=15}
$legacy=@{natural='7E3062599926AC9266A7F5CCA3C9B073E5B66FBBA3205B8FED7A8DA3B21E2A71';handsome='63434840DC201BA14765C38AE8996674A07CF64E76518A7E3A85D55F59443D05';xianxia='E8EB408F31283581605425055AD742753C3E76D7C2D78065473117CB19794DBA'}
$variants=@{};$sourceLists=@{};$count=0
foreach($character in $catalog.Characters){
    Assert ((Hash (Track $character.LayoutSourcePath))-eq $character.LayoutSha256) ('Frozen role layout: '+$character.Id)
    foreach($variant in $character.Variants){
        if($variant.Kind-eq 'original'){continue}
        $key=$character.Id+'/'+$variant.Id
        Assert ($expected.ContainsKey($key)-and-not $variants.ContainsKey($key)-and @($variant.Files).Count-eq $expected[$key]) ('Final variant inventory: '+$key)
        $actions=@(& $module {param($Root,$Role,$Variant) Get-ZHCharacterAssetActions $Root $Role $Variant} $root $character $variant)
        Assert ($actions.Count-eq ($expected[$key]+$(if($character.Id-eq 'player'){0}else{1}))) ('Actual source hashes, isolated targets and layout geometry: '+$key)
        $files=@{};foreach($file in $variant.Files){$relative=$variant.SourcePath+'/'+$file.Name;$null=Track $relative;$files[$file.Name]=$file.Sha256}
        $sourceLists[$variant.SourcePath]=@($files.Keys);$variants[$key]=[pscustomobject]@{Definition=$variant;Files=$files};$count+=$files.Count
        if($character.Id-eq 'player'-and $legacy.ContainsKey($variant.Id)){Assert ($variant.AssetFingerprint-eq $legacy[$variant.Id]) ('Previously released 47 PNGs are unchanged: '+$variant.Id)}
        if($character.Id-ne 'player'){
            $fallback=if($character.Id-eq 'tang-buyi'){'hand'}else{'white'}
            Assert (@($variant.OriginalFallback).Count-eq 1-and $variant.OriginalFallback[0]-eq $fallback-and-not $files.ContainsKey($fallback+'.png')) ('Intentional original-only resource retained: '+$character.Id+'/'+$fallback)
        }
    }
}
Assert ($variants.Count-eq 8-and $count-eq 312) 'Exactly eight custom variants and 312 declared PNGs'
foreach($entry in $catalog.SharedFiles){Assert ((Hash (Track ('BepInEx/plugins/ZhaoHuoNatural/'+$entry.Name)))-eq $entry.Sha256) ('Verified shared component: '+$entry.Name)}
$artPath='verification/character-art-integrity.json';$art=Read-Json $artPath;$artSeen=@{}
Assert ($art.Passed-is [bool]-and $art.Passed-and $art.PortraitCount-eq 312-and @($art.Variants).Count-eq 8) 'Decoded artwork evidence covers all final PNGs'
foreach($item in $art.Variants){
    $key=$item.CharacterId+'/'+$item.Id
    if(-not $variants.ContainsKey($key)-or $artSeen.ContainsKey($key)){throw 'Unexpected/duplicate artwork evidence variant.'};$artSeen[$key]=$true
    $v=$variants[$key];$seen=@{}
    if($item.SourcePath-ne $v.Definition.SourcePath-or $item.AssetFingerprint-ne $v.Definition.AssetFingerprint-or $item.PortraitCount-ne $v.Files.Count-or @($item.Files).Count-ne $v.Files.Count){throw ('Artwork evidence differs: '+$key)}
    foreach($file in $item.Files){
        if($seen.ContainsKey($file.Name)-or-not $v.Files.ContainsKey($file.Name)-or $file.Sha256-ne $v.Files[$file.Name]-or $file.Width-le 0-or $file.Height-le 0-or $file.AlphaMin-ne 0-or $file.AlphaMax-le 0-or $file.AlphaMax-gt 255){throw ('Artwork file evidence differs: '+$key+'/'+$file.Name)};$seen[$file.Name]=$true
    }
}
Assert ($artSeen.Count-eq 8) 'Decoded dimensions/alpha evidence binds the actual 312 file hashes'
$promptPath='Prompts/multichar/index.json';$prompts=Read-Json $promptPath;$promptSeen=@{}
if($prompts.Complete-isnot [bool]-or-not $prompts.Complete-or $prompts.GenerationMethod-ne 'builtin imagegen'-or @($prompts.Assets).Count-ne 171){throw 'Final prompt index is incomplete.'}
foreach($asset in $prompts.Assets){
    $key=$asset.CharacterId+'/'+$asset.VariantId;$name=[IO.Path]::GetFileNameWithoutExtension([string]$asset.Name)+'.png';$id=$key+'/'+$name
    if(-not $variants.ContainsKey($key)-or $key-in @('player/natural','player/handsome','player/xianxia')-or $promptSeen.ContainsKey($id)-or-not $variants[$key].Files.ContainsKey($name)-or $asset.OutputSHA256-ne $variants[$key].Files[$name]){throw ('Prompt output binding differs: '+$id)}
    if(-not ([string]$asset.RecordPath).StartsWith('Prompts/',[StringComparison]::Ordinal)){throw 'Prompt source must be within Prompts.'}
    $null=Track $asset.RecordPath;$promptSeen[$id]=$true
}
Assert ($promptSeen.Count-eq 171) 'All 171 new final images are bound to included prompt records'
$reused=@()
foreach($path in @('verification/character-manager-tests.json','verification/character-manager-regression.json')){
    $report=Read-Json $path;$entries=@(Entries $report.CodeHashes);$seen=@{};$oldCatalog=$null;$unchanged=0
    if($report.status-ne 'passed'-or $report.CodeHashAlgorithm-ne 'SHA256-UTF8-noBOM-LF-v1'-or $report.assertionCount-ne $(if($path-like '*regression*'){74}else{64})){throw ('Historical fixture evidence is incomplete: '+$path)}
    foreach($entry in $entries){
        if($seen.ContainsKey($entry.Path)-or $entry.Sha256-notmatch '^[0-9A-Fa-f]{64}$'){throw 'Historical code binding is invalid.'};$seen[$entry.Path]=$true
        if($entry.Path-eq 'VariantCatalog.json'){$oldCatalog=$entry.Sha256;continue}
        if((CodeHash (Track $entry.Path))-ne $entry.Sha256){throw ('Source changed since fixture testing: '+$entry.Path)};$unchanged++
    }
    foreach($required in $backend){if($required-eq 'Install.ps1'-and $path-like '*regression*'){continue};if(-not $seen.ContainsKey($required)){throw ('Historical report misses binding: '+$required)}}
    Assert ($oldCatalog-match '^[0-9A-Fa-f]{64}$'-and $unchanged-gt 0) ('Historical report retained; every non-Catalog tested source still matches: '+$path)
    $reused+=[pscustomobject]@{Path=$path;Sha256=$inputs[$path];HistoricalCatalogCodeSha256=$oldCatalog;AssertionCount=$report.assertionCount;UnchangedNonCatalogCodeFiles=$unchanged;SourceSuiteRerun=$false;Scope='Original synthetic-fixture report retained unchanged. Production Catalog data is separately validated in this acceptance; the old hash is not relabeled as a new test run.'}
}
foreach($source in $sourceLists.Keys){
    $actual=@(& $module {param($Root) Get-ZHFiles $Root} (Resolve-Input $source))
    if($actual.Count-ne $sourceLists[$source].Count){throw 'Artwork source inventory changed during validation.'}
}
foreach($relative in $inputs.Keys){if((Hash (Resolve-Input $relative))-ne $inputs[$relative]){throw ('Checked input changed during validation: '+$relative)}}
Assert $true 'All checked package inputs and exact portrait inventories remain unchanged'
$result=[ordered]@{
    Passed=$true;DateUtc=[DateTime]::UtcNow.ToString('o');PowerShell=$PSVersionTable.PSVersion.ToString();DurationSeconds=[Math]::Round(([DateTime]::UtcNow-$started).TotalSeconds,2)
    DataOnlyAcceptance=$true;SourceSuitesRerun=$false;ActualGameRun=$false;PackageReady=$true;ReadOnlyPackageUnchanged=$true
    CatalogSha256=$inputs['VariantCatalog.json'];CatalogCodeSha256=(CodeHash (Resolve-Input 'VariantCatalog.json'));PortraitCount=312;CustomVariantCount=8;CharacterCount=3
    AssertionCount=$checks.Count;Checks=$checks.ToArray();ReusedReports=$reused
    ArtworkEvidence=[pscustomobject]@{Path=$artPath;Sha256=$inputs[$artPath]};PromptEvidence=[pscustomobject]@{Path=$promptPath;Sha256=$inputs[$promptPath]}
    CodeHashAlgorithm='SHA256-UTF8-noBOM-LF-v1';CodeHashes=@($bound|ForEach-Object{[pscustomobject]@{Path=$_;Sha256=(CodeHash (Resolve-Input $_))}})
    Scope='Read-only final production-data/API acceptance: real 312 PNG bytes, exact eight inventories/fingerprints, role layout validation, readiness/availability, shared pins, old 141 preservation and new 171 prompt bindings. Existing decoded-pixel evidence is checked against file hashes, not rerun here. Original 64/74 synthetic suites are reused only for unchanged source; their historical Catalog hashes remain intact. No game files, installation or game execution are accessed.'
}
$parent=[IO.Path]::GetDirectoryName($output);[IO.Directory]::CreateDirectory($parent)|Out-Null
[IO.File]::WriteAllText($output,($result|ConvertTo-Json -Depth 14),(New-Object Text.UTF8Encoding($false)))
[pscustomobject]$result|Select-Object Passed,AssertionCount,PortraitCount,CustomVariantCount,CatalogSha256|ConvertTo-Json
