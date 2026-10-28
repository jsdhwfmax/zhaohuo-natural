#requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$TargetPackagePath,
    [Parameter(Mandatory=$true)][string[]]$BasePackagePaths,
    [Parameter(Mandatory=$true)][ValidatePattern('^[A-Fa-f0-9]{64}$')][string]$TargetManifestSha256,
    [Parameter(Mandatory=$true)][string]$OutputDirectory
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version 2.0
$repo=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$utf8=New-Object Text.UTF8Encoding($false)
$utf8Bom=New-Object Text.UTF8Encoding($true)
function Hash([string]$Path){(Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash}
function Hash-Bytes([byte[]]$Bytes){
    $sha=[Security.Cryptography.SHA256]::Create()
    try{([BitConverter]::ToString($sha.ComputeHash($Bytes))).Replace('-','')}finally{$sha.Dispose()}
}
function Resolve-Safe([string]$Root,[string]$Relative){
    if([string]::IsNullOrWhiteSpace($Relative)-or [IO.Path]::IsPathRooted($Relative)-or $Relative.Contains(':')-or $Relative.Contains('\')-or $Relative-match '[\x00-\x1f<>"|?*]' -or @($Relative.Split('/')|Where-Object{$_-in @('','.','..')-or $_-match '[. ]$'-or $_-match '^(?i:CON|PRN|AUX|NUL|COM[0-9]|LPT[0-9])(?:\.|$)'}).Count){throw ('Unsafe relative path: '+$Relative)}
    $path=[IO.Path]::GetFullPath((Join-Path $Root $Relative))
    if(-not $path.StartsWith($Root.TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase)){throw 'Path escaped its root.'}
    return $path
}
function Assert-NoLink([string]$Path){
    $cursor=[IO.Path]::GetFullPath($Path)
    while($cursor){
        if(Test-Path -LiteralPath $cursor){if(((Get-Item -LiteralPath $cursor -Force).Attributes-band [IO.FileAttributes]::ReparsePoint)-ne 0){throw ('Links are not supported: '+$cursor)}}
        $next=Split-Path -Parent $cursor
        if($next-eq $cursor){break};$cursor=$next
    }
}
function Read-Package([string]$Root,[string]$ExpectedManifestHash){
    $Root=[IO.Path]::GetFullPath($Root).TrimEnd('\');Assert-NoLink $Root
    if(-not(Test-Path -LiteralPath $Root -PathType Container)){throw ('Package not found: '+$Root)}
    $manifestPath=Resolve-Safe $Root 'ReleaseManifest.json';Assert-NoLink $manifestPath
    $manifestBytes=[IO.File]::ReadAllBytes($manifestPath);$manifestHash=Hash-Bytes $manifestBytes
    if($ExpectedManifestHash-and $manifestHash-ne $ExpectedManifestHash){throw 'Target release manifest does not match the independently verified release.'}
    $manifest=[Text.Encoding]::UTF8.GetString($manifestBytes).TrimStart([char]0xFEFF)|ConvertFrom-Json
    if($manifest.Package-ne 'ZhaoHuoPortraitManager'-or $manifest.Version-notmatch '^\d+\.\d+\.\d+$'){throw 'Unexpected package identity.'}
    $entries=@{};$files=@($manifest.Files)
    if(-not $files.Count){throw 'Empty release inventory.'}
    foreach($entry in $files){
        $path=Resolve-Safe $Root ([string]$entry.Path);Assert-NoLink $path
        if($entries.ContainsKey([string]$entry.Path)-or $entry.Path-in @('ReleaseManifest.json','SHA256SUMS.txt')-or $entry.SHA256-notmatch '^[A-Fa-f0-9]{64}$'-or $entry.Bytes-is [string]-or [long]$entry.Bytes-lt 0){throw ('Invalid release entry: '+$entry.Path)}
        $file=Get-Item -LiteralPath $path -Force
        if($file.PSIsContainer-or $file.Length-ne $entry.Bytes-or (Hash $path)-ne $entry.SHA256){throw ('Package bytes differ: '+$entry.Path)}
        $entries[[string]$entry.Path]=[pscustomobject]@{Path=[string]$entry.Path;SHA256=([string]$entry.SHA256).ToUpperInvariant();Bytes=[long]$entry.Bytes}
    }
    foreach($relative in @('ReleaseManifest.json','SHA256SUMS.txt')){
        $path=Resolve-Safe $Root $relative;Assert-NoLink $path
        $entries[$relative]=[pscustomobject]@{Path=$relative;SHA256=(Hash $path);Bytes=(Get-Item -LiteralPath $path).Length}
    }
    if($entries['ReleaseManifest.json'].SHA256-ne $manifestHash){throw 'Release manifest changed while validating its package.'}
    $sumSeen=@{}
    foreach($line in [IO.File]::ReadAllLines((Join-Path $Root 'SHA256SUMS.txt'))){
        if($line-notmatch '^([A-Fa-f0-9]{64})  (.+)$'){throw 'Invalid SHA256SUMS line.'}
        $sumHash=$Matches[1];$relative=$Matches[2];$null=Resolve-Safe $Root $relative
        if($sumSeen.ContainsKey($relative)-or $relative-eq 'SHA256SUMS.txt'-or -not $entries.ContainsKey($relative)-or $entries[$relative].SHA256-ne $sumHash){throw ('SHA256SUMS mismatch: '+$relative)}
        $sumSeen[$relative]=$true
    }
    if($sumSeen.Count-ne ($entries.Count-1)){throw 'SHA256SUMS inventory differs.'}
    return [pscustomobject]@{Root=$Root;Version=[string]$manifest.Version;Entries=$entries}
}
$target=Read-Package $TargetPackagePath $TargetManifestSha256
$bases=@($BasePackagePaths|ForEach-Object{Read-Package $_ ''})
if($bases.Count-eq 0-or @($bases.Version|Sort-Object -Unique).Count-ne $bases.Count){throw 'Provide one complete official package for each supported base version.'}
$output=[IO.Path]::GetFullPath($OutputDirectory).TrimEnd('\');Assert-NoLink $output
foreach($root in @($target.Root)+@($bases.Root)+@($repo)){
    if($output.Equals($root,[StringComparison]::OrdinalIgnoreCase)-or $output.StartsWith($root+'\',[StringComparison]::OrdinalIgnoreCase)){throw 'Output must be outside all input package roots and the repository.'}
}
$name='ZhaoHuoPortraitManager-v'+$target.Version+'-small-update'
$zip=Join-Path $output ($name+'.zip')
if(Test-Path -LiteralPath $zip){throw 'Update ZIP already exists. Use a new output directory.'}
$stage=Join-Path (Join-Path $output ('staging-'+[Guid]::NewGuid().ToString('N'))) $name
New-Item -ItemType Directory -Path $stage -Force|Out-Null
$entries=@()
foreach($relative in @($target.Entries.Keys|Sort-Object)){
    $item=$target.Entries[$relative]
    $reuse=$relative-notin @('ReleaseManifest.json','SHA256SUMS.txt')
    foreach($base in $bases){if(-not $base.Entries.ContainsKey($relative)-or $base.Entries[$relative].SHA256-ne $item.SHA256-or $base.Entries[$relative].Bytes-ne $item.Bytes){$reuse=$false}}
    $source=if($reuse){'Reuse'}else{'Payload'}
    if(-not $reuse){
        $destination=Resolve-Safe $stage ('Payload/'+$relative)
        New-Item -ItemType Directory -Path (Split-Path -Parent $destination) -Force|Out-Null
        Copy-Item -LiteralPath (Resolve-Safe $target.Root $relative) -Destination $destination
        if((Hash $destination)-ne $item.SHA256){throw ('Target changed while staging: '+$relative)}
    }
    $entries+=[pscustomobject][ordered]@{Path=$relative;SHA256=$item.SHA256;Bytes=$item.Bytes;Source=$source}
}
$manifest=[ordered]@{
    SchemaVersion=1;TargetVersion=$target.Version;TargetFolderName=('ZhaoHuoPortraitManager-v'+$target.Version+'-win-x64')
    TargetManifestSHA256=$target.Entries['ReleaseManifest.json'].SHA256;TargetSumsSHA256=$target.Entries['SHA256SUMS.txt'].SHA256
    SupportedBaseVersions=@($bases.Version|Sort-Object)
    TargetRelease=('https://github.com/jsdhwfmax/zhaohuo-natural/releases/tag/v'+$target.Version)
    Files=$entries
}
$manifestPath=Join-Path $stage 'UpdateManifest.json'
[IO.File]::WriteAllText($manifestPath,($manifest|ConvertTo-Json -Depth 7),$utf8)
$template=[IO.File]::ReadAllText((Join-Path $repo 'updates/Update-Manager.ps1'))
if(([regex]::Matches($template,'__UPDATE_MANIFEST_SHA256__')).Count-ne 1){throw 'Updater template must contain exactly one manifest hash placeholder.'}
[IO.File]::WriteAllText((Join-Path $stage 'Update-Manager.ps1'),$template.Replace('__UPDATE_MANIFEST_SHA256__',(Hash $manifestPath)),$utf8Bom)
foreach($relative in @('updates/双击更新管理器.cmd','updates/先看这里.txt','LICENSE')){
    Copy-Item -LiteralPath (Join-Path $repo $relative) -Destination (Join-Path $stage ([IO.Path]::GetFileName($relative)))
}
$sums=@(Get-ChildItem -LiteralPath $stage -Recurse -File|Sort-Object FullName|ForEach-Object{(Hash $_.FullName)+'  '+$_.FullName.Substring($stage.Length+1).Replace('\','/')})
[IO.File]::WriteAllLines((Join-Path $stage 'UPDATE-SHA256SUMS.txt'),$sums,$utf8)
Compress-Archive -LiteralPath $stage -DestinationPath $zip -CompressionLevel Optimal
$zipHash=Hash $zip
[IO.File]::WriteAllText(($zip+'.sha256'),($zipHash+'  '+[IO.Path]::GetFileName($zip)+[Environment]::NewLine),[Text.Encoding]::ASCII)
$result=[ordered]@{Status='built';Version=$target.Version;SupportedBaseVersions=$manifest.SupportedBaseVersions;ZipPath=$zip;ZipSHA256=$zipHash;ZipBytes=(Get-Item -LiteralPath $zip).Length;Stage=$stage;TargetFiles=$entries.Count;PayloadFiles=@($entries|Where-Object Source -eq Payload).Count;PayloadBytes=(@($entries|Where-Object Source -eq Payload)|Measure-Object Bytes -Sum).Sum;ReusedFiles=@($entries|Where-Object Source -eq Reuse).Count;ReusedBytes=(@($entries|Where-Object Source -eq Reuse)|Measure-Object Bytes -Sum).Sum;TargetManifestSHA256=$manifest.TargetManifestSHA256;TargetSumsSHA256=$manifest.TargetSumsSHA256;UpdateManifestSHA256=(Hash $manifestPath);BuilderSHA256=(Hash $PSCommandPath);UpdaterTemplateSHA256=(Hash (Join-Path $repo 'updates/Update-Manager.ps1'))}
[IO.File]::WriteAllText((Join-Path $output 'build-small-update.json'),($result|ConvertTo-Json -Depth 5),$utf8)
[pscustomobject]$result
