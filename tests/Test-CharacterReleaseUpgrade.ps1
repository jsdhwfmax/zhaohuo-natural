#requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$PreviousPackageRoot,
    [Parameter(Mandatory=$true)][string]$OutputPath
)
# Exercise the genuine released v2.1.0 installer first, then the current one.
# Every game, DLL and portrait used by the transactions below is an inert fixture.
$ErrorActionPreference='Stop';Set-StrictMode -Version 2.0
$repo=Split-Path -Parent $PSScriptRoot
$previous=[IO.Path]::GetFullPath($PreviousPackageRoot)
$oldCatalog=Get-Content -LiteralPath (Join-Path $previous 'VariantCatalog.json') -Raw -Encoding UTF8|ConvertFrom-Json
if($oldCatalog.PackageVersion-ne '2.1.0'-or $oldCatalog.RuntimeProtocol-ne 2){throw 'A complete genuine v2.1.0 source package is required.'}
$newCatalog=Get-Content -LiteralPath (Join-Path $repo 'VariantCatalog.json') -Raw -Encoding UTF8|ConvertFrom-Json
$productionDll=@($newCatalog.SharedFiles|Where-Object Name -eq 'ZhaoHuoNatural.dll')[0].Sha256
$work=Join-Path $PSScriptRoot ('.work\release-upgrade-'+[Guid]::NewGuid().ToString('N'))
$package=Join-Path $work 'Fixture package';$plugin='BepInEx\plugins\ZhaoHuoNatural'
$quiet={param($Message,$Level)};$checks=New-Object 'System.Collections.Generic.List[string]';$start=[DateTime]::UtcNow
$helper=Join-Path $PSScriptRoot 'Test-CharacterManager.ps1';$tokens=$null;$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile($helper,[ref]$tokens,[ref]$errors)
if($errors.Count){throw 'Fixture helper parse failed.'}
foreach($name in @('Write-Text','Save-Json','Hash','Assert','Reject','State','StatePath','Snapshot','Same','Apply','Check','New-Game','Inject-Failure','Clear-Failure')){
    $found=@($ast.FindAll({param($a)$a-is [Management.Automation.Language.FunctionDefinitionAst]-and $a.Name-eq $name},$true))
    if($found.Count-ne 1){throw ('Fixture helper missing: '+$name)}
    . ([scriptblock]::Create($found[0].Extent.Text))
}
function CodeHash([string]$Path){
    $text=[IO.File]::ReadAllText($Path).TrimStart([char]0xFEFF).Replace("`r`n","`n").Replace("`r","`n")
    $sha=[Security.Cryptography.SHA256]::Create()
    try{([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($text)))).Replace('-','')}finally{$sha.Dispose()}
}
function Assert-PreviousFiles([hashtable]$Before,[string]$Root,[string]$Name){
    $ok=$true;foreach($key in $Before.Keys){$p=Join-Path $Root $key;if(-not(Test-Path -LiteralPath $p -PathType Leaf)-or(Hash $p)-ne $Before[$key]){$ok=$false}}
    Assert $ok $Name
}
New-Item -ItemType Directory -Path $package -Force|Out-Null
Copy-Item -LiteralPath (Join-Path $repo 'Dependencies') -Destination $package -Recurse
Copy-Item -LiteralPath (Join-Path $repo 'Loader') -Destination $package -Recurse
$module=Import-Module (Join-Path $previous 'installer\ZhaoHuoInstaller.psm1') -Force -PassThru
$oldSourceHashes=@(Get-ChildItem -LiteralPath (Join-Path $previous 'installer') -File|Where-Object{$_.Extension-in @('.ps1','.psm1')}|ForEach-Object{[pscustomobject]@{Path=('installer/'+$_.Name);Sha256=(CodeHash $_.FullName)}})
foreach($character in $newCatalog.Characters){
    $names=@(& $module {param($Id)$script:CharacterAssets[$Id]} $character.Id)
    $layout="expression`tcanvasWidth`tcanvasHeight`tx`ty`twidth`theight`n"+(@($names|ForEach-Object{$_+"`t10`t10`t0`t0`t10`t10"})-join "`n")
    Write-Text (Join-Path $package $character.LayoutSourcePath) $layout
    $character.LayoutSha256=Hash (Join-Path $package $character.LayoutSourcePath)
    foreach($variant in $character.Variants){
        if($variant.Kind-eq 'original'){continue}
        $files=@(foreach($name in $names){if($name-in @($variant.OriginalFallback)){continue};$p=Join-Path $package ($variant.SourcePath+'/'+$name+'.png');Write-Text $p ('INERT PNG '+$character.Id+'/'+$variant.Id+'/'+$name);[pscustomobject]@{Name=($name+'.png');Sha256=(Hash $p)}})
        $variant.Files=$files;$variant.AssetFingerprint=& $module {param($Id,$Files)Get-ZHCharacterFingerprint $Id $Files} $character.Id $files;$variant.Ready=$true
    }
}
foreach($entry in $newCatalog.SharedFiles){$p=Join-Path $package ($plugin+'\'+$entry.Name);if($entry.Name-ne 'portrait-layout.tsv'){Write-Text $p ('INERT UNCHANGED SHARED '+$entry.Name)};$entry.Sha256=Hash $p}
$newCatalog.PackageReady=$true
$catalog=$newCatalog|ConvertTo-Json -Depth 20|ConvertFrom-Json
$catalog.PackageVersion='2.1.0';$catalog.Characters[0].Variants=@($catalog.Characters[0].Variants|Where-Object Id -ne 'hardman')
Save-Json (Join-Path $package 'VariantCatalog.json') $catalog
& $module {param($Shared)foreach($e in $Shared){$script:CharacterSharedHashes[$e.Name]=$e.Sha256}} $catalog.SharedFiles
$pe=New-Object byte[] 256;$pe[0]=0x4D;$pe[1]=0x5A;$pe[0x3C]=0x80;$pe[0x80]=0x50;$pe[0x81]=0x45;$pe[0x84]=0x64;$pe[0x85]=0x86
$game=New-Game 'upgrade' -Existing
$legacy=Join-Path $game 'BepInEx\plugins\Tianfei\MortalBeauty.dll';Write-Text $legacy 'ORIGINAL LEGACY PLUGIN'
$other=Join-Path $game 'BepInEx\plugins\Other\Other.dll';Write-Text $other 'UNRELATED USER PLUGIN'
$save=Join-Path $game 'UserData\save.json';Write-Text $save 'INERT USER SAVE'
$initialLoader=Hash (Join-Path $game 'winhttp.dll');$initialCore=Snapshot (Join-Path $game 'BepInEx\core')
$choices=[ordered]@{player='xianxia';'tang-buyi'='female';'xiahou-lan'='refined';'tang-moling'='refined';'long-xiang'='refined';'yu-xiaomei'='refined';'tang-zheng'='female'}
foreach($role in $choices.Keys){$null=Apply $game $role $choices[$role]}
$before=State $game;$beforeManifest=Hash (StatePath $game);$payloadBefore=Snapshot (Join-Path $game $plugin)
$first=Join-Path (Join-Path $game 'BepInEx\ZhaoHuoNatural-install') $before.BackupRelativePath;$backups=Snapshot $first
Assert ($before.SchemaVersion-eq 4-and $before.RuntimeProtocol-eq 2-and $before.Characters.Count-eq 7) 'Released v2.1.0 installer creates the seven-role schema4/protocol2 source installation'
Remove-Module $module
$module=Import-Module (Join-Path $repo 'installer\ZhaoHuoInstaller.psm1') -Force -PassThru
$group=@(& $module {$script:SupportedGameBuilds|Where-Object BuildId -eq '25987745'})
Assert ($group.Count-eq 1-and $group[0].Hashes.Count-eq 4-and $group[0].Hashes['Mortal.Core.dll']-eq 'C0CF84F41F110DD475D62AFFB58681BA4A1E5B3DEEC7698B8349D85876EA8A9C') 'New game support declares a complete build25987745 fingerprint group'
$fixtureHashes=[ordered]@{};foreach($name in @('Assembly-CSharp.dll','Mortal.Core.dll','Mortal.Story.dll','Fungus.dll')){$fixtureHashes[$name]=Hash (Join-Path $game ('Mortal_Data\Managed\'+$name))}
& $module {param($Shared,$Hashes)foreach($e in $Shared){$script:CharacterSharedHashes[$e.Name]=$e.Sha256};$script:SupportedGameBuilds=@([pscustomobject]@{BuildId='90000001';Hashes=$Hashes})} $newCatalog.SharedFiles $fixtureHashes
$catalog=$newCatalog;Save-Json (Join-Path $package 'VariantCatalog.json') $catalog
$snap=Snapshot $game;$result=Check $game 'player' 'xianxia'
Assert ($result.Status-eq 'Checked'-and $result.ChangedFiles-eq 0-and(Same $snap (Snapshot $game))) 'New manager checks an old complete installation without rewriting any file'
$result=Apply $game 'player' 'xianxia';$after=State $game
Assert ($result.Status-eq 'NoOp'-and-not $result.RequiresMigration-and(Same $snap (Snapshot $game))) 'v2.1.0 to current same-selection upgrade is a complete file no-op'
Assert (($after.Characters|ConvertTo-Json -Depth 8)-ceq($before.Characters|ConvertTo-Json -Depth 8)) 'All seven existing character selections survive the manager upgrade'
$plan=Get-PortraitApplyPlan -GamePath $game -PackageRoot $package -CharacterId player -VariantId hardman
Assert ($plan.Actions.Count-eq 47-and @($plan.Actions|Where-Object{$_.CharacterId-ne 'player'-or $_.Category-ne 'CharacterPortrait'}).Count-eq 0) 'New hardman appearance plans only its 47 player PNG replacements'
Inject-Failure $game '@commit'
try{Reject {Apply $game 'player' 'hardman'} '*INJECTED_CHARACTER_WRITE_FAILURE*' 'A failed hardman manifest commit is injected after portrait writes'}finally{Clear-Failure}
Assert ((Hash (StatePath $game))-eq $beforeManifest-and(Same $payloadBefore (Snapshot (Join-Path $game $plugin)))) 'Failed switch restores the exact v2.1.0 selections and payload'
Inject-Failure $game '@commit' -Interrupt
try{Reject {Apply $game 'player' 'hardman'} '*INJECTED_CHARACTER_WRITE_FAILURE*' 'Interrupted hardman switch remains recoverable'}finally{Clear-Failure}
$snap=Snapshot $game;$check=Check $game 'player' 'hardman'
Assert ($check.Status-eq 'RecoveryRequired'-and(Same $snap (Snapshot $game))) 'Interrupted upgrade check does not write or misreport success'
& $module {param($Game)$null=Restore-ZHSwitch (Get-ZHLocations $Game)} $game
Assert ((Hash (StatePath $game))-eq $beforeManifest-and(Same $payloadBefore (Snapshot (Join-Path $game $plugin)))) 'Interrupted upgrade recovery restores the original installed version'
$result=Apply $game 'player' 'hardman';$after=State $game
Assert ($result.ChangedFiles-eq 47-and $after.InstallationId-eq $before.InstallationId-and $after.BackupRelativePath-eq $before.BackupRelativePath) 'Successful hardman switch preserves the first installation identity and backup root'
$otherRoles=@($after.Characters|Where-Object Id -ne 'player')|ConvertTo-Json -Depth 8
Assert ($otherRoles-ceq(@($before.Characters|Where-Object Id -ne 'player')|ConvertTo-Json -Depth 8)) 'Selecting hardman leaves all six NPC selections unchanged'
Assert-PreviousFiles $backups $first 'Every pre-existing original backup and transaction snapshot remains unchanged'
$modified=Join-Path $game ($plugin+'\Portraits\normal.png');$original=Hash $modified;Write-Text $modified 'EXTERNAL USER CHANGE'
Reject {Apply $game 'player' 'xianxia'} '*修改*' 'Externally modified portraits block switching instead of being overwritten'
Copy-Item -LiteralPath (Join-Path $package 'Variants/player/hardman/Portraits/normal.png') -Destination $modified
Assert ((Hash $modified)-eq $original) 'Only the isolated modified fixture is restored for subsequent checks'
$null=Apply $game 'player' 'xianxia';$restored=State $game
Assert (($restored.Characters|ConvertTo-Json -Depth 8)-ceq($before.Characters|ConvertTo-Json -Depth 8)-and(Same $payloadBefore (Snapshot (Join-Path $game $plugin)))) 'Switching back restores the complete previous mixed appearance set'
Assert ((Same $initialCore (Snapshot (Join-Path $game 'BepInEx\core')))-and(Hash (Join-Path $game 'winhttp.dll'))-eq $initialLoader-and(Get-Content $other -Raw)-eq 'UNRELATED USER PLUGIN'-and(Get-Content $save -Raw)-eq 'INERT USER SAVE') 'Loader, existing BepInEx, unrelated plugin and save fixture remain unchanged'
Uninstall-PortraitManager -GamePath $game -Log $quiet
Assert (-not(Test-Path -LiteralPath (Join-Path $game $plugin))-and(Get-Content $legacy -Raw)-eq 'ORIGINAL LEGACY PLUGIN'-and(Get-Content $other -Raw)-eq 'UNRELATED USER PLUGIN') 'Uninstall after the release upgrade restores the original legacy plugin and preserves unrelated files'
$code=@('installer/ZhaoHuoInstaller.psm1','installer/AppearanceManager.ps1','installer/VariantSupport.ps1','installer/CharacterCatalog.ps1','installer/CharacterState.ps1','installer/CharacterManager.ps1','installer/CharacterTransactions.ps1','tests/Test-CharacterManager.ps1','tests/Test-CharacterReleaseUpgrade.ps1')
$report=[ordered]@{Passed=$true;FromVersion='2.1.0';ToVersion=$newCatalog.PackageVersion;RuntimeVersion='2.1.0';RuntimeProtocol=2;ExecutionMode='IsolatedPreviousReleaseInstallation';ActualGameRun=$false;RealGameFilesModified=$false;ProductionPluginSha256=$productionDll;AssertionCount=$checks.Count;Checks=$checks.ToArray();InitialInstallationPreserved=$true;OriginalBackupsPreserved=$true;OtherPluginsPreserved=$true;AllExistingSelectionsPreserved=$true;PowerShell=$PSVersionTable.PSVersion.ToString();DurationSeconds=[Math]::Round(([DateTime]::UtcNow-$start).TotalSeconds,2);PreviousInstallerCodeHashes=$oldSourceHashes;CodeHashAlgorithm='SHA256-UTF8-noBOM-LF-v1';CodeHashes=@($code|ForEach-Object{[pscustomobject]@{Path=$_;Sha256=(CodeHash (Join-Path $repo $_))}});Scope='Genuine released v2.1.0 installer creates an isolated inert seven-role installation. The current manager checks it, preserves every selection, switches hardman, rolls back a failure, recovers an interruption, rejects external edits and uninstalls. No game code or real game files are used. Dummy payload hashes are accepted only inside this test process; artwork acceptance is separate.'}
Save-Json $OutputPath $report
Write-Host ('ALL '+$checks.Count+' RELEASE UPGRADE ASSERTIONS PASSED')
