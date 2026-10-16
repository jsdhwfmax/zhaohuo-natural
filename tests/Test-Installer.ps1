#requires -Version 5.1
[CmdletBinding()]
param([string]$OutputPath)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
$repo = Split-Path -Parent $PSScriptRoot
if(-not $OutputPath){$OutputPath=Join-Path $PSScriptRoot 'results-summary.json'}
[IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($OutputPath)))|Out-Null
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
    $game = Join-Path (Join-Path $work (('game-{0:D2}-' -f $script:Counter) + $Name)) 'steamapps\common\LegendOfMortal'
    New-Item -ItemType Directory -Path (Join-Path $game 'Mortal_Data\Managed') -Force | Out-Null
    [IO.File]::WriteAllText((Join-Path ([IO.Directory]::GetParent($game).Parent.FullName) 'appmanifest_1859910.acf'),'"AppState" { "buildid" "90000001" }')
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
    $firstHashes = [ordered]@{}
    foreach ($name in $script:FixtureGameHashes.Keys) { $firstHashes[$name] = $script:FixtureGameHashes[$name] }
    $updated = New-Fixture 'updated-build'
    foreach ($name in @('Mortal.Core.dll','Mortal.Story.dll')) {
        [IO.File]::WriteAllText((Join-Path $updated ('Mortal_Data\Managed\' + $name)), ('fixture-second-build:' + $name))
    }
    [IO.File]::WriteAllText((Join-Path ([IO.Directory]::GetParent($updated).Parent.FullName) 'appmanifest_1859910.acf'),'"AppState" { "buildid" "90000002" }')
    $secondHashes = [ordered]@{}
    foreach ($name in $firstHashes.Keys) { $secondHashes[$name] = (Get-FileHash -LiteralPath (Join-Path $updated ('Mortal_Data\Managed\' + $name))).Hash }
    & $module {
        param($First,$Second)
        $script:SupportedGameBuilds = @(
            [pscustomobject]@{ BuildId = '90000001'; Hashes = $First },
            [pscustomobject]@{ BuildId = '90000002'; Hashes = $Second }
        )
    } $firstHashes $secondHashes
    # This suite verifies installer integration and fail-closed behavior. The
    # real read-only metadata probe has a separate fixture suite; dummy game
    # files here cannot be used as evidence of actual runtime compatibility.
    & $module {
        $script:ProbeFixtureMode = 'Reject'
        $script:ProbeCallCount = 0
        function script:Invoke-ZHCompatibilityProbe([string]$GamePath,[string]$PackageRoot) {
            $script:ProbeCallCount++
            if ($script:ProbeFixtureMode -eq 'Throw') { throw 'fixture probe read failure' }
            $fingerprints = [ordered]@{}
            foreach ($name in $script:GameAssemblyNames) { $fingerprints[$name] = Get-ZHHash (Get-ZHChild $GamePath ('Mortal_Data\Managed\' + $name)) }
            if ($script:ProbeFixtureMode -eq 'WrongFingerprint') { $fingerprints['Mortal.Core.dll'] = '0' * 64 }
            if ($script:ProbeFixtureMode -eq 'ChangedSteamManifest') {
                [IO.File]::WriteAllText((Join-Path ([IO.Directory]::GetParent($GamePath).Parent.FullName) 'appmanifest_1859910.acf'),'"AppState" { "buildid" "88888888" }')
            }
            $accepted = $script:ProbeFixtureMode -ne 'Reject'
            if ($script:ProbeFixtureMode -eq 'Malformed') { $accepted = 'true' }
            $checks = @([pscustomobject]@{ Name = 'FixtureContract'; Passed = $true })
            if ($script:ProbeFixtureMode -eq 'FailedCheck') { $checks[0].Passed = $false }
            if ($script:ProbeFixtureMode -eq 'MissingEvidence') { $checks = @() }
            [pscustomobject]@{
                Compatible = $accepted; Method = 'OfflineCompatibilityProbe'; BaselineBuildIds = @('90000001')
                Reasons = @('fixture critical interface changed'); Checks = $checks
                FingerprintSet = $fingerprints
            }
        }
    }
    $checkFirst = Install-ZhaoHuo -GamePath $clean -PackageRoot $package -CheckOnly -Log $quiet
    Assert-True ($checkFirst.Validation.MatchedBuildId -eq '90000001') 'First verified four-assembly group remains supported'
    Assert-True ($checkFirst.Validation.CompatibilityMode -eq 'VerifiedFingerprint' -and (& $module { $script:ProbeCallCount }) -eq 0) 'Known fingerprint group uses the verified fast path without calling the probe'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $clean 'BepInEx'))) 'Clean CheckOnly creates no game files'
    $checkSecond = Install-ZhaoHuo -GamePath $updated -PackageRoot $package -CheckOnly -Log $quiet
    Assert-True ($checkSecond.Validation.MatchedBuildId -eq '90000002' -and -not (Test-Path -LiteralPath (Join-Path $updated 'BepInEx'))) 'Second complete group passes CheckOnly without changing game files'
    Install-ZhaoHuo -GamePath $clean -PackageRoot $package -Log $quiet | Out-Null
    $state = Read-State $clean
    Assert-True ($state.SchemaVersion -eq 3 -and $state.Environment -eq 'CleanGame' -and @($state.OwnedFiles).Count -eq 66) 'Clean install records all 66 owned files in schema 3'
    Assert-True (@($state.GameAssemblySha256.PSObject.Properties).Count -eq 4) 'Manifest records all four game hashes'
    Assert-True ($state.MatchedBuildId -eq '90000001') 'Manifest records the complete fingerprint group that matched'
    Assert-True ((Get-FileHash -LiteralPath (Join-Path $clean 'winhttp.dll')).Hash -eq 'D3B62F4C9C3E2196EF82603C52D6B98C043A0D6C125C081FD33D7CA3798B41B8') 'Clean install uses verified official x64 loader'
    $manifestPath = Join-Path $clean 'BepInEx\ZhaoHuoNatural-install\ActiveManifest.json'
    $before = (Get-FileHash -LiteralPath $manifestPath).Hash
    Install-ZhaoHuo -GamePath $clean -PackageRoot $package -Log $quiet | Out-Null
    Assert-True ((Get-FileHash -LiteralPath $manifestPath).Hash -eq $before) 'Repeated identical install is a no-op'
    # Recreate the v1.0.0 schema3 shape, which predates MatchedBuildId. Updating
    # the game must not force an uninstall when the portrait payload is unchanged.
    $state.PSObject.Properties.Remove('MatchedBuildId')
    $state.PSObject.Properties.Remove('AdoptedUntrackedPayload')
    $state.PSObject.Properties.Remove('CompatibilityMode')
    $state.PSObject.Properties.Remove('DetectedBuild')
    $state.PSObject.Properties.Remove('CompatibilityEvidence')
    Write-State $clean $state
    $beforeUpdate = (Get-FileHash -LiteralPath $manifestPath).Hash
    foreach ($name in @('Mortal.Core.dll','Mortal.Story.dll')) {
        Copy-Item -LiteralPath (Join-Path $updated ('Mortal_Data\Managed\' + $name)) -Destination (Join-Path $clean ('Mortal_Data\Managed\' + $name))
    }
    [IO.File]::WriteAllText((Join-Path ([IO.Directory]::GetParent($clean).Parent.FullName) 'appmanifest_1859910.acf'),'"AppState" { "buildid" "90000002" }')
    $upgrade = Install-ZhaoHuo -GamePath $clean -PackageRoot $package -Log $quiet
    Assert-True ($upgrade.AlreadyInstalled -and $upgrade.Validation.MatchedBuildId -eq '90000002' -and (Get-FileHash -LiteralPath $manifestPath).Hash -eq $beforeUpdate) 'Existing v1.0.0 schema3 installation accepts a verified game update without uninstall or overwrite'
    $storyPath = Join-Path $clean 'Mortal_Data\Managed\Mortal.Story.dll'
    [IO.File]::WriteAllText($storyPath,'fixture-game-assembly:Mortal.Story.dll')
    Assert-Rejected { Install-ZhaoHuo -GamePath $clean -PackageRoot $package -Log $quiet } '*游戏版本不受支持*' 'Known Core and Story hashes from different builds are rejected as a mixed group'
    Assert-True ((Get-FileHash -LiteralPath $manifestPath).Hash -eq $beforeUpdate) 'Rejected mixed group leaves the previous installation record unchanged'
    Copy-Item -LiteralPath (Join-Path $updated 'Mortal_Data\Managed\Mortal.Story.dll') -Destination $storyPath
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
    $diagnostic = $null
    try { Install-ZhaoHuo -GamePath $version -PackageRoot $package -CheckOnly -Log $quiet | Out-Null } catch { $diagnostic = $_.Exception.Message }
    $allHashesIncluded = $true
    foreach ($name in $firstHashes.Keys) {
        $actualHash = (Get-FileHash -LiteralPath (Join-Path $version ('Mortal_Data\Managed\' + $name))).Hash
        if (-not $diagnostic.Contains($name + ' SHA-256: ' + $actualHash)) { $allHashesIncluded = $false }
    }
    Assert-True ($allHashesIncluded -and $diagnostic.Contains('90000001') -and $diagnostic.Contains('90000002') -and $diagnostic.Contains('/releases')) 'Unsupported-version feedback contains every actual hash, supported groups and update link'
    $metadata = New-Fixture 'metadata'
    $acfPath = Join-Path ([IO.Directory]::GetParent($metadata).Parent.FullName) 'appmanifest_1859910.acf'
    [IO.File]::WriteAllText($acfPath,'"AppState" { "buildid" "99999999" }')
    $callsBeforeMetadata = & $module { $script:ProbeCallCount }
    Assert-Rejected { Install-ZhaoHuo -GamePath $metadata -PackageRoot $package -CheckOnly -Log $quiet } '*fixture critical interface changed*' 'A new build with unchanged four DLLs is rejected when the resource or interface probe fails'
    Assert-True ((& $module { $script:ProbeCallCount }) -gt $callsBeforeMetadata) 'A new Steam build never skips the probe merely because four DLL hashes are known'
    & $module { $script:ProbeFixtureMode = 'Pass' }
    $metadataPlan = Install-ZhaoHuo -GamePath $metadata -PackageRoot $package -CheckOnly -Log $quiet
    Assert-True ($metadataPlan.Validation.BuildId -eq '99999999' -and $null -eq $metadataPlan.Validation.MatchedBuildId -and $metadataPlan.Validation.CompatibilityMode -eq 'OfflineCompatibilityProbe') 'New Steam metadata can be accepted by the probe without claiming a known build match'
    Remove-Item -LiteralPath $acfPath
    $noMetadataPlan = Install-ZhaoHuo -GamePath $metadata -PackageRoot $package -CheckOnly -Log $quiet
    Assert-True ($null -eq $noMetadataPlan.Validation.DetectedBuild -and $noMetadataPlan.Validation.CompatibilityMode -eq 'OfflineCompatibilityProbe') 'Missing Steam metadata requires the offline probe even with known DLL fingerprints'
    & $module { $script:ProbeFixtureMode = 'Reject' }
    [IO.File]::WriteAllText($acfPath,'"AppState" { "buildid" "25953419" }')
    [IO.File]::WriteAllText((Join-Path $metadata 'Mortal_Data\Managed\Mortal.Core.dll'),'unknown future core')
    Assert-Rejected { Install-ZhaoHuo -GamePath $metadata -PackageRoot $package -CheckOnly -Log $quiet } '*游戏版本不受支持*' 'A familiar Steam build label cannot bypass unknown assembly fingerprints'

    $automatic = New-Fixture 'auto-update'
    [IO.File]::WriteAllText((Join-Path $automatic 'Mortal_Data\Managed\Mortal.Core.dll'),'future non-portrait update fixture')
    $automaticAcf = Join-Path ([IO.Directory]::GetParent($automatic).Parent.FullName) 'appmanifest_1859910.acf'
    [IO.File]::WriteAllText($automaticAcf,'"AppState" { "buildid" "99999999" }')
    & $module { $script:ProbeFixtureMode = 'Pass' }
    $automaticPlan = Install-ZhaoHuo -GamePath $automatic -PackageRoot $package -CheckOnly -Log $quiet
    Assert-True ($automaticPlan.Validation.CompatibilityMode -eq 'OfflineCompatibilityProbe' -and $null -eq $automaticPlan.Validation.MatchedBuildId -and $automaticPlan.Validation.DetectedBuild -eq '99999999') 'Unknown compatible update uses probe mode and never claims a verified build match'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $automatic 'BepInEx'))) 'Automatic compatibility CheckOnly leaves the game directory unchanged'
    Install-ZhaoHuo -GamePath $automatic -PackageRoot $package -Log $quiet | Out-Null
    $automaticState = Read-State $automatic
    Assert-True ($automaticState.CompatibilityMode -eq 'OfflineCompatibilityProbe' -and $automaticState.DetectedBuild -eq '99999999' -and $null -eq $automaticState.MatchedBuildId -and @($automaticState.CompatibilityEvidence.Checks).Count -eq 1) 'Automatic installation records detected build and offline compatibility evidence'
    foreach ($property in @('CompatibilityMode','DetectedBuild','CompatibilityEvidence','MatchedBuildId')) { $automaticState.PSObject.Properties.Remove($property) }
    Write-State $automatic $automaticState
    $automaticManifest = Join-Path $automatic 'BepInEx\ZhaoHuoNatural-install\ActiveManifest.json'
    $automaticBefore = (Get-FileHash -LiteralPath $automaticManifest).Hash
    $automaticRepeat = Install-ZhaoHuo -GamePath $automatic -PackageRoot $package -Log $quiet
    Assert-True ($automaticRepeat.AlreadyInstalled -and $automaticRepeat.Validation.CompatibilityMode -eq 'OfflineCompatibilityProbe' -and (Get-FileHash -LiteralPath $automaticManifest).Hash -eq $automaticBefore) 'Older schema3 records work with automatic compatibility without rewriting installation history'
    & $module { $script:ProbeFixtureMode = 'Reject' }
    Assert-Rejected { Install-ZhaoHuo -GamePath $automatic -PackageRoot $package -CheckOnly -Log $quiet } '*fixture critical interface changed*' 'A critical interface rejection blocks an already installed unknown update'
    Assert-True ((Get-FileHash -LiteralPath $automaticManifest).Hash -eq $automaticBefore) 'Failed automatic revalidation preserves the existing install record'
    Uninstall-ZhaoHuo -GamePath $automatic -Log $quiet
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $automatic 'winhttp.dll'))) 'An automatically accepted update remains uninstallable after compatibility changes'
    foreach ($probeFailure in @('Throw','WrongFingerprint','Malformed','FailedCheck','MissingEvidence')) {
        & $module { param($Mode) $script:ProbeFixtureMode = $Mode } $probeFailure
        Assert-Rejected { Install-ZhaoHuo -GamePath $automatic -PackageRoot $package -CheckOnly -Log $quiet } '*游戏版本不受支持*' ('Probe failure is rejected safely: ' + $probeFailure)
    }
    & $module { $script:ProbeFixtureMode = 'ChangedSteamManifest' }
    Assert-Rejected { Install-ZhaoHuo -GamePath $automatic -PackageRoot $package -CheckOnly -Log $quiet } '*Steam 安装清单发生变化*' 'Changing Steam metadata during a probe rejects the result before installation'
    Remove-Item -LiteralPath $automaticAcf
    Assert-Rejected { Install-ZhaoHuo -GamePath $automatic -PackageRoot $package -CheckOnly -Log $quiet } '*Steam 安装清单发生变化*' 'A Steam manifest appearing during a probe also invalidates its result'
    & $module { $script:ProbeFixtureMode = 'Pass' }
    [IO.File]::WriteAllText((Join-Path $automatic 'winhttp.dll'),'unknown graphics proxy')
    Assert-Rejected { Install-ZhaoHuo -GamePath $automatic -PackageRoot $package -CheckOnly -Log $quiet } '*未知 winhttp.dll*' 'A successful offline probe does not bypass loader protection'
    & $module { $script:ProbeFixtureMode = 'Reject' }
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

    $insideGame = New-Fixture 'package-inside-game'
    Assert-Rejected { Install-ZhaoHuo -GamePath $insideGame -PackageRoot $insideGame -Log $quiet } '*重新完整解压到游戏目录之外*' 'Running the extracted package from the game root gives a recovery instruction'
    $adopt = New-Fixture 'exact-untracked-copy'
    [IO.File]::WriteAllText((Join-Path $adopt 'Mortal_Data\Managed\Mortal.Core.dll'),'future non-portrait update fixture')
    & $module { $script:ProbeFixtureMode = 'Pass' }
    $adoptPlugin = Join-Path $adopt 'BepInEx\plugins\ZhaoHuoNatural'
    New-Item -ItemType Directory -Path (Split-Path -Parent $adoptPlugin) -Force | Out-Null
    Copy-Item -LiteralPath $payload -Destination $adoptPlugin -Recurse
    $otherMod = Join-Path $adopt 'BepInEx\plugins\OtherManualMod.dll'
    [IO.File]::WriteAllText($otherMod,'unrelated manual mod')
    $adoptCheck = Install-ZhaoHuo -GamePath $adopt -PackageRoot $package -CheckOnly -Log $quiet
    Assert-True ($adoptCheck.AdoptedUntrackedPayload -and $adoptCheck.Validation.CompatibilityMode -eq 'OfflineCompatibilityProbe' -and -not (Test-Path -LiteralPath (Join-Path $adopt 'BepInEx\ZhaoHuoNatural-install'))) 'Exact untracked payload recovery still works after automatic compatibility checking'
    Install-ZhaoHuo -GamePath $adopt -PackageRoot $package -Log $quiet | Out-Null
    $adoptState = Read-State $adopt
    $adoptRecords = @($adoptState.OwnedFiles | Where-Object { $_.Category -eq 'Plugin' })
    $adoptBackupRoot = Join-Path (Join-Path $adopt 'BepInEx\ZhaoHuoNatural-install') $adoptState.BackupRelativePath
    $allAdoptBackups = $true
    foreach ($record in $adoptRecords) {
        if (-not $record.WasPresent -or (Get-FileHash -LiteralPath (Join-Path $adoptBackupRoot $record.BackupRelativePath)).Hash -ne $record.OriginalSha256) { $allAdoptBackups = $false }
    }
    Assert-True ($adoptState.AdoptedUntrackedPayload -and $adoptRecords.Count -eq 50 -and $allAdoptBackups) 'Adopting an exact untracked payload backs up all 50 pre-existing files'
    Uninstall-ZhaoHuo -GamePath $adopt -Log $quiet
    $restoredAdoptFiles = @(Get-ChildItem -LiteralPath $adoptPlugin -File -Recurse)
    Assert-True ($restoredAdoptFiles.Count -eq 50 -and (Get-Content -LiteralPath $otherMod -Raw) -eq 'unrelated manual mod' -and -not (Test-Path -LiteralPath (Join-Path $adopt 'winhttp.dll'))) 'Adopted payload uninstall restores pre-existing files and leaves other mods intact'
    $unknownAdoptFile = Join-Path $adoptPlugin 'user-extra.txt'
    [IO.File]::WriteAllText($unknownAdoptFile,'keep this unknown file')
    Assert-Rejected { Install-ZhaoHuo -GamePath $adopt -PackageRoot $package -Log $quiet } '*文件与本发布包不完全一致*' 'An extra file prevents adoption of an untracked portrait directory'
    Assert-True ((Get-Content -LiteralPath $unknownAdoptFile -Raw) -eq 'keep this unknown file') 'Rejected adoption preserves unknown user files'
    Remove-Item -LiteralPath $unknownAdoptFile
    $adoptNormal = Join-Path $adoptPlugin 'Portraits\normal.png'
    [IO.File]::WriteAllText($adoptNormal,'modified existing portrait')
    Assert-Rejected { Install-ZhaoHuo -GamePath $adopt -PackageRoot $package -Log $quiet } '*文件与本发布包不完全一致*' 'A modified portrait prevents adoption even when names match'
    Assert-True ((Get-Content -LiteralPath $adoptNormal -Raw) -eq 'modified existing portrait') 'Rejected adoption preserves modified portrait bytes'
    Remove-Item -LiteralPath $adoptNormal
    Assert-Rejected { Install-ZhaoHuo -GamePath $adopt -PackageRoot $package -Log $quiet } '*文件与本发布包不完全一致*' 'A missing portrait prevents adopting an incomplete extracted copy'
    & $module { $script:ProbeFixtureMode = 'Reject' }

    $failure = New-Fixture 'rollback'
    $failureLegacy = Join-Path $failure 'BepInEx\plugins\Tianfei\MortalBeauty.dll'
    New-Item -ItemType Directory -Path (Split-Path -Parent $failureLegacy) -Force | Out-Null
    [IO.File]::WriteAllText($failureLegacy,'rollback legacy bytes')
    $adoptFailure = New-Fixture 'adoption-rollback'
    $adoptFailurePlugin = Join-Path $adoptFailure 'BepInEx\plugins\ZhaoHuoNatural'
    New-Item -ItemType Directory -Path (Split-Path -Parent $adoptFailurePlugin) -Force | Out-Null
    Copy-Item -LiteralPath $payload -Destination $adoptFailurePlugin -Recurse
    & $module {
        $script:OriginalCopy = ${function:Copy-ZHVerified}
        function script:Copy-ZHVerified([string]$Source,[string]$Destination,[string]$Sha256) {
            & $script:OriginalCopy $Source $Destination $Sha256
            if ($Source -like '*\Loader\winhttp.dll') { throw 'INJECTED_FAILURE_AFTER_LOADER_COPY' }
        }
    }
    try {
        Assert-Rejected { Install-ZhaoHuo -GamePath $failure -PackageRoot $package -Log $quiet } '*INJECTED_FAILURE*' 'Injected failure exercises automatic rollback'
        Assert-Rejected { Install-ZhaoHuo -GamePath $adoptFailure -PackageRoot $package -Log $quiet } '*INJECTED_FAILURE*' 'Injected failure also exercises rollback after untracked payload adoption'
    }
    finally { & $module { Set-Item -Path Function:script:Copy-ZHVerified -Value $script:OriginalCopy } }
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $failure 'winhttp.dll')) -and -not (Test-Path -LiteralPath (Join-Path $failure 'BepInEx\plugins\ZhaoHuoNatural')) -and -not (Test-Path -LiteralPath (Join-Path $failure 'BepInEx\ZhaoHuoNatural-install\ActiveManifest.json'))) 'Rollback removes partially installed files and retires active state'
    Assert-True ((Get-Content -LiteralPath $failureLegacy -Raw) -eq 'rollback legacy bytes') 'Rollback restores previously disabled legacy plugin'
    $adoptRollbackRestored = $true
    foreach ($file in @(Get-ChildItem -LiteralPath $payload -Recurse -File)) {
        $relative = $file.FullName.Substring($payload.Length + 1)
        $restored = Join-Path $adoptFailurePlugin $relative
        if (-not (Test-Path -LiteralPath $restored -PathType Leaf) -or (Get-FileHash -LiteralPath $restored).Hash -ne (Get-FileHash -LiteralPath $file.FullName).Hash) { $adoptRollbackRestored = $false }
    }
    Assert-True ($adoptRollbackRestored -and -not (Test-Path -LiteralPath (Join-Path $adoptFailure 'winhttp.dll')) -and -not (Test-Path -LiteralPath (Join-Path $adoptFailure 'BepInEx\ZhaoHuoNatural-install\ActiveManifest.json'))) 'Failed adoption restores every original portrait and removes its partial installation state'

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

    $summary = [ordered]@{ status='passed'; powershell=$PSVersionTable.PSVersion.ToString(); assertionCount=$script:Assertions.Count; durationSeconds=[Math]::Round(([DateTime]::UtcNow-$start).TotalSeconds,2); scope='Installer integration with synthetic game fixtures, official bundled runtime and stubbed offline-probe results; metadata probe tested separately; no real game installation or execution'; checks=@($script:Assertions) }
    [IO.File]::WriteAllText($OutputPath,($summary | ConvertTo-Json -Depth 6),(New-Object Text.UTF8Encoding($false)))
    Write-Host "ALL $($script:Assertions.Count) ASSERTIONS PASSED. No real game files were modified."
} catch {
    $summary = [ordered]@{ status='failed'; powershell=$PSVersionTable.PSVersion.ToString(); passedBeforeFailure=$script:Assertions.Count; error=$_.Exception.Message }
    [IO.File]::WriteAllText($OutputPath,($summary | ConvertTo-Json -Depth 4),(New-Object Text.UTF8Encoding($false)))
    throw
}
