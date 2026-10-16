#requires -Version 5.1
[CmdletBinding()]
param()
$ErrorActionPreference='Stop';Set-StrictMode -Version 2.0
$repo=Split-Path -Parent $PSScriptRoot
$module=Import-Module (Join-Path $repo 'installer\ZhaoHuoInstaller.psm1') -Force -PassThru
$work=Join-Path $PSScriptRoot ('.work\shared-update-'+[Guid]::NewGuid().ToString('N'))
$package=Join-Path $work 'Fixture package';$plugin='BepInEx\plugins\ZhaoHuoNatural'
$quiet={param($Message,$Level)};$checks=New-Object 'System.Collections.Generic.List[string]';$start=[DateTime]::UtcNow
# Reuse only the existing fixture helper definitions, never its main test body.
$helperPath=Join-Path $PSScriptRoot 'Test-CharacterManager.ps1';$tokens=$null;$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile($helperPath,[ref]$tokens,[ref]$errors)
if($errors.Count){throw 'Fixture helper source parse failed.'}
foreach($name in @('Write-Text','Save-Json','Hash','Assert','Reject','State','StatePath','Snapshot','Same','Apply','Check','New-Game','Inject-Failure','Clear-Failure')){
    $found=@($ast.FindAll({param($a) $a-is [Management.Automation.Language.FunctionDefinitionAst]-and $a.Name-eq $name},$true))
    if($found.Count-ne 1){throw ('Fixture helper missing/duplicate: '+$name)}
    . ([scriptblock]::Create($found[0].Extent.Text))
}
$pe=New-Object byte[] 256;$pe[0]=0x4D;$pe[1]=0x5A;$pe[0x3C]=0x80;$pe[0x80]=0x50;$pe[0x81]=0x45;$pe[0x84]=0x64;$pe[0x85]=0x86
New-Item -ItemType Directory -Path $package -Force|Out-Null
Copy-Item -LiteralPath (Join-Path $repo 'Dependencies') -Destination $package -Recurse
Copy-Item -LiteralPath (Join-Path $repo 'Loader') -Destination $package -Recurse
$catalog=Get-Content -LiteralPath (Join-Path $repo 'VariantCatalog.json') -Raw -Encoding UTF8|ConvertFrom-Json
$productionTargetDll=@($catalog.SharedFiles|Where-Object Name -eq 'ZhaoHuoNatural.dll')[0].Sha256
foreach($character in $catalog.Characters){
    $names=@(& $module {param($Id) $script:CharacterAssets[$Id]} $character.Id)
    $layout="expression`tcanvasWidth`tcanvasHeight`tx`ty`twidth`theight`n"+(@($names|ForEach-Object{$_+"`t10`t10`t0`t0`t10`t10"})-join "`n")
    Write-Text (Join-Path $package $character.LayoutSourcePath) $layout;$character.LayoutSha256=Hash (Join-Path $package $character.LayoutSourcePath)
    foreach($variant in $character.Variants){
        if($variant.Kind-eq 'original'){continue}
        $fallback=if($character.Id-eq 'tang-buyi'){@('hand')}elseif($character.Id-eq 'xiahou-lan'){@('white')}else{@()}
        $files=@(foreach($name in $names){if($name-in $fallback){continue};$file=Join-Path $package ($variant.SourcePath+'/'+$name+'.png');Write-Text $file ('INERT SHARED-UPDATE FIXTURE PNG '+$character.Id+'/'+$variant.Id+'/'+$name);[pscustomobject]@{Name=($name+'.png');Sha256=(Hash $file)}})
        $variant.Files=$files;$variant.OriginalFallback=@($fallback);$variant.AssetFingerprint=& $module {param($Id,$Files) Get-ZHCharacterFingerprint $Id $Files} $character.Id $files;$variant.Ready=$true
    }
}
foreach($shared in $catalog.SharedFiles){$path=Join-Path $package ($plugin+'\'+$shared.Name);if($shared.Name-ne 'portrait-layout.tsv'){Write-Text $path ('INERT INITIAL SHARED '+$shared.Name)};$shared.Sha256=Hash $path}
& $module {param($Shared) foreach($entry in $Shared){$script:CharacterSharedHashes[$entry.Name]=$entry.Sha256}} $catalog.SharedFiles
$catalog.PackageReady=$true;Save-Json (Join-Path $package 'VariantCatalog.json') $catalog
$game=New-Game 'schema4' -Existing
$oldPlugin=Join-Path $game 'BepInEx\plugins\Tianfei\MortalBeauty.dll';Write-Text $oldPlugin 'ORIGINAL LEGACY PLUGIN'
$otherPlugin=Join-Path $game 'BepInEx\plugins\Other\Other.dll';Write-Text $otherPlugin 'UNRELATED USER PLUGIN'
$initialCore=Snapshot (Join-Path $game 'BepInEx\core');$initialLoader=Hash (Join-Path $game 'winhttp.dll')
$null=Apply $game 'player' 'white';$null=Apply $game 'tang-buyi' 'refined';$null=Apply $game 'xiahou-lan' 'refined'
$before=State $game;$beforeStateHash=Hash (StatePath $game);$beforePayload=Snapshot (Join-Path $game $plugin)
$first=Join-Path (Join-Path $game 'BepInEx\ZhaoHuoNatural-install') $before.BackupRelativePath;$backupBefore=Snapshot $first
$configPath=Join-Path $game ($plugin+'\characters.json');$configHash=Hash $configPath
$dllRelative=$plugin+'\ZhaoHuoNatural.dll';$dllPath=Join-Path $game $dllRelative;$oldDllHash=Hash $dllPath
$newSource=Join-Path $package $dllRelative;Write-Text $newSource 'INERT PATCHED MANAGED PARSER SHARED DLL'
$newDllHash=Hash $newSource;@($catalog.SharedFiles|Where-Object Name -eq 'ZhaoHuoNatural.dll')[0].Sha256=$newDllHash
& $module {param($Hash) $script:CharacterSharedHashes['ZhaoHuoNatural.dll']=$Hash} $newDllHash
Save-Json (Join-Path $package 'VariantCatalog.json') $catalog
$plan=Get-PortraitApplyPlan -GamePath $game -PackageRoot $package -CharacterId player -VariantId white
Assert ($before.SchemaVersion-eq 4-and-not $plan.RequiresMigration-and-not $plan.NoOp-and @($plan.Actions).Count-eq 1-and $plan.Actions[0].RelativePath-eq $dllRelative-and $plan.Actions[0].ExpectedOldSha256-eq $oldDllHash) 'Schema4 same-selection update plans exactly one shared DLL write with the old owned hash'
$snap=Snapshot $game;$check=Check $game 'player' 'white'
Assert ($check.Status-eq 'Checked'-and $check.ChangedFiles-eq 1-and(Same $snap (Snapshot $game))) 'Shared DLL update check-only leaves every fixture file unchanged'
Inject-Failure $game '@commit'
try{Reject {Apply $game 'player' 'white'} '*INJECTED_CHARACTER_WRITE_FAILURE*' 'Failure is injected after the new DLL write, before final manifest commit'}finally{Clear-Failure}
Assert ((Hash (StatePath $game))-eq $beforeStateHash-and(Same $beforePayload (Snapshot (Join-Path $game $plugin)))) 'Failed shared DLL update restores the exact old schema4 manifest and complete mixed payload'
Inject-Failure $game '@commit' -Interrupt
try{Reject {Apply $game 'player' 'white'} '*INJECTED_CHARACTER_WRITE_FAILURE*' 'Interrupted shared DLL commit retains a recoverable transaction'}finally{Clear-Failure}
$pending=Get-PortraitManagerState -GamePath $game -PackageRoot $package
Assert ($pending.Status-eq 'RecoveryRequired'-and(Hash $dllPath)-eq $newDllHash) 'Interrupted update reports recovery required instead of a completed installation'
$snap=Snapshot $game;$check=Check $game 'player' 'white'
Assert ($check.Status-eq 'RecoveryRequired'-and(Same $snap (Snapshot $game))) 'Interrupted DLL update check validates recovery without writing'
& $module {param($Game) $null=Restore-ZHSwitch (Get-ZHLocations $Game)} $game
Assert ((Hash (StatePath $game))-eq $beforeStateHash-and(Same $beforePayload (Snapshot (Join-Path $game $plugin)))) 'Recovery restores the original schema4 DLL, selections and all files'
$result=Apply $game 'player' 'white';$after=State $game
Assert ($result.Status-eq 'Applied'-and $result.ChangedFiles-eq 1-and(Hash $dllPath)-eq $newDllHash-and $after.InstallationId-eq $before.InstallationId-and $after.BackupRelativePath-eq $before.BackupRelativePath) 'Successful schema4 DLL update retains first installation identity and backup root'
$nonDllUnchanged=$true
foreach($relative in $beforePayload.Keys){if($relative-eq 'ZhaoHuoNatural.dll'){continue};if((Hash (Join-Path (Join-Path $game $plugin) $relative))-ne $beforePayload[$relative]){$nonDllUnchanged=$false}}
Assert ($nonDllUnchanged-and(Hash $configPath)-eq $configHash-and($after.Characters|ConvertTo-Json -Depth 8)-ceq($before.Characters|ConvertTo-Json -Depth 8)) 'All three selections, character PNGs, layouts, mapping and config remain byte-identical'
$backupsUnchanged=$true;foreach($relative in $backupBefore.Keys){if((Hash (Join-Path $first $relative))-ne $backupBefore[$relative]){$backupsUnchanged=$false}}
Assert ($backupsUnchanged-and(Same $initialCore (Snapshot (Join-Path $game 'BepInEx\core')))-and(Hash (Join-Path $game 'winhttp.dll'))-eq $initialLoader-and(Get-Content -LiteralPath $otherPlugin -Raw)-eq 'UNRELATED USER PLUGIN') 'All pre-existing backup files, loader, core and other plugin remain unchanged'
$snap=Snapshot $game;$repeat=Apply $game 'player' 'white'
Assert ($repeat.Status-eq 'NoOp'-and(Same $snap (Snapshot $game))) 'Repeated patched DLL selection is a complete file no-op'
Uninstall-PortraitManager -GamePath $game -Log $quiet
Assert (-not(Test-Path -LiteralPath (Join-Path $game $plugin))-and(Get-Content -LiteralPath $oldPlugin -Raw)-eq 'ORIGINAL LEGACY PLUGIN'-and(Get-Content -LiteralPath $otherPlugin -Raw)-eq 'UNRELATED USER PLUGIN'-and(Hash (Join-Path $game 'winhttp.dll'))-eq $initialLoader) 'Uninstall after shared DLL update restores original legacy plugin and retains unrelated files'
function CodeHash([string]$Path){$text=[IO.File]::ReadAllText($Path).TrimStart([char]0xFEFF).Replace("`r`n","`n").Replace("`r","`n");& $module {param($Text) Get-ZHTextHash $Text} $text}
$code=@('installer/ZhaoHuoInstaller.psm1','installer/AppearanceManager.ps1','installer/VariantSupport.ps1','installer/CharacterCatalog.ps1','installer/CharacterState.ps1','installer/CharacterManager.ps1','installer/CharacterTransactions.ps1','tests/Test-CharacterManager.ps1','tests/Test-CharacterSharedUpdate.ps1')
$summary=[ordered]@{Passed=$true;AssertionCount=$checks.Count;PowerShell=$PSVersionTable.PSVersion.ToString();DurationSeconds=[Math]::Round(([DateTime]::UtcNow-$start).TotalSeconds,2);ActualGameRun=$false;RealGameFilesModified=$false;ProductionTargetDllSha256=$productionTargetDll;CodeHashAlgorithm='SHA256-UTF8-noBOM-LF-v1';CodeHashes=@($code|ForEach-Object{[pscustomobject]@{Path=$_;Sha256=(CodeHash (Join-Path $repo $_))}});Checks=$checks.ToArray();Scope='Synthetic inert schema4 game, DLL and PNG fixtures plus official offline BepInEx runtime; same-selection shared DLL update, commit-failure rollback, interrupted recovery, no-op and uninstall. Production installer code is unchanged; fixture-only accepted hashes are set only in this isolated PowerShell process. No game assembly or real game installation is executed.'}
Save-Json (Join-Path $PSScriptRoot 'character-shared-update-results.json') $summary
Write-Host ('ALL '+$checks.Count+' SHARED DLL UPDATE ASSERTIONS PASSED')
