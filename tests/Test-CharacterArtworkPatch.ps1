#requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$PreviousPackageRoot,
    [Parameter(Mandatory=$true)][string]$OutputPath
)
# Genuine released installer and its exact old female PNGs, inert game/runtime
# fixtures. No game process or real installation is accessed.
$ErrorActionPreference='Stop';Set-StrictMode -Version 2.0
$repo=Split-Path -Parent $PSScriptRoot
$previous=[IO.Path]::GetFullPath($PreviousPackageRoot)
$oldCatalog=Get-Content -LiteralPath (Join-Path $previous 'VariantCatalog.json') -Raw -Encoding UTF8|ConvertFrom-Json
if($oldCatalog.PackageVersion-ne '2.2.0'-or $oldCatalog.RuntimeProtocol-ne 2){throw 'The complete released v2.2.0 package is required.'}
$newCatalog=Get-Content -LiteralPath (Join-Path $repo 'VariantCatalog.json') -Raw -Encoding UTF8|ConvertFrom-Json
$productionDll=@($newCatalog.SharedFiles|Where-Object Name -eq 'ZhaoHuoNatural.dll')[0].Sha256
$oldFemale=@(@($oldCatalog.Characters|Where-Object Id -eq 'tang-buyi')[0].Variants|Where-Object Id -eq 'female')[0]
$knownOld='3DE6E1944779A6DFADEA26A8631CECFD09FE29D750F97A4AEFF39FF82BF003A8'
if($oldFemale.AssetFingerprint-ne $knownOld-or @($oldFemale.Files).Count-ne 15){throw 'The old public female fingerprint differs.'}
$work=Join-Path $PSScriptRoot ('.work\artwork-patch-'+[Guid]::NewGuid().ToString('N'))
$package=Join-Path $work 'Fixture package';$plugin='BepInEx\plugins\ZhaoHuoNatural'
$quiet={param($Message,$Level)};$checks=New-Object 'System.Collections.Generic.List[string]';$start=[DateTime]::UtcNow
$helper=Join-Path $PSScriptRoot 'Test-CharacterManager.ps1';$tokens=$null;$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile($helper,[ref]$tokens,[ref]$errors)
if($errors.Count){throw 'Fixture helper parse failed.'}
foreach($name in @('Write-Text','Save-Json','Hash','Assert','Reject','State','StatePath','Snapshot','Same','Apply','Check','New-Game','Inject-Failure','Clear-Failure')){
    $found=@($ast.FindAll({param($a)$a-is [Management.Automation.Language.FunctionDefinitionAst]-and $a.Name-eq $name},$true))
    if($found.Count-ne 1){throw ('Missing fixture helper: '+$name)}
    . ([scriptblock]::Create($found[0].Extent.Text))
}
function CodeHash([string]$Path){$text=[IO.File]::ReadAllText($Path).TrimStart([char]0xFEFF).Replace("`r`n","`n").Replace("`r","`n");$sha=[Security.Cryptography.SHA256]::Create();try{([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($text)))).Replace('-','')}finally{$sha.Dispose()}}
function Choices([object]$Manifest){(@($Manifest.Characters|ForEach-Object{[pscustomobject]@{Id=$_.Id;SelectedVariantId=$_.SelectedVariantId}})|ConvertTo-Json -Compress)}
New-Item -ItemType Directory -Path $package -Force|Out-Null
Copy-Item -LiteralPath (Join-Path $repo 'Dependencies') -Destination $package -Recurse
Copy-Item -LiteralPath (Join-Path $repo 'Loader') -Destination $package -Recurse
$module=Import-Module (Join-Path $previous 'installer\ZhaoHuoInstaller.psm1') -Force -PassThru
$oldCode=@(Get-ChildItem -LiteralPath (Join-Path $previous 'installer') -File|Where-Object{$_.Extension-in @('.ps1','.psm1')}|ForEach-Object{[pscustomobject]@{Path=('installer/'+$_.Name);Sha256=(CodeHash $_.FullName)}})
foreach($character in $newCatalog.Characters){
    $names=@(& $module {param($Id)$script:CharacterAssets[$Id]} $character.Id)
    $layout="expression`tcanvasWidth`tcanvasHeight`tx`ty`twidth`theight`n"+(@($names|ForEach-Object{$_+"`t10`t10`t0`t0`t10`t10"})-join "`n")
    Write-Text (Join-Path $package $character.LayoutSourcePath) $layout;$character.LayoutSha256=Hash (Join-Path $package $character.LayoutSourcePath)
    foreach($variant in $character.Variants){
        if($variant.Kind-eq 'original'){continue}
        $files=@(foreach($name in $names){
            if($name-in @($variant.OriginalFallback)){continue};$p=Join-Path $package ($variant.SourcePath+'/'+$name+'.png')
            if($character.Id-eq 'tang-buyi'-and $variant.Id-eq 'female'){
                $source=Join-Path $previous ($oldFemale.SourcePath+'/'+$name+'.png');$entry=@($oldFemale.Files|Where-Object Name -eq ($name+'.png'))[0]
                if((Hash $source)-ne $entry.Sha256){throw 'Old public artwork bytes differ.'};New-Item -ItemType Directory -Path (Split-Path -Parent $p) -Force|Out-Null;Copy-Item -LiteralPath $source -Destination $p
            }else{Write-Text $p ('INERT ARTWORK '+$character.Id+'/'+$variant.Id+'/'+$name)}
            [pscustomobject]@{Name=($name+'.png');Sha256=(Hash $p)}
        })
        $variant.Files=$files;$variant.AssetFingerprint=& $module {param($Id,$Files)Get-ZHCharacterFingerprint $Id $Files} $character.Id $files;$variant.Ready=$true
    }
}
foreach($entry in $newCatalog.SharedFiles){$p=Join-Path $package ($plugin+'\'+$entry.Name);if($entry.Name-ne 'portrait-layout.tsv'){Write-Text $p ('INERT SHARED '+$entry.Name)};$entry.Sha256=Hash $p}
$newCatalog.PackageReady=$true;$catalog=$newCatalog|ConvertTo-Json -Depth 20|ConvertFrom-Json;$catalog.PackageVersion='2.2.0'
Save-Json (Join-Path $package 'VariantCatalog.json') $catalog
& $module {param($Shared)foreach($e in $Shared){$script:CharacterSharedHashes[$e.Name]=$e.Sha256}} $catalog.SharedFiles
$pe=New-Object byte[] 256;$pe[0]=0x4D;$pe[1]=0x5A;$pe[0x3C]=0x80;$pe[0x80]=0x50;$pe[0x81]=0x45;$pe[0x84]=0x64;$pe[0x85]=0x86
$game=New-Game 'patch' -Existing
$legacy=Join-Path $game 'BepInEx\plugins\Tianfei\MortalBeauty.dll';Write-Text $legacy 'ORIGINAL LEGACY PLUGIN'
$other=Join-Path $game 'BepInEx\plugins\Other\Other.dll';Write-Text $other 'UNRELATED USER PLUGIN'
$save=Join-Path $game 'UserData\save.json';Write-Text $save 'INERT SAVE FIXTURE'
$choices=[ordered]@{player='hardman';'tang-buyi'='female';'xiahou-lan'='refined';'tang-moling'='refined';'long-xiang'='refined';'yu-xiaomei'='refined';'tang-zheng'='female'}
foreach($role in $choices.Keys){$null=Apply $game $role $choices[$role]}
$before=State $game;$manifestBytes=[IO.File]::ReadAllBytes((StatePath $game));$payloadBefore=Snapshot (Join-Path $game $plugin)
$first=Join-Path (Join-Path $game 'BepInEx\ZhaoHuoNatural-install') $before.BackupRelativePath;$backups=Snapshot $first
Assert ($before.SchemaVersion-eq 4-and $before.RuntimeProtocol-eq 2-and $before.Characters.Count-eq 7-and $before.Characters[1].InstalledPayload.AssetFingerprint-eq $knownOld) 'Released v2.2.0 installer creates seven selections with the exact public old female fingerprint'
Remove-Module $module;$module=Import-Module (Join-Path $repo 'installer\ZhaoHuoInstaller.psm1') -Force -PassThru
$hashes=[ordered]@{};foreach($name in @('Assembly-CSharp.dll','Mortal.Core.dll','Mortal.Story.dll','Fungus.dll')){$hashes[$name]=Hash (Join-Path $game ('Mortal_Data\Managed\'+$name))}
& $module {param($Shared,$Hashes)foreach($e in $Shared){$script:CharacterSharedHashes[$e.Name]=$e.Sha256};$script:SupportedGameBuilds=@([pscustomobject]@{BuildId='90000001';Hashes=$Hashes})} $newCatalog.SharedFiles $hashes
$female=@(@($newCatalog.Characters|Where-Object Id -eq 'tang-buyi')[0].Variants|Where-Object Id -eq 'female')[0]
foreach($entry in $female.Files){$p=Join-Path $package ($female.SourcePath+'/'+$entry.Name);Write-Text $p ('INERT REPAIRED ARTWORK '+$entry.Name);$entry.Sha256=Hash $p}
$female.AssetFingerprint=& $module {param($Files)Get-ZHCharacterFingerprint 'tang-buyi' $Files} $female.Files
$catalog=$newCatalog;Save-Json (Join-Path $package 'VariantCatalog.json') $catalog
Assert (& $module {param($Old,$Variant)Test-ZHCharacterPayloadFingerprint 'tang-buyi' $Variant $Old} $knownOld $female) 'Production historical allowlist accepts the exact released female revision without fixture overrides'
$wrong=$female|ConvertTo-Json -Depth 10|ConvertFrom-Json;$wrong.Id='refined'
Assert (-not(& $module {param($Old,$Variant)Test-ZHCharacterPayloadFingerprint 'tang-buyi' $Variant $Old} $knownOld $wrong)) 'Historical permission cannot be reused under another appearance ID'
$snapshot=Snapshot $game;$result=Check $game 'tang-buyi' 'female'
Assert ($result.ChangedFiles-eq 15-and(Same $snapshot (Snapshot $game))) 'Check-only recognizes the old installation and plans fifteen PNG writes without changing files'
$plan=Get-PortraitApplyPlan -GamePath $game -PackageRoot $package -CharacterId 'tang-buyi' -VariantId 'female'
Assert ($plan.Actions.Count-eq 15-and @($plan.Actions|Where-Object{$_.CharacterId-ne 'tang-buyi'-or $_.Category-ne 'CharacterPortrait'-or $_.RelativePath-notlike '*\Portraits\*.png'}).Count-eq 0) 'Same-appearance patch targets only the fifteen female portraits'
$result=Apply $game 'player' 'hardman'
Assert ($result.Status-eq 'NoOp'-and(Same $snapshot (Snapshot $game))) 'Applying another unchanged role preserves the recognized old female revision'
$extra=Join-Path $game ($plugin+'\Characters\tang-buyi\Portraits\unknown.png');Write-Text $extra 'UNREGISTERED FIXTURE'
Reject {Check $game 'tang-buyi' 'female'} '*未登记*' 'Unknown extra files still block the update';Remove-Item -LiteralPath $extra
$edited=Join-Path $game ($plugin+'\Characters\tang-buyi\Portraits\normal.png');Write-Text $edited 'EXTERNAL EDIT'
Reject {Apply $game 'tang-buyi' 'female'} '*修改*' 'A changed live PNG is rejected before overwriting it'
$tampered=State $game;@($tampered.OwnedFiles|Where-Object RelativePath -eq ($plugin+'\Characters\tang-buyi\Portraits\normal.png'))[0].InstalledSha256=Hash $edited
$items=@($tampered.OwnedFiles|Where-Object{$_.CharacterId-eq 'tang-buyi'-and $_.RelativePath-like '*\Portraits\*.png'}|ForEach-Object{[pscustomobject]@{Name=[IO.Path]::GetFileName($_.RelativePath);Sha256=$_.InstalledSha256}})
$tampered.Characters[1].InstalledPayload.AssetFingerprint=& $module {param($Files)Get-ZHCharacterFingerprint 'tang-buyi' $Files} $items
Save-Json (StatePath $game) $tampered
Reject {Check $game 'tang-buyi' 'female'} '*完整指纹*' 'Self-consistent but unknown historical PNG and manifest hashes are not adopted'
[IO.File]::WriteAllBytes((StatePath $game),$manifestBytes);Copy-Item -LiteralPath (Join-Path $previous ($oldFemale.SourcePath+'/normal.png')) -Destination $edited
Inject-Failure $game '@commit'
try{Reject {Apply $game 'tang-buyi' 'female'} '*INJECTED_CHARACTER_WRITE_FAILURE*' 'Failure is injected after all repaired PNG writes'}finally{Clear-Failure}
Assert ((Same $payloadBefore (Snapshot (Join-Path $game $plugin)))-and(Hash (StatePath $game))-eq ([BitConverter]::ToString(([Security.Cryptography.SHA256]::Create()).ComputeHash($manifestBytes))).Replace('-','')) 'Failed commit restores the exact old portraits and manifest'
Inject-Failure $game '@commit' -Interrupt
try{Reject {Apply $game 'tang-buyi' 'female'} '*INJECTED_CHARACTER_WRITE_FAILURE*' 'A process interruption remains recoverable'}finally{Clear-Failure}
$snapshot=Snapshot $game;$result=Check $game 'tang-buyi' 'female'
Assert ($result.Status-eq 'RecoveryRequired'-and(Same $snapshot (Snapshot $game))) 'Interrupted update check is read-only and does not claim success'
& $module {param($Game)$null=Restore-ZHSwitch (Get-ZHLocations $Game)} $game
Assert ((Same $payloadBefore (Snapshot (Join-Path $game $plugin)))-and(Choices (State $game))-ceq(Choices $before)) 'Interrupted update recovery restores old artwork and every selection'
$result=Apply $game 'tang-buyi' 'female';$after=State $game
Assert ($result.ChangedFiles-eq 15-and $after.InstallationId-eq $before.InstallationId-and $after.BackupRelativePath-eq $before.BackupRelativePath-and(Choices $after)-ceq(Choices $before)) 'Successful artwork patch preserves all selections and the first installation identity'
$preserved=$true;foreach($key in $backups.Keys){if((Hash (Join-Path $first $key))-ne $backups[$key]){$preserved=$false}}
Assert $preserved 'Every pre-existing original backup and switch snapshot remains byte-identical'
$others=$true;foreach($key in $payloadBefore.Keys){if($key-like 'Characters\tang-buyi\Portraits\*.png'){continue};if((Hash (Join-Path (Join-Path $game $plugin) $key))-ne $payloadBefore[$key]){$others=$false}}
Assert $others 'All other character portraits, shared components, layout and enabled-role configuration remain unchanged'
Assert ($after.Characters[1].InstalledPayload.AssetFingerprint-eq $female.AssetFingerprint) 'Installed metadata records the repaired complete female fingerprint'
$snapshot=Snapshot $game;$result=Apply $game 'tang-buyi' 'female'
Assert ($result.Status-eq 'NoOp'-and(Same $snapshot (Snapshot $game))) 'Repeated application of the repaired appearance is a complete no-op'
$null=Apply $game 'tang-buyi' 'original';$null=Apply $game 'tang-buyi' 'female'
Assert ((Choices (State $game))-ceq(Choices $before)) 'Original mode and re-enabling the repaired appearance preserve all other role choices'
Assert ((Get-Content $other -Raw)-eq 'UNRELATED USER PLUGIN'-and(Get-Content $save -Raw)-eq 'INERT SAVE FIXTURE') 'Other mods and the inert save remain unchanged'
Uninstall-PortraitManager -GamePath $game -Log $quiet
Assert (-not(Test-Path -LiteralPath (Join-Path $game $plugin))-and(Get-Content $legacy -Raw)-eq 'ORIGINAL LEGACY PLUGIN'-and(Get-Content $other -Raw)-eq 'UNRELATED USER PLUGIN'-and(Get-Content $save -Raw)-eq 'INERT SAVE FIXTURE') 'Uninstall after the patch restores the first legacy plugin and preserves unrelated files'
$code=@('installer/ZhaoHuoInstaller.psm1','installer/AppearanceManager.ps1','installer/VariantSupport.ps1','installer/CharacterCatalog.ps1','installer/CharacterState.ps1','installer/CharacterManager.ps1','installer/CharacterTransactions.ps1','tests/Test-CharacterManager.ps1','tests/Test-CharacterArtworkPatch.ps1')
$report=[ordered]@{Passed=$true;FromVersion='2.2.0';ToVersion=$newCatalog.PackageVersion;RuntimeVersion='2.1.0';RuntimeProtocol=2;ExecutionMode='IsolatedPreviousReleaseInstallation';ActualGameRun=$false;RealGameFilesModified=$false;ProductionPluginSha256=$productionDll;HistoricalFemaleFingerprint=$knownOld;PatchedPortraitCount=15;AssertionCount=$checks.Count;Checks=$checks.ToArray();InitialInstallationPreserved=$true;OriginalBackupsPreserved=$true;OtherPluginsPreserved=$true;AllExistingSelectionsPreserved=$true;PowerShell=$PSVersionTable.PSVersion.ToString();DurationSeconds=[Math]::Round(([DateTime]::UtcNow-$start).TotalSeconds,2);PreviousInstallerCodeHashes=$oldCode;CodeHashAlgorithm='SHA256-UTF8-noBOM-LF-v1';CodeHashes=@($code|ForEach-Object{[pscustomobject]@{Path=$_;Sha256=(CodeHash (Join-Path $repo $_))}});Scope='Genuine v2.2.0 installer and exact released female PNGs create an isolated seven-role installation. Fifteen inert replacement portraits exercise same-appearance updates, rejection, rollback, interruption, no-op and uninstall. No game execution occurs; final repaired artwork and runtime acceptance are separate.'}
Save-Json ([IO.Path]::GetFullPath($OutputPath)) $report
Write-Host ('PASS: '+$checks.Count+' artwork patch assertions')
