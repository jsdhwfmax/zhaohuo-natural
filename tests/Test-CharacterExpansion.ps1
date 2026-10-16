#requires -Version 5.1
[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$OutputPath)
$ErrorActionPreference='Stop';Set-StrictMode -Version 2.0
$repo=Split-Path -Parent $PSScriptRoot
$module=Import-Module (Join-Path $repo 'installer\ZhaoHuoInstaller.psm1') -Force -PassThru
$work=Join-Path $PSScriptRoot ('.work\expansion-'+[Guid]::NewGuid().ToString('N'))
$package=Join-Path $work 'Fixture package';$plugin='BepInEx\plugins\ZhaoHuoNatural'
$quiet={param($Message,$Level)};$checks=New-Object 'System.Collections.Generic.List[string]';$start=[DateTime]::UtcNow
$helperPath=Join-Path $PSScriptRoot 'Test-CharacterManager.ps1';$tokens=$null;$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile($helperPath,[ref]$tokens,[ref]$errors)
if($errors.Count){throw 'Fixture helper parse failed.'}
foreach($name in @('Write-Text','Save-Json','Hash','Assert','Reject','State','StatePath','Snapshot','Same','Apply','Check','New-Game','Inject-Failure','Clear-Failure')){
    $found=@($ast.FindAll({param($a)$a-is [Management.Automation.Language.FunctionDefinitionAst]-and $a.Name-eq $name},$true))
    if($found.Count-ne 1){throw ('Fixture helper unavailable: '+$name)}
    . ([scriptblock]::Create($found[0].Extent.Text))
}
$production=Get-PortraitCharacters -PackageRoot $repo
$sourceCatalog=Get-Content -LiteralPath (Join-Path $repo 'VariantCatalog.json') -Raw -Encoding UTF8|ConvertFrom-Json
$oldProduction=@($sourceCatalog.Characters|Where-Object{$_.Id-in @('player','tang-buyi','xiahou-lan')}|ForEach-Object{$_.Variants}|Where-Object{$_.Kind-eq 'custom'-and $_.Id-ne 'female'})
$productionBefore=@{};foreach($variant in $oldProduction){foreach($file in $variant.Files){$relative=$variant.SourcePath+'/'+$file.Name;$productionBefore[$relative]=Hash (Join-Path $repo $relative)}}
Assert ($productionBefore.Count-eq 312) 'All 312 previously released PNGs are included in the unchanged-input guard'
$pe=New-Object byte[] 256;$pe[0]=0x4D;$pe[1]=0x5A;$pe[0x3C]=0x80;$pe[0x80]=0x50;$pe[0x81]=0x45;$pe[0x84]=0x64;$pe[0x85]=0x86
New-Item -ItemType Directory -Path $package -Force|Out-Null
Copy-Item -LiteralPath (Join-Path $repo 'Dependencies') -Destination $package -Recurse
Copy-Item -LiteralPath (Join-Path $repo 'Loader') -Destination $package -Recurse
$catalog=$sourceCatalog|ConvertTo-Json -Depth 30|ConvertFrom-Json
$temporaryAllowlists=@()
foreach($character in $catalog.Characters){
    $names=@(& $module {param($Id)$script:CharacterAssets[$Id]} $character.Id)
    if(-not $names.Count){throw ('Production resource allowlist is not yet verified: '+$character.Id)}
    $layout="expression`tcanvasWidth`tcanvasHeight`tx`ty`twidth`theight`n"+(@($names|ForEach-Object{$_+"`t10`t10`t0`t0`t10`t10"})-join "`n")
    Write-Text (Join-Path $package $character.LayoutSourcePath) $layout;$character.LayoutSha256=Hash (Join-Path $package $character.LayoutSourcePath)
    foreach($v in $character.Variants){
        if($v.Kind-eq 'original'){continue}
        $fallback=@($v.OriginalFallback)
        $v.Files=@(foreach($name in $names){if($name-in $fallback){continue};$path=Join-Path $package ($v.SourcePath+'/'+$name+'.png');Write-Text $path ('INERT EXPANSION FIXTURE '+$character.Id+'/'+$v.Id+'/'+$name);[pscustomobject]@{Name=($name+'.png');Sha256=(Hash $path)}})
        $v.OriginalFallback=@($fallback);$v.AssetFingerprint=& $module {param($Id,$Files)Get-ZHCharacterFingerprint $Id $Files} $character.Id $v.Files;$v.Ready=$true
    }
}
foreach($entry in $catalog.SharedFiles){$path=Join-Path $package ($plugin+'\'+$entry.Name);if($entry.Name-ne 'portrait-layout.tsv'){Write-Text $path ('INERT OLD SHARED '+$entry.Name)};$entry.Sha256=Hash $path}
& $module {param($Shared)foreach($entry in $Shared){$script:CharacterSharedHashes[$entry.Name]=$entry.Sha256}} $catalog.SharedFiles
$catalog.PackageReady=$true;Save-Json (Join-Path $package 'VariantCatalog.json') $catalog
$view=Get-PortraitCharacters -PackageRoot $package
Assert ($view.Characters.Count-eq 7-and @($view.Characters.Variants).Count-eq 20) 'Expanded catalog exposes seven independent roles and twenty choices'
$game=New-Game 'protocol-upgrade' -Existing
$legacyPlugin=Join-Path $game 'BepInEx\plugins\Tianfei\MortalBeauty.dll';Write-Text $legacyPlugin 'ORIGINAL LEGACY PLUGIN'
$otherPlugin=Join-Path $game 'BepInEx\plugins\Other\user.dll';Write-Text $otherPlugin 'UNCHANGED OTHER MOD'
$null=Apply $game 'player' 'white';$null=Apply $game 'tang-buyi' 'refined';$null=Apply $game 'xiahou-lan' 'refined'
# Form a valid historical schema4/protocol1 fixture: old three-role choices,
# old shared DLL and the exact old configuration schema, with its owned hash.
$old=State $game;$old.RuntimeProtocol=1;$old.Characters=@($old.Characters|Where-Object{$_.Id-in @('player','tang-buyi','xiahou-lan')})
$configRelative=$plugin+'\characters.json';$configPath=Join-Path $game $configRelative
$config=[ordered]@{SchemaVersion=1;Characters=@($old.Characters|ForEach-Object{[ordered]@{Id=$_.Id;Enabled=($_.SelectedVariantId-ne 'original')}})}
Save-Json $configPath $config;@($old.OwnedFiles|Where-Object RelativePath -eq $configRelative)[0].InstalledSha256=Hash $configPath
Save-Json (StatePath $game) $old
$oldManifestBytes=[IO.File]::ReadAllBytes((StatePath $game));$oldManifestHash=Hash (StatePath $game);$oldPayload=Snapshot (Join-Path $game $plugin)
$first=Join-Path (Join-Path $game 'BepInEx\ZhaoHuoNatural-install') $old.BackupRelativePath;$backupBefore=Snapshot $first
$dllRelative=$plugin+'\ZhaoHuoNatural.dll';$dllPath=Join-Path $game $dllRelative
$dllSource=Join-Path $package $dllRelative;Write-Text $dllSource 'INERT NEW SEVEN-ROLE SHARED DLL'
$newDllHash=Hash $dllSource;@($catalog.SharedFiles|Where-Object Name -eq 'ZhaoHuoNatural.dll')[0].Sha256=$newDllHash
& $module {param($Hash)$script:CharacterSharedHashes['ZhaoHuoNatural.dll']=$Hash} $newDllHash
Save-Json (Join-Path $package 'VariantCatalog.json') $catalog
$status=Get-PortraitManagerState -GamePath $game -PackageRoot $package
Assert ($status.Status-eq 'Installed'-and $status.RequiresMigration-and $status.Characters.Count-eq 7-and @($status.Characters|Where-Object{$_.Id-notin @('player','tang-buyi','xiahou-lan')-and $_.InstalledVariantId-ne 'original'}).Count-eq 0) 'Valid v2.0 state is recognized and new characters preview as original'
$plan=Get-PortraitApplyPlan -GamePath $game -PackageRoot $package -CharacterId player -VariantId white
Assert ($plan.RequiresMigration-and-not $plan.NoOp-and $plan.Actions.Count-eq 2-and $plan.Actions[-1].RelativePath-eq $configRelative-and $plan.BeforeCharacters.Count-eq 3-and $plan.After.Characters.Count-eq 7) 'Same-selection migration writes only shared DLL and final seven-role config'
$snapshot=Snapshot $game;$null=Check $game 'player' 'white'
Assert (Same $snapshot (Snapshot $game)) 'Migration check-only preserves every fixture byte'
$bad=State $game;$bad.RuntimeProtocol=2;Save-Json (StatePath $game) $bad
Reject {Check $game 'player' 'white'} '*协议无效*' 'Incomplete protocol2 state is rejected instead of silently filling choices'
[IO.File]::WriteAllBytes((StatePath $game),$oldManifestBytes)
$bad=State $game;$bad.Characters[2].Id='long-xiang';Save-Json (StatePath $game) $bad
Reject {Check $game 'player' 'white'} '*未知或重复角色*' 'Protocol1 cannot substitute a new role for a missing old role'
[IO.File]::WriteAllBytes((StatePath $game),$oldManifestBytes)
$configText=[IO.File]::ReadAllText($configPath);$config.SchemaVersion=2;Save-Json $configPath $config
$bad=State $game;@($bad.OwnedFiles|Where-Object RelativePath -eq $configRelative)[0].InstalledSha256=Hash $configPath;Save-Json (StatePath $game) $bad
Reject {Check $game 'player' 'white'} '*角色开关无效*' 'Mixed protocol1 manifest and protocol2 config are rejected even with an updated owned hash'
Write-Text $configPath $configText;[IO.File]::WriteAllBytes((StatePath $game),$oldManifestBytes)
Inject-Failure $game '@commit'
try{Reject {Apply $game 'player' 'white'} '*INJECTED_CHARACTER_WRITE_FAILURE*' 'Inject failure after both migration writes before manifest commit'}finally{Clear-Failure}
Assert ((Hash (StatePath $game))-eq $oldManifestHash-and(Same $oldPayload (Snapshot (Join-Path $game $plugin)))) 'Failed upgrade restores the exact three-role manifest, config and DLL'
Inject-Failure $game '@commit' -Interrupt
try{Reject {Apply $game 'player' 'white'} '*INJECTED_CHARACTER_WRITE_FAILURE*' 'Simulate process interruption after migration writes'}finally{Clear-Failure}
Assert ((Get-PortraitManagerState -GamePath $game -PackageRoot $package).Status-eq 'RecoveryRequired') 'Interrupted migration never claims an installed selection'
$snapshot=Snapshot $game;$recovery=Check $game 'player' 'white'
Assert ($recovery.Status-eq 'RecoveryRequired'-and(Same $snapshot (Snapshot $game))) 'Interrupted check-only verifies recovery without writes'
& $module {param($Game)$null=Restore-ZHSwitch (Get-ZHLocations $Game)} $game
Assert ((Hash (StatePath $game))-eq $oldManifestHash-and(Same $oldPayload (Snapshot (Join-Path $game $plugin)))) 'Recovery restores all historical three-role bytes'
$result=Apply $game 'player' 'white';$after=State $game;$newConfig=Get-Content -LiteralPath $configPath -Raw|ConvertFrom-Json
Assert ($result.RequiresMigration-and $after.RuntimeProtocol-eq 2-and $after.Characters.Count-eq 7-and $newConfig.SchemaVersion-eq 2-and $newConfig.Characters.Count-eq 7-and @($newConfig.Characters|Where-Object{$_.Id-notin @('player','tang-buyi','xiahou-lan')-and $_.Enabled}).Count-eq 0) 'Successful migration writes exact protocol2 and leaves every new role disabled'
Assert ($after.InstallationId-eq $old.InstallationId-and $after.BackupRelativePath-eq $old.BackupRelativePath-and @($backupBefore.Keys|Where-Object{(Hash (Join-Path $first $_))-ne $backupBefore[$_]}).Count-eq 0) 'Migration preserves first installation identity and every existing backup file'
$preserved=$true;foreach($relative in $oldPayload.Keys){if($relative-in @('ZhaoHuoNatural.dll','characters.json')){continue};if((Hash (Join-Path (Join-Path $game $plugin) $relative))-ne $oldPayload[$relative]){$preserved=$false}}
Assert $preserved 'All previously installed artwork, layouts and map bytes are unchanged'
foreach($role in @('tang-moling','long-xiang','yu-xiaomei','tang-zheng')){
    $selected=if($role-eq 'tang-zheng'){'female'}else{'refined'}
    $beforePayload=Snapshot (Join-Path $game $plugin);$beforeState=State $game
    $null=Apply $game $role $selected;$after=State $game;$allOther=$true
    foreach($relative in $beforePayload.Keys){if($relative-eq 'characters.json'-or $relative.StartsWith('Characters\'+$role+'\')){continue};if((Hash (Join-Path (Join-Path $game $plugin) $relative))-ne $beforePayload[$relative]){$allOther=$false}}
    Assert ($allOther-and @($after.Characters|Where-Object Id -eq $role)[0].SelectedVariantId-eq $selected) ('New role installs without changing other role files: '+$role)
    $rolePath=Join-Path $game ($plugin+'\Characters\'+$role);$cache=Snapshot $rolePath
    $null=Apply $game $role 'original';$configuration=Get-Content -LiteralPath $configPath -Raw|ConvertFrom-Json
    Assert (-not @($configuration.Characters|Where-Object Id -eq $role)[0].Enabled-and(Same $cache (Snapshot $rolePath))) ('Original option disables only its role and preserves owned cache: '+$role)
}
$otherRoles=@{};foreach($role in @('tang-moling','long-xiang','yu-xiaomei','tang-zheng','xiahou-lan')){$otherRoles[$role]=Snapshot (Join-Path $game ($plugin+'\Characters\'+$role))}
$null=Apply $game 'tang-buyi' 'female';$femaleState=State $game
Assert (@($femaleState.Characters|Where-Object Id -eq 'tang-buyi').Count-eq 1-and @($femaleState.Characters|Where-Object Id -eq 'tang-buyi')[0].SelectedVariantId-eq 'female') 'Brother female style replaces the same role without creating a duplicate identity'
$null=Apply $game 'tang-buyi' 'refined';$othersStable=$true;foreach($role in $otherRoles.Keys){if(-not(Same $otherRoles[$role] (Snapshot (Join-Path $game ($plugin+'\Characters\'+$role))))){$othersStable=$false}}
Assert $othersStable 'Switching brother female back to refined leaves every other NPC unchanged'
$snapshot=Snapshot $game;$noop=Apply $game 'tang-buyi' 'refined'
Assert ($noop.Status-eq 'NoOp'-and(Same $snapshot (Snapshot $game))) 'Repeated expanded selection is a byte-for-byte no-op'
$newFile=Join-Path $game ($plugin+'\Characters\long-xiang\Portraits\external.txt');Write-Text $newFile 'USER FILE'
Reject {Apply $game 'tang-buyi' 'female'} '*未登记文件*' 'Unknown files in a new role directory block all writes'
# Preserve the deliberately introduced file by moving only this exact fixture file
# outside the managed fixture path; it is never deleted.
Move-Item -LiteralPath $newFile -Destination (Join-Path $work 'preserved-external.txt')
$edited=Join-Path $game ($plugin+'\Characters\long-xiang\Portraits\normal.png');Write-Text $edited 'USER EDITED NPC ART'
Reject {Apply $game 'tang-buyi' 'female'} '*被修改或缺失*' 'Modified new-role art blocks overwrite'
Uninstall-PortraitManager -GamePath $game -Log $quiet
$kept=@(Get-ChildItem -LiteralPath $first -File -Recurse|Where-Object{$_.FullName-like '*\Preserved-*\*'-and $_.Name-eq 'normal.png'-and(Get-Content -LiteralPath $_.FullName -Raw)-eq 'USER EDITED NPC ART'})
Assert ($kept.Count-eq 1-and-not(Test-Path -LiteralPath (StatePath $game))-and(Get-Content -LiteralPath $legacyPlugin -Raw)-eq 'ORIGINAL LEGACY PLUGIN'-and(Get-Content -LiteralPath $otherPlugin -Raw)-eq 'UNCHANGED OTHER MOD') 'Uninstall preserves modified new-role artwork and restores the original unrelated installation'
$unchanged=$true;foreach($relative in $productionBefore.Keys){if((Hash (Join-Path $repo $relative))-ne $productionBefore[$relative]){$unchanged=$false}}
Assert $unchanged 'All 312 production PNGs remain byte-identical after the isolated suite'
Assert ((Get-PortraitCharacters -PackageRoot $repo).PackageReady-eq $production.PackageReady) 'Production readiness is not changed by fixture tests'
$codePaths=@('installer/CharacterCatalog.ps1','installer/CharacterState.ps1','installer/CharacterManager.ps1','installer/CharacterTransactions.ps1','installer/ZhaoHuoInstaller.psm1','installer/AppearanceManager.ps1','installer/VariantSupport.ps1','tests/Test-CharacterManager.ps1','tests/Test-CharacterExpansion.ps1')
$hashes=@(foreach($relative in $codePaths){$text=[IO.File]::ReadAllText((Join-Path $repo $relative)).TrimStart([char]0xFEFF).Replace("`r`n","`n").Replace("`r","`n");[pscustomobject]@{Path=$relative;Sha256=(& $module {param($Text)Get-ZHTextHash $Text} $text)}})
$summary=[ordered]@{Passed=$true;AssertionCount=$checks.Count;PowerShell=$PSVersionTable.PSVersion.ToString();DurationSeconds=[Math]::Round(([DateTime]::UtcNow-$start).TotalSeconds,2);ActualGameRun=$false;RealGameFilesModified=$false;FinalArtAcceptance=$false;TemporaryFixtureAllowlists=$temporaryAllowlists;Scope='Inert transaction fixtures: v2.0 protocol1 to v2.1 protocol2 migration, new character independence, failure/interruption recovery, no-op, modified-file protection and uninstall. No game assemblies are executed.';CodeHashAlgorithm='SHA256-UTF8-noBOM-LF-v1';CodeHashes=$hashes;Checks=$checks.ToArray()}
Save-Json $OutputPath $summary
Write-Host ('ALL '+$checks.Count+' EXPANSION ASSERTIONS PASSED')
