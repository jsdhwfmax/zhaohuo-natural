#requires -Version 5.1
[CmdletBinding()]
param([string]$OutputPath)
$ErrorActionPreference='Stop';Set-StrictMode -Version 2.0
$repo=Split-Path -Parent $PSScriptRoot
function Test-CodeHash([string]$Path){$text=[IO.File]::ReadAllText($Path).TrimStart([char]0xFEFF).Replace("`r`n","`n").Replace("`r","`n");$sha=[Security.Cryptography.SHA256]::Create();try{([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($text)))).Replace('-','')}finally{$sha.Dispose()}}
$codeHashes=[ordered]@{}
foreach($file in @('installer/ZhaoHuoInstaller.psm1','installer/AppearanceManager.ps1','installer/VariantSupport.ps1','installer/CharacterCatalog.ps1','installer/CharacterState.ps1','installer/CharacterManager.ps1','installer/CharacterTransactions.ps1','Install.ps1','VariantCatalog.json','tests/Test-CharacterManager.ps1')){$codeHashes[$file]=Test-CodeHash (Join-Path $repo $file)}
$module=Import-Module (Join-Path $repo 'installer\ZhaoHuoInstaller.psm1') -Force -PassThru
$prod=Get-PortraitCharacters -PackageRoot $repo
$work=Join-Path $PSScriptRoot ('.work\characters-'+[Guid]::NewGuid().ToString('N'))
$package=Join-Path $work 'Fixture package';$plugin='BepInEx\plugins\ZhaoHuoNatural'
$quiet={param($Message,$Level)};$checks=New-Object 'System.Collections.Generic.List[string]';$start=[DateTime]::UtcNow
function Write-Text([string]$Path,[string]$Text){New-Item -ItemType Directory -Path (Split-Path -Parent $Path) -Force|Out-Null;[IO.File]::WriteAllText($Path,$Text,(New-Object Text.UTF8Encoding($false)))}
function Save-Json([string]$Path,[object]$Value){Write-Text $Path ($Value|ConvertTo-Json -Depth 20)}
function Hash([string]$Path){(Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash}
function Assert([bool]$Condition,[string]$Name){if(-not $Condition){throw ('FAIL: '+$Name)};$checks.Add($Name);Write-Host ('PASS: '+$Name)}
function Reject([scriptblock]$Operation,[string]$Pattern,[string]$Name){$failed=$false;try{& $Operation|Out-Null}catch{if($_.Exception.Message-notlike $Pattern){throw};$failed=$true};Assert $failed $Name}
function State([string]$Game){Get-Content -LiteralPath (Join-Path $Game 'BepInEx\ZhaoHuoNatural-install\ActiveManifest.json') -Raw -Encoding UTF8|ConvertFrom-Json}
function StatePath([string]$Game){Join-Path $Game 'BepInEx\ZhaoHuoNatural-install\ActiveManifest.json'}
function Snapshot([string]$Root){$map=@{};if(Test-Path -LiteralPath $Root){foreach($f in @(Get-ChildItem -LiteralPath $Root -Recurse -File)){$map[$f.FullName.Substring($Root.Length+1)]=Hash $f.FullName}};return $map}
function Same([hashtable]$Before,[hashtable]$After){if($Before.Count-ne $After.Count){return $false};foreach($k in $Before.Keys){if($Before[$k]-ne $After[$k]){return $false}};return $true}
function Apply([string]$Game,[string]$Character,[string]$Variant){Set-PortraitAppearance -GamePath $Game -PackageRoot $package -CharacterId $Character -VariantId $Variant -Log $quiet}
function Check([string]$Game,[string]$Character,[string]$Variant){Set-PortraitAppearance -GamePath $Game -PackageRoot $package -CharacterId $Character -VariantId $Variant -CheckOnly -Log $quiet}
$pe=New-Object byte[] 256;$pe[0]=0x4D;$pe[1]=0x5A;$pe[0x3C]=0x80;$pe[0x80]=0x50;$pe[0x81]=0x45;$pe[0x84]=0x64;$pe[0x85]=0x86
function New-Game([string]$Name,[switch]$Existing){
    $game=Join-Path $work ($Name+'\steamapps\common\LegendOfMortal')
    New-Item -ItemType Directory -Path (Join-Path $game 'Mortal_Data\Managed') -Force|Out-Null
    [IO.File]::WriteAllBytes((Join-Path $game 'Mortal.exe'),$pe);[IO.File]::WriteAllBytes((Join-Path $game 'UnityPlayer.dll'),$pe)
    Write-Text (Join-Path ([IO.Directory]::GetParent($game).Parent.FullName) 'appmanifest_1859910.acf') '"AppState" { "buildid" "90000001" }'
    $hashes=[ordered]@{}
    foreach($name in @('Assembly-CSharp.dll','Mortal.Core.dll','Mortal.Story.dll','Fungus.dll')){$file=Join-Path $game ('Mortal_Data\Managed\'+$name);Write-Text $file ('INERT TEST ASSEMBLY '+$name);$hashes[$name]=Hash $file}
    & $module {param($Hashes) $script:SupportedGameBuilds=@([pscustomobject]@{BuildId='90000001';Hashes=$Hashes})} $hashes
    if($Existing){
        $deps=Get-Content -LiteralPath (Join-Path $package 'Dependencies\BepInEx\runtime-manifest.json') -Raw|ConvertFrom-Json
        foreach($d in $deps.Files){$dest=Join-Path $game $d.RelativePath;New-Item -ItemType Directory -Path (Split-Path -Parent $dest) -Force|Out-Null;Copy-Item -LiteralPath (Join-Path $package ('Dependencies\BepInEx\files\'+$d.RelativePath)) -Destination $dest}
        Copy-Item -LiteralPath (Join-Path $package 'Loader\winhttp.dll') -Destination (Join-Path $game 'winhttp.dll')
    }
    return $game
}
function Legacy-Package([string]$Variant){
    $legacy=Join-Path $work ('Legacy '+$Variant+'-'+[Guid]::NewGuid().ToString('N').Substring(0,8))
    New-Item -ItemType Directory -Path $legacy -Force|Out-Null
    Copy-Item -LiteralPath (Join-Path $package 'Dependencies') -Destination $legacy -Recurse
    Copy-Item -LiteralPath (Join-Path $package 'Loader') -Destination $legacy -Recurse
    $v=@($catalog.Characters[0].Variants|Where-Object Id -eq $Variant)[0]
    $target=Join-Path $legacy $plugin;New-Item -ItemType Directory -Path $target -Force|Out-Null
    Copy-Item -LiteralPath (Join-Path $package $v.SourcePath) -Destination (Join-Path $target 'Portraits') -Recurse
    foreach($name in @('ZhaoHuoNatural.dll','portrait-map.txt','portrait-layout.tsv')){Write-Text (Join-Path $target $name) ('OLD INERT SHARED '+$name)}
    $files=@(Get-ChildItem -LiteralPath $target -Recurse -File|ForEach-Object{[pscustomobject]@{RelativePath=($plugin+'\'+$_.FullName.Substring($target.Length+1));Sha256=(Hash $_.FullName)}})
    $fp=& $module {param($Files) Get-ZHPayloadFingerprint $Files} $files
    & $module {param($Id,$Fingerprint) $script:KnownVariantFingerprints[$Id]=$Fingerprint} $Variant $fp
    Save-Json (Join-Path $legacy 'Variant.json') ([ordered]@{SchemaVersion=1;Id=$Variant;DisplayName=('Fixture '+$Variant);PayloadReady=$true;PayloadFingerprint=$fp;SwitchFrom=@()})
    return $legacy
}
function Inject-Failure([string]$Game,[string]$Match,[switch]$Interrupt){
    & $module {
        param($Root,$Match,$Interrupt)
        $script:SavedCopy=${function:Copy-ZHVerified};$script:SavedRestore=${function:Restore-ZHCharacterTransaction};$script:SavedSave=${function:Save-ZHJson}
        $script:FailRoot=$Root;$script:FailMatch=$Match;$script:FailFired=$false
        function script:Copy-ZHVerified([string]$Source,[string]$Destination,[string]$Sha256){
            if(-not $script:FailFired -and $Destination.StartsWith($script:FailRoot+'\',[StringComparison]::OrdinalIgnoreCase)-and-not $Destination.StartsWith($script:FailRoot+'\BepInEx\ZhaoHuoNatural-install\',[StringComparison]::OrdinalIgnoreCase)-and $Destination-like $script:FailMatch){$script:FailFired=$true;throw 'INJECTED_CHARACTER_WRITE_FAILURE'}
            & $script:SavedCopy $Source $Destination $Sha256
        }
        function script:Save-ZHJson([object]$Value,[string]$Path){
            if(-not $script:FailFired-and $script:FailMatch-eq '@commit'-and $Path-eq ($script:FailRoot+'\BepInEx\ZhaoHuoNatural-install\ActiveManifest.json')-and $Value.Status-eq 'installed'){$script:FailFired=$true;throw 'INJECTED_CHARACTER_WRITE_FAILURE'}
            & $script:SavedSave $Value $Path
        }
        if($Interrupt){function script:Restore-ZHCharacterTransaction([object]$Paths,[switch]$CheckOnly,[scriptblock]$Log){throw 'SIMULATED_PROCESS_INTERRUPTION'}}
    } $Game $Match ([bool]$Interrupt)
}
function Clear-Failure {& $module {Set-Item Function:script:Copy-ZHVerified $script:SavedCopy;Set-Item Function:script:Restore-ZHCharacterTransaction $script:SavedRestore;Set-Item Function:script:Save-ZHJson $script:SavedSave}}
try{
    New-Item -ItemType Directory -Path $package -Force|Out-Null
    $cli=Join-Path $work 'CLI fixture';New-Item -ItemType Directory -Path $cli -Force|Out-Null
    Copy-Item -LiteralPath (Join-Path $repo 'Install.ps1') -Destination (Join-Path $cli 'Install.ps1')
    $stub=@'
function Get-ZhaoHuoSteamCandidates { 'fixture-discovered-game' }
function Install-ZhaoHuo {
    param([string]$GamePath,[string]$PackageRoot,[string]$CharacterId,[string]$VariantId,[switch]$CheckOnly)
    [IO.File]::WriteAllText((Join-Path $PackageRoot 'observed.json'),([ordered]@{GamePath=$GamePath;CharacterId=$CharacterId;VariantId=$VariantId;CheckOnly=[bool]$CheckOnly}|ConvertTo-Json))
}
Export-ModuleMember -Function Get-ZhaoHuoSteamCandidates,Install-ZhaoHuo
'@
    Write-Text (Join-Path $cli 'installer\ZhaoHuoInstaller.psm1') $stub
    foreach($case in @(@('player','natural'),@('tang-buyi','refined'),@('xiahou-lan','original'))){
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $cli 'Install.ps1') -CharacterId $case[0] -VariantId $case[1] -CheckOnly
        if($LASTEXITCODE-ne 0){throw 'CLI fixture process failed.'};$observed=Get-Content -LiteralPath (Join-Path $cli 'observed.json') -Raw|ConvertFrom-Json
        Assert ($observed.CharacterId-eq $case[0]-and $observed.VariantId-eq $case[1]-and $observed.CheckOnly-and $observed.GamePath-eq 'fixture-discovered-game') ('CLI forwards independent role/style and check-only: '+$case[0])
    }
    Copy-Item -LiteralPath (Join-Path $repo 'Dependencies') -Destination $package -Recurse
    Copy-Item -LiteralPath (Join-Path $repo 'Loader') -Destination $package -Recurse
    $catalog=Get-Content -LiteralPath (Join-Path $repo 'VariantCatalog.json') -Raw -Encoding UTF8|ConvertFrom-Json
    # Only isolated synthetic fixture data is made ready; production stays closed.
    foreach($character in $catalog.Characters){
        $names=@(& $module {param($Id) $script:CharacterAssets[$Id]} $character.Id)
        $layout="expression`tcanvasWidth`tcanvasHeight`tx`ty`twidth`theight`n"+(@($names|ForEach-Object{$_+"`t10`t10`t0`t0`t10`t10"})-join "`n")
        Write-Text (Join-Path $package $character.LayoutSourcePath) $layout;$character.LayoutSha256=Hash (Join-Path $package $character.LayoutSourcePath)
        foreach($v in $character.Variants){
            if($v.Kind-eq 'original'){continue}
            $fallback=@($v.OriginalFallback)
            $files=@(foreach($name in $names){if($name-in $fallback){continue};$file=Join-Path $package ($v.SourcePath+'/'+$name+'.png');Write-Text $file ('INERT DUMMY PNG FOR TRANSACTION TEST ONLY '+$character.Id+'/'+$v.Id+'/'+$name);[pscustomobject]@{Name=($name+'.png');Sha256=(Hash $file)}})
            $v.Files=$files;$v.OriginalFallback=@($fallback);$v.AssetFingerprint=& $module {param($Id,$Files) Get-ZHCharacterFingerprint $Id $Files} $character.Id $files;$v.Ready=$true
        }
    }
    foreach($shared in $catalog.SharedFiles){$path=Join-Path $package ($plugin+'\'+$shared.Name);if($shared.Name-ne 'portrait-layout.tsv'){Write-Text $path ('NEW INERT SHARED '+$shared.Name)};$shared.Sha256=Hash $path}
    & $module {param($Shared) foreach($entry in $Shared){$script:CharacterSharedHashes[$entry.Name]=$entry.Sha256}} $catalog.SharedFiles
    # A second fixture-only NPC style exercises removing previously supplied
    # assets. It is never added to the production catalog or release payload.
    $mini=$catalog.Characters[1].Variants[1]|ConvertTo-Json -Depth 10|ConvertFrom-Json
    $mini.Id='minimal';$mini.DisplayName='Fixture-only subset';$mini.SourcePath='Variants/tang-buyi/minimal/Portraits';$mini.PreviewPath=$mini.SourcePath+'/normal.png'
    Write-Text (Join-Path $package $mini.PreviewPath) 'INERT MINIMAL NPC TEST ASSET'
    $mini.Files=@([pscustomobject]@{Name='normal.png';Sha256=(Hash (Join-Path $package $mini.PreviewPath))})
    $mini.OriginalFallback=@(& $module {$script:CharacterAssets['tang-buyi']|Where-Object{$_-ne 'normal'}})
    $mini.AssetFingerprint=& $module {param($Files) Get-ZHCharacterFingerprint 'tang-buyi' $Files} $mini.Files
    $catalog.Characters[1].Variants+=@($mini)
    $catalog.PackageReady=$true;Save-Json (Join-Path $package 'VariantCatalog.json') $catalog
    $view=Get-PortraitCharacters -PackageRoot $package
    Assert ($view.Characters.Count-eq 7-and $view.Characters[0].Variants.Count-eq 7) 'Dynamic catalog exposes seven independent character groups and six player styles'
    Assert (($prod.PackageReady-and @($prod.Characters.Variants|Where-Object{-not $_.Ready}).Count-eq 0)-or(-not $prod.PackageReady-and @($prod.Characters.Variants|Where-Object Available).Count-eq 0)) 'Production catalog exposes availability only when its global readiness permits it'
    $clean=New-Game 'clean'
    $catalog.PackageReady=$false;Save-Json (Join-Path $package 'VariantCatalog.json') $catalog
    Reject {Check $clean 'player' 'natural'} '*尚未完成验证*' 'An incomplete package cannot be made installable by selecting a ready old variant'
    $catalog.PackageReady=$true;Save-Json (Join-Path $package 'VariantCatalog.json') $catalog
    $before=Snapshot $clean;$check=Check $clean 'player' 'natural'
    Assert ($check.Status-eq 'Checked'-and(Same $before (Snapshot $clean))) 'Fresh check does not change files'
    $null=Apply $clean 'player' 'original'
    Assert (-not(Test-Path -LiteralPath (StatePath $clean))) 'Fresh original option is a no-op with no loader installation'
    $null=Apply $clean 'player' 'natural';$initial=State $clean
    Assert ($initial.SchemaVersion-eq 4-and $initial.Characters[0].SelectedVariantId-eq 'natural') 'Clean installation writes schema4 and player selection'
    $playerBefore=Snapshot (Join-Path $clean ($plugin+'\Portraits'))
    $null=Apply $clean 'tang-buyi' 'refined';$s=State $clean
    Assert ((Same $playerBefore (Snapshot (Join-Path $clean ($plugin+'\Portraits'))))-and $s.Characters[1].SelectedVariantId-eq 'refined') 'Applying brother preserves every player PNG'
    Assert (-not(Test-Path -LiteralPath (Join-Path $clean ($plugin+'\Characters\tang-buyi\Portraits\hand.png')))) 'Omitted brother hand retains game fallback'
    $brother=Snapshot (Join-Path $clean ($plugin+'\Characters\tang-buyi'))
    $null=Apply $clean 'xiahou-lan' 'refined'
    Assert ((Same $brother (Snapshot (Join-Path $clean ($plugin+'\Characters\tang-buyi'))))) 'Applying Xiahou Lan preserves brother files'
    $null=Apply $clean 'player' 'black';$null=Apply $clean 'tang-buyi' 'original'
    $config=Get-Content -LiteralPath (Join-Path $clean ($plugin+'\characters.json')) -Raw|ConvertFrom-Json
    Assert ($config.Characters[0].Enabled-and-not $config.Characters[1].Enabled-and $config.Characters[2].Enabled) 'Original disables only selected character in runtime configuration'
    Assert ((Same $brother (Snapshot (Join-Path $clean ($plugin+'\Characters\tang-buyi'))))) 'Original option retains inactive owned cache'
    $null=Apply $clean 'tang-buyi' 'refined';$snapshot=Snapshot $clean;$repeat=Apply $clean 'tang-buyi' 'refined'
    Assert ($repeat.Status-eq 'NoOp'-and(Same $snapshot (Snapshot $clean))) 'Repeated selection is byte-for-byte no-op'
    $beforeSubset=Hash (StatePath $clean)
    Inject-Failure $clean '@commit'
    try{Reject {Apply $clean 'tang-buyi' 'minimal'} '*INJECTED_CHARACTER_WRITE_FAILURE*' 'Failure injection covers removal of obsolete NPC PNG files'}finally{Clear-Failure}
    Assert ((Hash (StatePath $clean))-eq $beforeSubset-and(Same $brother (Snapshot (Join-Path $clean ($plugin+'\Characters\tang-buyi'))))) 'Failed subset switch restores all removed PNGs and previous selection'
    $null=Apply $clean 'tang-buyi' 'minimal';$subset=State $clean
    Assert (@($subset.OwnedFiles|Where-Object{$_.CharacterId-eq 'tang-buyi'-and-not $_.InstalledPresent}).Count-eq 14-and @(Get-ChildItem -LiteralPath (Join-Path $clean ($plugin+'\Characters\tang-buyi\Portraits')) -File).Count-eq 1) 'Subset switch removes stale replacements and retains their ownership history'
    $null=Apply $clean 'tang-buyi' 'refined'
    Assert ((Same $brother (Snapshot (Join-Path $clean ($plugin+'\Characters\tang-buyi'))))) 'Switching back restores complete NPC payload from the selected source'
    foreach($v in @('white','veteran','handsome','xianxia','natural')){$null=Apply $clean 'player' $v;Assert ((State $clean).Characters[0].SelectedVariantId-eq $v) ('Player style applies: '+$v)}
    $status=Get-PortraitManagerState -GamePath $clean -PackageRoot $package
    Assert ($status.Status-eq 'Installed'-and-not $status.RequiresMigration-and $status.Characters[2].InstalledVariantId-eq 'refined') 'Status reports independent installed selections'
    $other=Join-Path $clean 'BepInEx\plugins\Other\user.txt';Write-Text $other 'OTHER MOD'
    $null=Apply $clean 'tang-buyi' 'minimal'
    $reintroduced=Join-Path $clean ($plugin+'\Characters\tang-buyi\Portraits\angry1.png')
    Copy-Item -LiteralPath (Join-Path $package 'Variants\tang-buyi\refined\Portraits\angry1.png') -Destination $reintroduced
    $reintroducedHash=Hash $reintroduced
    Uninstall-PortraitManager -GamePath $clean -Log $quiet
    Assert (-not(Test-Path -LiteralPath (StatePath $clean))-and-not(Test-Path -LiteralPath (Join-Path $clean 'winhttp.dll'))-and(Get-Content -LiteralPath $other)-eq 'OTHER MOD') 'All-character uninstall removes newly owned runtime and preserves another mod'
    Assert (@(Get-ChildItem -LiteralPath (Join-Path $clean 'BepInEx\ZhaoHuoNatural-install\Backups') -Recurse -File|Where-Object{$_.FullName-like '*\Preserved-*\*'-and $_.Name-eq 'angry1.png'-and(Hash $_.FullName)-eq $reintroducedHash}).Count-eq 1) 'Uninstall preserves an externally reintroduced file at a deliberately absent owned path'
    foreach($id in @('natural','handsome','xianxia')){
        $legacy=Legacy-Package $id;$game=New-Game ('upgrade-'+$id) -Existing
        $oldPlugin=Join-Path $game 'BepInEx\plugins\Tianfei\MortalBeauty.dll';Write-Text $oldPlugin 'ORIGINAL LEGACY DLL'
        $null=Install-ZhaoHuo -GamePath $game -PackageRoot $legacy -VariantId $id -Log $quiet
        $beforeState=State $game;$first=Join-Path (Join-Path $game 'BepInEx\ZhaoHuoNatural-install') $beforeState.BackupRelativePath
        Write-Text (Join-Path $first 'Switches\historical-fixture\Files\retained-snapshot.txt') 'PRIOR SWITCH SNAPSHOT MUST REMAIN'
        $historicalBefore=Snapshot $first
        $originalLoader=Hash (Join-Path $first 'Original\winhttp.dll');$originalLegacy=Hash (Join-Path $first 'MortalBeauty.dll')
        # v1.0.x public schema3 had no explicit variant metadata.
        if($id-eq 'natural'){$beforeState.PSObject.Properties.Remove('VariantId');$beforeState.PSObject.Properties.Remove('PayloadFingerprint');Save-Json (StatePath $game) $beforeState}
        $status=Get-PortraitManagerState -GamePath $game -PackageRoot $package
        Assert ($status.Status-eq 'Installed'-and $status.RequiresMigration-and $status.Characters[0].InstalledVariantId-eq $id) ('Recognizes old schema3 '+$id)
        $oldPNGs=Snapshot (Join-Path $game ($plugin+'\Portraits'))
        $null=Apply $game 'tang-buyi' 'refined';$after=State $game
        Assert ($after.SchemaVersion-eq 4-and $after.InstallationId-eq $beforeState.InstallationId-and $after.BackupRelativePath-eq $beforeState.BackupRelativePath) ('Migration preserves first installation identity: '+$id)
        Assert ((Same $oldPNGs (Snapshot (Join-Path $game ($plugin+'\Portraits'))))-and $after.Characters[0].SelectedVariantId-eq $id) ('Migration preserves existing player bytes: '+$id)
        Assert ((Hash (Join-Path $first 'Original\winhttp.dll'))-eq $originalLoader-and(Hash (Join-Path $first 'MortalBeauty.dll'))-eq $originalLegacy) ('Migration retains immutable original backups: '+$id)
        $historyUnchanged=$true;foreach($relative in $historicalBefore.Keys){if((Hash (Join-Path $first $relative))-ne $historicalBefore[$relative]){$historyUnchanged=$false}}
        Assert $historyUnchanged ('Migration also retains every earlier switch snapshot: '+$id)
        $null=Apply $game 'player' 'veteran';$null=Apply $game 'xiahou-lan' 'refined';$null=Apply $game 'player' 'original'
        Uninstall-PortraitManager -GamePath $game -Log $quiet
        Assert ((Hash (Join-Path $game 'winhttp.dll'))-eq $originalLoader-and(Get-Content -LiteralPath $oldPlugin)-eq 'ORIGINAL LEGACY DLL'-and-not(Test-Path -LiteralPath (Join-Path $game $plugin))) ('Uninstall after migration and mixed switches restores original state: '+$id)
    }
    $game=New-Game 'failure-existing' -Existing;$legacy=Legacy-Package 'natural'
    $null=Install-ZhaoHuo -GamePath $game -PackageRoot $legacy -Log $quiet
    $oldState=Hash (StatePath $game);$oldPayload=Snapshot (Join-Path $game $plugin)
    Inject-Failure $game '*\Characters\tang-buyi\portrait-layout.tsv'
    try{Reject {Apply $game 'tang-buyi' 'refined'} '*INJECTED_CHARACTER_WRITE_FAILURE*' 'Inject failure after shared runtime and NPC PNG writes'}finally{Clear-Failure}
    Assert ((Hash (StatePath $game))-eq $oldState-and(Same $oldPayload (Snapshot (Join-Path $game $plugin)))) 'Failed migration restores exact schema3 manifest and complete old payload'
    $fresh=New-Game 'failure-fresh'
    Inject-Failure $fresh '*\characters.json'
    try{Reject {Apply $fresh 'xiahou-lan' 'refined'} '*INJECTED_CHARACTER_WRITE_FAILURE*' 'Fresh install failure at final runtime configuration'}finally{Clear-Failure}
    Assert (-not(Test-Path -LiteralPath (StatePath $fresh))-and-not(Test-Path -LiteralPath (Join-Path $fresh 'winhttp.dll'))-and-not(Test-Path -LiteralPath (Join-Path $fresh $plugin))) 'Fresh failed transaction removes only newly added owned files'
    $null=Apply $game 'player' 'natural';$prior=Hash (StatePath $game);$priorPayload=Snapshot (Join-Path $game $plugin)
    Inject-Failure $game '*\characters.json' -Interrupt
    try{Reject {Apply $game 'xiahou-lan' 'refined'} '*INJECTED_CHARACTER_WRITE_FAILURE*' 'Simulate process interruption before final config commit'}finally{Clear-Failure}
    $pending=Get-PortraitManagerState -GamePath $game -PackageRoot $package
    Assert ($pending.Status-eq 'RecoveryRequired') 'Interrupted state does not falsely identify installed appearance'
    $snap=Snapshot $game;$checked=Check $game 'xiahou-lan' 'refined'
    Assert ($checked.Status-eq 'RecoveryRequired'-and(Same $snap (Snapshot $game))) 'Interrupted check validates recovery without writing'
    & $module {param($Game) $null=Restore-ZHSwitch (Get-ZHLocations $Game)} $game
    Assert ((Hash (StatePath $game))-eq $prior-and(Same $priorPayload (Snapshot (Join-Path $game $plugin)))) 'Recovery restores exact pre-interruption mixed selections and files'
    $saved=Get-Content -LiteralPath (StatePath $game) -Raw -Encoding UTF8
    $invalid=State $game;@($invalid.OwnedFiles|Where-Object RelativePath -like '*\Portraits\normal.png')[0].CharacterId='xiahou-lan';Save-Json (StatePath $game) $invalid
    Reject {Check $game 'tang-buyi' 'refined'} '*所属角色*' 'Forged cross-character ownership is rejected'
    Write-Text (StatePath $game) $saved
    $modified=Join-Path $game ($plugin+'\Portraits\normal.png');Write-Text $modified 'USER MODIFIED PNG'
    Reject {Apply $game 'tang-buyi' 'refined'} '*被修改或缺失*' 'External portrait edits block all transactions'
    $state=Get-PortraitManagerState -GamePath $game -PackageRoot $package
    Assert ($state.Status-eq 'Modified'-and @($state.Characters|Where-Object State -ne 'Unknown').Count-eq 0) 'Damaged state never displays original as known installed selection'
    Uninstall-PortraitManager -GamePath $game -Log $quiet
    Assert (@(Get-ChildItem -LiteralPath (Join-Path $game 'BepInEx\ZhaoHuoNatural-install\Backups') -Recurse -File|Where-Object{$_.Name-eq 'normal.png'-and(Get-Content -LiteralPath $_.FullName -Raw)-eq 'USER MODIFIED PNG'}).Count-eq 1) 'Uninstall preserves user-modified owned image in backup'
    $unknown=New-Game 'unknown-payload';Write-Text (Join-Path $unknown ($plugin+'\unknown.txt')) 'USER FILE'
    Reject {Apply $unknown 'player' 'natural'} '*未登记*' 'Unregistered manually extracted directory is not adopted'
    $race=New-Game 'planning-race'
    $racePlan=Get-PortraitApplyPlan -GamePath $race -PackageRoot $package -CharacterId player -VariantId natural
    Write-Text (Join-Path $race 'doorstop_config.ini') 'USER CONFIG CREATED AFTER CHECK'
    Reject {& $module {param($Plan) Invoke-ZHCharacterTransaction $Plan} $racePlan} '*外部改动*' 'A new file appearing after planning is rejected before transaction'
    Assert ((Get-Content -LiteralPath (Join-Path $race 'doorstop_config.ini') -Raw)-eq 'USER CONFIG CREATED AFTER CHECK'-and-not(Test-Path -LiteralPath (StatePath $race))) 'Rejected race preserves external file and creates no active installation'
    $badCatalog=Get-Content -LiteralPath (Join-Path $package 'VariantCatalog.json') -Raw -Encoding UTF8
    $catalog.Characters[1].Variants[1].SourcePath=$catalog.Characters[2].Variants[1].SourcePath;Save-Json (Join-Path $package 'VariantCatalog.json') $catalog
    Reject {Get-PortraitCharacters -PackageRoot $package} '*跨角色*' 'Cross-character source path is rejected'
    Write-Text (Join-Path $package 'VariantCatalog.json') $badCatalog;$catalog=$badCatalog|ConvertFrom-Json
    $catalog.Characters[1].Variants[1].Files[0].Name='../normal.png';Save-Json (Join-Path $package 'VariantCatalog.json') $catalog
    Reject {Get-PortraitCharacters -PackageRoot $package} '*图片清单*' 'Catalog traversal is rejected before file access'
    Write-Text (Join-Path $package 'VariantCatalog.json') $badCatalog
    $catalog=$badCatalog|ConvertFrom-Json;$sharedPath=Join-Path $package ($plugin+'\ZhaoHuoNatural.dll');$oldDll=[IO.File]::ReadAllText($sharedPath)
    Write-Text $sharedPath 'UNAPPROVED EXECUTABLE CONTENT';$catalog.SharedFiles[0].Sha256=Hash $sharedPath;Save-Json (Join-Path $package 'VariantCatalog.json') $catalog
    Reject {Get-PortraitCharacters -PackageRoot $package} '*认可的版本*' 'Editing both DLL and catalog hash cannot approve an unknown runtime'
    Write-Text $sharedPath $oldDll;Write-Text (Join-Path $package 'VariantCatalog.json') $badCatalog
    $private=New-Game 'private-schema';$legacy=Legacy-Package 'natural';$null=Install-ZhaoHuo -GamePath $private -PackageRoot $legacy -Log $quiet
    $state=State $private;$state.SchemaVersion=2;Save-Json (StatePath $private) $state
    Reject {Apply $private 'player' 'natural'} '*私人*' 'Insufficiently evidenced private schema2 is not auto-migrated'
    foreach($file in $codeHashes.Keys){if($file-ne 'VariantCatalog.json'-and (Test-CodeHash (Join-Path $repo $file))-ne $codeHashes[$file]){throw ('Tested source changed during the suite: '+$file)}}
    $summary=[ordered]@{status='passed';powershell=$PSVersionTable.PSVersion.ToString();assertionCount=$checks.Count;durationSeconds=[Math]::Round(([DateTime]::UtcNow-$start).TotalSeconds,2);scope='Synthetic inert game/PNG fixtures and official offline loader; no real game writes or game assembly execution. Production readiness was not modified; dummy fixtures are not distributable.';ProductionReadyAtTest=$prod.PackageReady;CodeHashAlgorithm='SHA256-UTF8-noBOM-LF-v1';CodeHashes=$codeHashes;checks=@($checks)}
    if(-not $OutputPath){$OutputPath=Join-Path $PSScriptRoot 'character-manager-results.json'}
    Save-Json $OutputPath $summary
    Write-Host ('ALL '+$checks.Count+' CHARACTER ASSERTIONS PASSED')
}catch{Write-Host $_.ScriptStackTrace;throw}
