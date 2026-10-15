#requires -Version 5.1
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
$repo = Split-Path -Parent $PSScriptRoot
$module = Import-Module (Join-Path $repo 'installer\ZhaoHuoInstaller.psm1') -Force -PassThru
$work = Join-Path $PSScriptRoot ('.work\run-' + [Guid]::NewGuid().ToString('N'))
$package = Join-Path $work 'Offline Package'
New-Item -ItemType Directory -Path $package -Force | Out-Null
New-Item -ItemType Directory -Path (Join-Path $package 'Dependencies\BepInEx') -Force | Out-Null
Copy-Item -LiteralPath (Join-Path $repo 'Dependencies\BepInEx\runtime-manifest.json') -Destination (Join-Path $package 'Dependencies\BepInEx')
Copy-Item -LiteralPath (Join-Path $repo 'Dependencies\BepInEx\files') -Destination (Join-Path $package 'Dependencies\BepInEx') -Recurse
Copy-Item -LiteralPath (Join-Path $repo 'Loader') -Destination $package -Recurse
$payload = Join-Path $package 'BepInEx\plugins\ZhaoHuoNatural'
New-Item -ItemType Directory -Path (Join-Path $payload 'Portraits') -Force | Out-Null
$portraitNames = @(& $module { $script:PortraitNames })
$png = [Convert]::FromBase64String('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aZf8AAAAASUVORK5CYII=')
foreach ($name in $portraitNames) { [IO.File]::WriteAllBytes((Join-Path $payload ('Portraits\' + $name + '.png')), $png) }
foreach ($name in @('ZhaoHuoNatural.dll','portrait-map.txt','portrait-layout.tsv')) { [IO.File]::WriteAllText((Join-Path $payload $name), 'fixture payload; never executed') }
$script:Counter = 0
$script:Assertions = New-Object 'System.Collections.Generic.List[string]'
$script:FixtureGameHashes = [ordered]@{}
$pe = New-Object byte[] 256
$pe[0] = 0x4D; $pe[1] = 0x5A; $pe[0x3C] = 0x80; $pe[0x80] = 0x50; $pe[0x81] = 0x45; $pe[0x84] = 0x64; $pe[0x85] = 0x86
function New-Fixture([string]$Name, [switch]$Existing) {
    $script:Counter++
    $game = Join-Path $work (('game-{0:D2}-' -f $script:Counter) + $Name)
    New-Item -ItemType Directory -Path (Join-Path $game 'Mortal_Data\Managed') -Force | Out-Null
    [IO.File]::WriteAllBytes((Join-Path $game 'Mortal.exe'), $pe)
    [IO.File]::WriteAllBytes((Join-Path $game 'UnityPlayer.dll'), $pe)
    foreach ($name in @('Assembly-CSharp.dll','Mortal.Core.dll','Mortal.Story.dll','Fungus.dll')) {
        $file = Join-Path $game ('Mortal_Data\Managed\' + $name)
        [IO.File]::WriteAllText($file, ('fixture-game-assembly:' + $name))
        $script:FixtureGameHashes[$name] = (Get-FileHash -LiteralPath $file).Hash
    }
    if ($Existing) {
        $dependencies = Get-Content -LiteralPath (Join-Path $package 'Dependencies\BepInEx\runtime-manifest.json') -Raw | ConvertFrom-Json
        foreach ($entry in $dependencies.Files) {
            $destination = Join-Path $game $entry.RelativePath
            New-Item -ItemType Directory -Path (Split-Path -Parent $destination) -Force | Out-Null
            Copy-Item -LiteralPath (Join-Path (Join-Path $package 'Dependencies\BepInEx\files') $entry.RelativePath) -Destination $destination
        }
        Copy-Item -LiteralPath (Join-Path $package 'Loader\winhttp.dll') -Destination (Join-Path $game 'winhttp.dll')
    }
    return $game
}
function Assert-True([bool]$Condition,[string]$Name) {
    if (-not $Condition) { throw "FAIL: $Name" }
    $script:Assertions.Add($Name)
    Write-Host "PASS: $Name"
}
function Assert-Rejected([scriptblock]$Operation,[string]$Pattern,[string]$Name) {
    $rejected = $false
    try { & $Operation | Out-Null } catch { $rejected = $_.Exception.Message -like $Pattern; if (-not $rejected) { throw } }
    Assert-True $rejected $Name
}
function Read-State([string]$Game) { return (Get-Content -LiteralPath (Join-Path $Game 'BepInEx\ZhaoHuoNatural-install\ActiveManifest.json') -Raw | ConvertFrom-Json) }
function Write-State([string]$Game,[object]$Value) { [IO.File]::WriteAllText((Join-Path $Game 'BepInEx\ZhaoHuoNatural-install\ActiveManifest.json'),($Value | ConvertTo-Json -Depth 14),(New-Object Text.UTF8Encoding($true))) }
$quiet = { param($Message,$Level) }
$start = [DateTime]::UtcNow
try {
    $clean = New-Fixture 'clean'
    # Only this test process changes the module's expected hashes, to allow
    # self-contained dummy game assemblies. Production scripts expose no bypass.
    & $module { param($Hashes) $script:GameHashes = $Hashes } $script:FixtureGameHashes
    Install-ZhaoHuo -GamePath $clean -PackageRoot $package -CheckOnly -Log $quiet | Out-Null
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $clean 'BepInEx'))) 'Clean CheckOnly creates no game files'
    Install-ZhaoHuo -GamePath $clean -PackageRoot $package -Log $quiet | Out-Null
    $state = Read-State $clean
    Assert-True ($state.SchemaVersion -eq 3 -and $state.Environment -eq 'CleanGame' -and @($state.OwnedFiles).Count -eq 66) 'Clean install records all 66 owned files in schema 3'
    Assert-True (@($state.GameAssemblySha256.PSObject.Properties).Count -eq 4) 'Manifest records all four game hashes'
    Assert-True ((Get-FileHash -LiteralPath (Join-Path $clean 'winhttp.dll')).Hash -eq 'D3B62F4C9C3E2196EF82603C52D6B98C043A0D6C125C081FD33D7CA3798B41B8') 'Clean install uses verified official x64 loader'
    $manifestPath = Join-Path $clean 'BepInEx\ZhaoHuoNatural-install\ActiveManifest.json'
    $before = (Get-FileHash -LiteralPath $manifestPath).Hash
    Install-ZhaoHuo -GamePath $clean -PackageRoot $package -Log $quiet | Out-Null
    Assert-True ((Get-FileHash -LiteralPath $manifestPath).Hash -eq $before) 'Repeated identical install is a no-op'
    Uninstall-ZhaoHuo -GamePath $clean -CheckOnly -Log $quiet
    Assert-True (Test-Path -LiteralPath (Join-Path $clean 'winhttp.dll')) 'Uninstall CheckOnly does not remove loader'
    $normal = Join-Path $clean 'BepInEx\plugins\ZhaoHuoNatural\Portraits\normal.png'
    [IO.File]::WriteAllText($normal,'edited portrait')
    $extra = Join-Path $clean 'BepInEx\plugins\OtherPlugin.dll'
    [IO.File]::WriteAllText($extra,'unrelated user mod')
    $extraCore = Join-Path $clean 'BepInEx\core\user-note.txt'
    [IO.File]::WriteAllText($extraCore,'user file')
    New-Item -ItemType Directory -Path (Join-Path $clean 'BepInEx\plugins\ZhaoHuoNatural\Diagnostics\test') -Force | Out-Null
    [IO.File]::WriteAllText((Join-Path $clean 'BepInEx\plugins\ZhaoHuoNatural\Diagnostics\test\PASS.txt'),'diagnostic')
    Uninstall-ZhaoHuo -GamePath $clean -Log $quiet
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $clean 'winhttp.dll')) -and -not (Test-Path -LiteralPath (Join-Path $clean 'doorstop_config.ini'))) 'Clean uninstall restores absent loader and configuration'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $clean 'BepInEx\core\BepInEx.Core.dll')) -and (Test-Path -LiteralPath $extraCore) -and (Test-Path -LiteralPath $extra)) 'Clean uninstall removes only owned runtime and preserves other mods/files'
    $preserved = @(Get-ChildItem -LiteralPath (Join-Path $clean 'BepInEx\ZhaoHuoNatural-install') -Recurse -File | Where-Object { $_.FullName -match 'Preserved-' })
    Assert-True (@($preserved | Where-Object { $_.Name -eq 'normal.png' }).Count -eq 1 -and @($preserved | Where-Object { $_.Name -eq 'PASS.txt' }).Count -eq 1) 'Modified portrait and runtime diagnostics are preserved'
    Uninstall-ZhaoHuo -GamePath $clean -Log $quiet
    Assert-True (Test-Path -LiteralPath $extra) 'Repeated uninstall is harmless'

    $existing = New-Fixture 'existing6' -Existing
    Add-Content -LiteralPath (Join-Path $existing 'doorstop_config.ini') -Value '# user comment to preserve'
    $configHash = (Get-FileHash -LiteralPath (Join-Path $existing 'doorstop_config.ini')).Hash
    $coreHash = (Get-FileHash -LiteralPath (Join-Path $existing 'BepInEx\core\BepInEx.Core.dll')).Hash
    $legacy = Join-Path $existing 'BepInEx\plugins\Tianfei\MortalBeauty.dll'
    New-Item -ItemType Directory -Path (Split-Path -Parent $legacy) -Force | Out-Null
    [IO.File]::WriteAllText($legacy,'original old plugin')
    [IO.File]::WriteAllText((Join-Path (Split-Path -Parent $legacy) 'keep.txt'),'keep old images and content')
    Install-ZhaoHuo -GamePath $existing -PackageRoot $package -Log $quiet | Out-Null
    $state = Read-State $existing
    Assert-True ($state.Environment -eq 'ExistingBepInEx6' -and @($state.OwnedFiles | Where-Object { $_.Category -eq 'Runtime' }).Count -eq 0) 'Existing be692 core is not claimed or replaced'
    Assert-True ((Get-FileHash -LiteralPath (Join-Path $existing 'doorstop_config.ini')).Hash -eq $configHash -and (Get-FileHash -LiteralPath (Join-Path $existing 'BepInEx\core\BepInEx.Core.dll')).Hash -eq $coreHash) 'Existing core and customized known configuration stay byte-identical'
    Assert-True (-not (Test-Path -LiteralPath $legacy) -and (Test-Path -LiteralPath ($legacy + '.disabled-by-zhaohuo-natural'))) 'Only old MortalBeauty DLL is reversibly disabled'
    $config = Join-Path $existing 'doorstop_config.ini'
    $configBytes = [IO.File]::ReadAllBytes($config)
    [IO.File]::WriteAllText($config,"[General]`r`nenabled=false`r`ntarget_assembly=BepInEx\core\BepInEx.Unity.Mono.Preloader.dll")
    Assert-Rejected { Install-ZhaoHuo -GamePath $existing -PackageRoot $package -CheckOnly -Log $quiet } '*Doorstop*' 'Already-installed check revalidates active configuration'
    [IO.File]::WriteAllBytes($config,$configBytes)
    $cecil = Join-Path $existing 'BepInEx\core\Mono.Cecil.dll'
    $cecilBytes = [IO.File]::ReadAllBytes($cecil)
    [IO.File]::WriteAllBytes($cecil,($cecilBytes + [byte]1))
    Assert-Rejected { Install-ZhaoHuo -GamePath $existing -PackageRoot $package -CheckOnly -Log $quiet } '*6.0.0-be.692*' 'Already-installed check rejects changed external runtime core'
    [IO.File]::WriteAllBytes($cecil,$cecilBytes)
    [IO.File]::WriteAllText((Join-Path $existing 'winhttp.dll'),'later manually replaced loader')
    Uninstall-ZhaoHuo -GamePath $existing -Log $quiet
    Assert-True ((Get-Content -LiteralPath $legacy -Raw) -eq 'original old plugin') 'Existing old plugin is restored exactly'
    Assert-True ((Get-FileHash -LiteralPath (Join-Path $existing 'winhttp.dll')).Hash -eq 'D3B62F4C9C3E2196EF82603C52D6B98C043A0D6C125C081FD33D7CA3798B41B8') 'Original existing loader is restored'
    $loaderCopies = @(Get-ChildItem -LiteralPath (Join-Path $existing 'BepInEx\ZhaoHuoNatural-install') -Recurse -File | Where-Object { $_.FullName -match 'Preserved-' -and $_.Name -eq 'winhttp.dll' })
    Assert-True ($loaderCopies.Count -eq 1 -and (Get-Content -LiteralPath $loaderCopies[0].FullName -Raw) -eq 'later manually replaced loader') 'Changed loader is preserved before restoring original'
    Assert-True ((Get-FileHash -LiteralPath $config).Hash -eq $configHash -and (Test-Path -LiteralPath (Join-Path $existing 'BepInEx\core\BepInEx.Core.dll'))) 'Uninstall retains pre-existing be692 runtime and configuration'

    $missingConfig = New-Fixture 'existing-without-config' -Existing
    Remove-Item -LiteralPath (Join-Path $missingConfig 'doorstop_config.ini')
    Install-ZhaoHuo -GamePath $missingConfig -PackageRoot $package -Log $quiet | Out-Null
    Assert-True (Test-Path -LiteralPath (Join-Path $missingConfig 'doorstop_config.ini')) 'Existing be692 with absent config gets verified default config'
    Uninstall-ZhaoHuo -GamePath $missingConfig -Log $quiet
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $missingConfig 'doorstop_config.ini'))) 'Uninstall restores previously absent config'

    $conflict = New-Fixture 'bep5'
    New-Item -ItemType Directory -Path (Join-Path $conflict 'BepInEx\core') -Force | Out-Null
    [IO.File]::WriteAllText((Join-Path $conflict 'BepInEx\core\BepInEx.dll'),'Bep5 marker')
    Assert-Rejected { Install-ZhaoHuo -GamePath $conflict -PackageRoot $package -Log $quiet } '*BepInEx 5*' 'BepInEx 5 is rejected without overwrite'
    $unknown = New-Fixture 'unknown-loader'
    [IO.File]::WriteAllText((Join-Path $unknown 'winhttp.dll'),'other graphics proxy')
    Assert-Rejected { Install-ZhaoHuo -GamePath $unknown -PackageRoot $package -Log $quiet } '*未知 winhttp.dll*' 'Unknown proxy loader is rejected'
    $custom = New-Fixture 'custom-config' -Existing
    [IO.File]::WriteAllText((Join-Path $custom 'doorstop_config.ini'),"[General]`r`nenabled=true`r`ntarget_assembly=Other\loader.dll")
    Assert-Rejected { Install-ZhaoHuo -GamePath $custom -PackageRoot $package -Log $quiet } '*现有 Doorstop 配置*' 'Unknown bootstrap target is rejected'
    $version = New-Fixture 'story-update'
    [IO.File]::WriteAllText((Join-Path $version 'Mortal_Data\Managed\Mortal.Story.dll'),'only Story changed')
    Assert-Rejected { Install-ZhaoHuo -GamePath $version -PackageRoot $package -Log $quiet } '*Mortal.Story.dll*' 'Story-only version update is rejected'
    $x86 = New-Fixture 'wrong-architecture'
    $x86Bytes = [byte[]]$pe.Clone(); $x86Bytes[0x84] = 0x4C; $x86Bytes[0x85] = 0x01
    [IO.File]::WriteAllBytes((Join-Path $x86 'Mortal.exe'),$x86Bytes)
    Assert-Rejected { Install-ZhaoHuo -GamePath $x86 -PackageRoot $package -Log $quiet } '*64 位游戏*' 'Wrong game architecture is rejected'
    $missingPicture = Join-Path $payload 'Portraits\normal.png'
    $bytes = [IO.File]::ReadAllBytes($missingPicture); Remove-Item -LiteralPath $missingPicture
    $incomplete = New-Fixture 'missing-picture'
    Assert-Rejected { Install-ZhaoHuo -GamePath $incomplete -PackageRoot $package -Log $quiet } '*47 张立绘*' 'Missing one of 47 required portraits is rejected'
    [IO.File]::WriteAllBytes($missingPicture,$bytes)
    $unknownDirectory = New-Fixture 'unrecorded-plugin'
    New-Item -ItemType Directory -Path (Join-Path $unknownDirectory 'BepInEx\plugins\ZhaoHuoNatural') -Force | Out-Null
    Assert-Rejected { Install-ZhaoHuo -GamePath $unknownDirectory -PackageRoot $package -Log $quiet } '*专用目录已存在*' 'Unrecorded existing plugin directory is not overwritten'

    $failure = New-Fixture 'rollback'
    $failureLegacy = Join-Path $failure 'BepInEx\plugins\Tianfei\MortalBeauty.dll'
    New-Item -ItemType Directory -Path (Split-Path -Parent $failureLegacy) -Force | Out-Null
    [IO.File]::WriteAllText($failureLegacy,'rollback legacy bytes')
    & $module {
        $script:OriginalCopy = ${function:Copy-ZHVerified}
        function script:Copy-ZHVerified([string]$Source,[string]$Destination,[string]$Sha256) {
            & $script:OriginalCopy $Source $Destination $Sha256
            if ($Source -like '*\Loader\winhttp.dll') { throw 'INJECTED_FAILURE_AFTER_LOADER_COPY' }
        }
    }
    try { Assert-Rejected { Install-ZhaoHuo -GamePath $failure -PackageRoot $package -Log $quiet } '*INJECTED_FAILURE*' 'Injected failure exercises automatic rollback' }
    finally { & $module { Set-Item -Path Function:script:Copy-ZHVerified -Value $script:OriginalCopy } }
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $failure 'winhttp.dll')) -and -not (Test-Path -LiteralPath (Join-Path $failure 'BepInEx\plugins\ZhaoHuoNatural')) -and -not (Test-Path -LiteralPath (Join-Path $failure 'BepInEx\ZhaoHuoNatural-install\ActiveManifest.json'))) 'Rollback removes partially installed files and retires active state'
    Assert-True ((Get-Content -LiteralPath $failureLegacy -Raw) -eq 'rollback legacy bytes') 'Rollback restores previously disabled legacy plugin'

    $tampered = New-Fixture 'tampered-record'
    Install-ZhaoHuo -GamePath $tampered -PackageRoot $package -Log $quiet | Out-Null
    $state = Read-State $tampered
    $state.OwnedFiles[0].RelativePath = '..\outside.txt'
    Write-State $tampered $state
    Assert-Rejected { Uninstall-ZhaoHuo -GamePath $tampered -Log $quiet } '*不属于本包*' 'Manifest path traversal is rejected before deletion'
    Assert-True (Test-Path -LiteralPath (Join-Path $tampered 'winhttp.dll')) 'Rejected tampered manifest leaves installed files intact'

    $schema2 = New-Fixture 'schema2' -Existing
    $legacy2 = Join-Path $schema2 'BepInEx\plugins\Tianfei\MortalBeauty.dll'
    New-Item -ItemType Directory -Path (Split-Path -Parent $legacy2) -Force | Out-Null
    [IO.File]::WriteAllText($legacy2,'schema2 old plugin')
    Install-ZhaoHuo -GamePath $schema2 -PackageRoot $package -Log $quiet | Out-Null
    $state3 = Read-State $schema2
    $backup2 = Join-Path (Join-Path $schema2 'BepInEx\ZhaoHuoNatural-install') $state3.BackupRelativePath
    Copy-Item -LiteralPath (Join-Path $backup2 'Original\winhttp.dll') -Destination (Join-Path $backup2 'winhttp.dll')
    $oldFiles = @($state3.OwnedFiles | Where-Object { $_.Category -eq 'Plugin' } | ForEach-Object { [pscustomobject]@{ RelativePath = $_.RelativePath.Substring('BepInEx\plugins\ZhaoHuoNatural\'.Length); Sha256 = $_.InstalledSha256; Length = 0 } })
    $old = [pscustomobject]@{ SchemaVersion=2; PackageId='ZhaoHuoNatural'; InstallationId=$state3.InstallationId; Status='installed'; GamePath=$schema2; BackupRelativePath=$state3.BackupRelativePath; Files=$oldFiles; Legacy=$state3.Legacy; Loader=[pscustomobject]@{OriginalSha256='D3B62F4C9C3E2196EF82603C52D6B98C043A0D6C125C081FD33D7CA3798B41B8';InstalledSha256='D3B62F4C9C3E2196EF82603C52D6B98C043A0D6C125C081FD33D7CA3798B41B8'} }
    Write-State $schema2 $old
    Uninstall-ZhaoHuo -GamePath $schema2 -CheckOnly -Log $quiet
    Uninstall-ZhaoHuo -GamePath $schema2 -Log $quiet
    Assert-True ((Get-Content -LiteralPath $legacy2 -Raw) -eq 'schema2 old plugin' -and -not (Test-Path -LiteralPath (Join-Path $schema2 'BepInEx\plugins\ZhaoHuoNatural')) -and (Test-Path -LiteralPath (Join-Path $schema2 'winhttp.dll'))) 'Private schema2 record remains fully uninstallable'

    $steamA = Join-Path $work 'Steam A'
    $steamB = Join-Path $work 'Steam B'
    foreach ($steam in @($steamA,$steamB)) {
        New-Item -ItemType Directory -Path (Join-Path $steam 'steamapps\common\LegendOfMortal') -Force | Out-Null
        [IO.File]::WriteAllBytes((Join-Path $steam 'steamapps\common\LegendOfMortal\Mortal.exe'),$pe)
        [IO.File]::WriteAllText((Join-Path $steam 'steamapps\appmanifest_1859910.acf'),'"AppState" { "installdir" "LegendOfMortal" }')
    }
    [IO.File]::WriteAllText((Join-Path $steamA 'steamapps\libraryfolders.vdf'),('"libraryfolders" { "1" { "path" "' + $steamB.Replace('\','\\') + '" } }'))
    $discovered = @(Get-ZhaoHuoSteamCandidates -SteamRoots @($steamA))
    Assert-True ($discovered.Count -eq 2 -and $discovered -contains (Join-Path $steamB 'steamapps\common\LegendOfMortal')) 'Steam library discovery handles multiple libraries and spaces'

    $summary = [ordered]@{ status='passed'; powershell=$PSVersionTable.PSVersion.ToString(); assertionCount=$script:Assertions.Count; durationSeconds=[Math]::Round(([DateTime]::UtcNow-$start).TotalSeconds,2); scope='Self-contained synthetic game fixtures, official bundled runtime, no real game installation or execution'; checks=@($script:Assertions) }
    [IO.File]::WriteAllText((Join-Path $PSScriptRoot 'results-summary.json'),($summary | ConvertTo-Json -Depth 6),(New-Object Text.UTF8Encoding($false)))
    Write-Host "ALL $($script:Assertions.Count) ASSERTIONS PASSED. No real game files were modified."
} catch {
    $summary = [ordered]@{ status='failed'; powershell=$PSVersionTable.PSVersion.ToString(); passedBeforeFailure=$script:Assertions.Count; error=$_.Exception.Message }
    [IO.File]::WriteAllText((Join-Path $PSScriptRoot 'results-summary.json'),($summary | ConvertTo-Json -Depth 4),(New-Object Text.UTF8Encoding($false)))
    throw
}
