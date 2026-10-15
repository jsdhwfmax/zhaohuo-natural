#requires -Version 5.1
[CmdletBinding()]
param(
    [ValidatePattern('^[0-9]+\.[0-9]+\.[0-9]+$')][string]$Version = '1.0.0',
    [string]$OutputDirectory
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
$repo = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
if (-not $OutputDirectory) { $OutputDirectory = Join-Path $repo 'dist' }
$OutputDirectory = [IO.Path]::GetFullPath($OutputDirectory)
New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
$name = "ZhaoHuoNatural-v$Version-build25953419-win-x64"
$zipPath = Join-Path $OutputDirectory ($name + '.zip')
if (Test-Path -LiteralPath $zipPath) { throw "Output already exists; use a new output directory: $zipPath" }
$workRoot = Join-Path $OutputDirectory ('staging-' + [Guid]::NewGuid().ToString('N'))
$stage = Join-Path $workRoot $name
New-Item -ItemType Directory -Path $stage -Force | Out-Null
$folders = @('BepInEx','Loader','Dependencies','installer','Source','Prompts','docs','verification')
$rootFiles = @('Install.cmd','Uninstall.cmd','Install.ps1','Uninstall.ps1','README.md','LICENSE','ARTWORK-NOTICE.md','THIRD_PARTY_NOTICES.md','CHANGELOG.md')
foreach ($folder in $folders) {
    $source = Join-Path $repo $folder
    if (-not (Test-Path -LiteralPath $source -PathType Container)) { throw "Missing package directory: $folder" }
    Get-ChildItem -LiteralPath $source -Recurse -Force | ForEach-Object {
        if (($_.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw "Package contains a link: $($_.FullName)" }
    }
    Copy-Item -LiteralPath $source -Destination (Join-Path $stage $folder) -Recurse
}
foreach ($file in $rootFiles) { Copy-Item -LiteralPath (Join-Path $repo $file) -Destination (Join-Path $stage $file) }
$files = @(Get-ChildItem -LiteralPath $stage -Recurse -File)
foreach ($file in $files) {
    if ($file.Extension -in @('.pdb','.rsp')) {
        if (-not $file.FullName.StartsWith($stage.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)) { throw 'Unexpected staging path.' }
        Remove-Item -LiteralPath $file.FullName
        continue
    }
    if ($file.Extension -in @('.log','.tmp') -or $file.Name -in @('Mortal.exe','Assembly-CSharp.dll','Mortal.Core.dll','Mortal.Story.dll','Fungus.dll','ActiveManifest.json')) {
        throw "Unexpected build/local/game file in public package: $($file.FullName)"
    }
}
$requiredFiles = @(
    'BepInEx\plugins\ZhaoHuoNatural\ZhaoHuoNatural.dll',
    'BepInEx\plugins\ZhaoHuoNatural\portrait-map.txt',
    'BepInEx\plugins\ZhaoHuoNatural\portrait-layout.tsv',
    'Loader\winhttp.dll', 'Dependencies\BepInEx\runtime-manifest.json',
    'installer\Gui.ps1', 'installer\ZhaoHuoInstaller.psm1'
)
foreach ($relative in $requiredFiles) {
    if (-not (Test-Path -LiteralPath (Join-Path $stage $relative) -PathType Leaf)) { throw "Required release file missing: $relative" }
}
$runtime = Get-Content -LiteralPath (Join-Path $stage 'Dependencies\BepInEx\runtime-manifest.json') -Raw -Encoding UTF8 | ConvertFrom-Json
foreach ($entry in $runtime.Files) {
    $runtimePath = [IO.Path]::GetFullPath((Join-Path (Join-Path $stage 'Dependencies\BepInEx\files') $entry.RelativePath))
    if (-not $runtimePath.StartsWith((Join-Path $stage 'Dependencies\BepInEx\files') + '\', [StringComparison]::OrdinalIgnoreCase) -or
        -not (Test-Path -LiteralPath $runtimePath -PathType Leaf) -or
        (Get-FileHash -LiteralPath $runtimePath -Algorithm SHA256).Hash -ne $entry.Sha256) { throw "Runtime hash validation failed: $($entry.RelativePath)" }
}
$files = @(Get-ChildItem -LiteralPath $stage -Recurse -File)
$portraits = @(Get-ChildItem -LiteralPath (Join-Path $stage 'BepInEx\plugins\ZhaoHuoNatural\Portraits') -File -Filter '*.png')
if ($portraits.Count -ne 47) { throw "Expected 47 portraits, got $($portraits.Count)" }
$manifest = [ordered]@{
    Package = 'ZhaoHuoNatural'
    Version = $Version
    SteamAppId = 1859910
    SteamBuildId = 25953419
    GameVersion = 'release_1.0.6000.0'
    PortraitCount = $portraits.Count
    Files = @($files | Sort-Object FullName | ForEach-Object {
        [ordered]@{Path=$_.FullName.Substring($stage.Length+1).Replace('\','/'); SHA256=(Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash; Bytes=$_.Length}
    })
}
[IO.File]::WriteAllText((Join-Path $stage 'ReleaseManifest.json'),($manifest | ConvertTo-Json -Depth 8),(New-Object Text.UTF8Encoding($false)))
$sums = @(Get-ChildItem -LiteralPath $stage -Recurse -File | Sort-Object FullName | ForEach-Object {
    '{0}  {1}' -f (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash,$_.FullName.Substring($stage.Length+1).Replace('\','/')
})
[IO.File]::WriteAllLines((Join-Path $stage 'SHA256SUMS.txt'),$sums,(New-Object Text.UTF8Encoding($false)))
Compress-Archive -LiteralPath $stage -DestinationPath $zipPath -CompressionLevel Optimal
$hash = (Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash
[IO.File]::WriteAllText(($zipPath + '.sha256'),($hash + '  ' + [IO.Path]::GetFileName($zipPath) + [Environment]::NewLine),[Text.Encoding]::ASCII)
# Keep the staging directory for inspection; no recursive deletion is needed.
Write-Output "Release archive: $zipPath"
Write-Output "SHA256: $hash"
Write-Output "Inspection directory: $stage"
