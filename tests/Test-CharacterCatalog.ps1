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
$bound=@($backend)+@('tests/Test-CharacterCatalog.ps1','scripts/CharacterReleaseRules.ps1','scripts/artwork-patch-v2.2.1.json')
foreach($path in $bound){$null=Track $path}
. (Resolve-Input 'scripts/CharacterReleaseRules.ps1')
$module=Import-Module (Resolve-Input 'installer/ZhaoHuoInstaller.psm1') -Force -PassThru
& $module {param($Root,$Output) Assert-ZHNoLink $Root;Assert-ZHNoLink $Output} $root $output
$catalog=& $module {param($Root) Read-ZHCharacterCatalog $Root} $root
Assert ($catalog.PackageReady-is [bool]-and $catalog.PackageReady) 'Final production catalog is ready and passes the strict schema/runtime pins'
$display=Get-PortraitCharacters -PackageRoot $root
$options=@($display.Characters|ForEach-Object{$_.Variants})
Assert (@($display.Characters).Count-eq $releaseRoleIds.Count-and $options.Count-eq $releaseChoiceCount-and @($options|Where-Object{-not $_.Available-or-not $_.Ready}).Count-eq 0) ('All '+$releaseChoiceCount+' choices are available under the seven independent roles')
Assert (@($options|Where-Object Kind -eq 'original').Count-eq $releaseRoleIds.Count) 'Each role exposes one original option without bundled original game images'
$expected=$releaseCounts
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
        Assert-ReleaseArtworkRevision $key $variant
        Assert $true ('Exact frozen or approved repaired artwork revision: '+$key)
        if($character.Id-ne 'player'){
            $fallback=@($releaseFallbacks[$character.Id]);$actualFallback=@($variant.OriginalFallback)
            Assert ($actualFallback.Count-eq $fallback.Count-and @($actualFallback|Where-Object{$_-notin $fallback}).Count-eq 0-and @($fallback|Where-Object{$files.ContainsKey($_+'.png')}).Count-eq 0) ('Intentional original-art fallback: '+$key)
        }
    }
}
Assert ($variants.Count-eq $releaseCustomCount-and $count-eq $releasePortraitCount) ('Exactly '+$releaseCustomCount+' custom variants and '+$releasePortraitCount+' declared PNGs')
foreach($entry in $catalog.SharedFiles){Assert ((Hash (Track ('BepInEx/plugins/ZhaoHuoNatural/'+$entry.Name)))-eq $entry.Sha256) ('Verified shared component: '+$entry.Name)}
$artPath='verification/character-art-integrity.json';$art=Read-Json $artPath;$artSeen=@{}
Assert ($art.Passed-is [bool]-and $art.Passed-and $art.PortraitCount-eq $releasePortraitCount-and @($art.Variants).Count-eq $releaseCustomCount) 'Decoded artwork evidence covers all final PNGs'
foreach($item in $art.Variants){
    $key=$item.CharacterId+'/'+$item.Id
    if(-not $variants.ContainsKey($key)-or $artSeen.ContainsKey($key)){throw 'Unexpected/duplicate artwork evidence variant.'};$artSeen[$key]=$true
    $v=$variants[$key];$seen=@{}
    if($item.SourcePath-ne $v.Definition.SourcePath-or $item.AssetFingerprint-ne $v.Definition.AssetFingerprint-or $item.PortraitCount-ne $v.Files.Count-or @($item.Files).Count-ne $v.Files.Count){throw ('Artwork evidence differs: '+$key)}
    foreach($file in $item.Files){
        if($seen.ContainsKey($file.Name)-or-not $v.Files.ContainsKey($file.Name)-or $file.Sha256-ne $v.Files[$file.Name]-or $file.Width-le 0-or $file.Height-le 0-or $file.AlphaMin-ne 0-or $file.AlphaMax-le 0-or $file.AlphaMax-gt 255){throw ('Artwork file evidence differs: '+$key+'/'+$file.Name)};$seen[$file.Name]=$true
    }
}
Assert ($artSeen.Count-eq $releaseCustomCount) ('Decoded dimensions/alpha evidence binds all '+$releasePortraitCount+' file hashes')
$promptSeen=@{};$promptEvidence=@()
foreach($group in $releasePromptGroups){
    $promptPath=$group.Path;$prompts=Read-Json $promptPath
    if($prompts.Complete-isnot [bool]-or-not $prompts.Complete-or $prompts.GenerationMethod-ne 'builtin imagegen'-or @($prompts.Assets).Count-ne $group.Count){throw ('Final prompt index is incomplete: '+$promptPath)}
    foreach($asset in $prompts.Assets){
        $key=$asset.CharacterId+'/'+$asset.VariantId;$name=[IO.Path]::GetFileNameWithoutExtension([string]$asset.Name)+'.png';$id=$key+'/'+$name
        if(-not $variants.ContainsKey($key)-or $key-notin $group.Variants-or-not $variants[$key].Files.ContainsKey($name)){throw ('Prompt output identity differs: '+$id)}
        $expect=Get-ReleasePromptExpectation $group $key $name $variants[$key].Files[$name];$id=$expect.Identity
        if($promptSeen.ContainsKey($id)-or $asset.OutputSHA256-ne $expect.Sha256){throw ('Prompt output binding differs: '+$id)}
        if(-not ([string]$asset.RecordPath).StartsWith('Prompts/',[StringComparison]::Ordinal)){throw 'Prompt source must be within Prompts.'}
        $null=Track $asset.RecordPath;$promptSeen[$id]=$true
    }
    $promptEvidence+=@([pscustomobject]@{Path=$promptPath;Sha256=$inputs[$promptPath];AssetCount=$group.Count})
}
Assert ($promptSeen.Count-eq (@($releasePromptGroups|Measure-Object Count -Sum)[0].Sum)) 'Every required generated image is bound to an included actual prompt record'
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
    CatalogSha256=$inputs['VariantCatalog.json'];CatalogCodeSha256=(CodeHash (Resolve-Input 'VariantCatalog.json'));PortraitCount=$releasePortraitCount;CustomVariantCount=$releaseCustomCount;CharacterCount=$releaseRoleIds.Count
    AssertionCount=$checks.Count;Checks=$checks.ToArray();ReusedReports=$reused
    ArtworkEvidence=[pscustomobject]@{Path=$artPath;Sha256=$inputs[$artPath]};PromptEvidence=$promptEvidence
    CodeHashAlgorithm='SHA256-UTF8-noBOM-LF-v1';CodeHashes=@($bound|ForEach-Object{[pscustomobject]@{Path=$_;Sha256=(CodeHash (Resolve-Input $_))}})
    Scope='Read-only final production-data/API acceptance: 447 PNGs, 432 unchanged v2.2 portraits, fifteen approved female repairs, seven role layouts, readiness, shared pins and current/historical prompt bindings. Decoded-pixel evidence is checked against file hashes, not rerun here. The latest 64/74 synthetic suites are reused only for unchanged source; their tested Catalog hashes remain intact. No game files, installation or game execution are accessed.'
}
$parent=[IO.Path]::GetDirectoryName($output);[IO.Directory]::CreateDirectory($parent)|Out-Null
[IO.File]::WriteAllText($output,($result|ConvertTo-Json -Depth 14),(New-Object Text.UTF8Encoding($false)))
[pscustomobject]$result|Select-Object Passed,AssertionCount,PortraitCount,CustomVariantCount,CatalogSha256|ConvertTo-Json
