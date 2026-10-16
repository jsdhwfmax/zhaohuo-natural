#requires -Version 5.1
param([string]$ReportPath)
$ErrorActionPreference='Stop'
Set-StrictMode -Version 2.0
$repo=Split-Path -Parent $PSScriptRoot
if (-not $ReportPath) { $ReportPath=Join-Path $repo 'verification\appearance-manager-tests.json' }
$module=Import-Module (Join-Path $repo 'installer\ZhaoHuoInstaller.psm1') -Force -PassThru
$work=Join-Path $PSScriptRoot ('.work\manager-'+[Guid]::NewGuid().ToString('N'))
$package=Join-Path $work 'Manager Package'
$plugin='BepInEx\plugins\ZhaoHuoNatural'
$ids=@('natural','handsome','xianxia')
$names=@(& $module {$script:PortraitNames})
$checks=New-Object 'System.Collections.Generic.List[string]'
$quiet={param($Message,$Level)}
$script:counter=0
$start=[DateTime]::UtcNow
function Assert([bool]$Value,[string]$Name) { if(-not $Value){throw "FAIL: $Name"};$checks.Add($Name);Write-Host "PASS: $Name" }
function Reject([scriptblock]$Action,[string]$Name) { $hit=$false;try { & $Action | Out-Null } catch { $hit=$true };Assert $hit $Name }
function Hash([string]$Path) { (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash }
function Json([string]$Path,[object]$Value) { [IO.File]::WriteAllText($Path,($Value | ConvertTo-Json -Depth 16),(New-Object Text.UTF8Encoding($true))) }
function StatePath([string]$Game) { Join-Path $Game 'BepInEx\ZhaoHuoNatural-install\ActiveManifest.json' }
function State([string]$Game) { Get-Content -LiteralPath (StatePath $Game) -Raw -Encoding UTF8 | ConvertFrom-Json }
function Status([string]$Game) { Get-ZhaoHuoInstalledVariant -GamePath $Game -PackageRoot $package }
function PortraitRoot([string]$Id) { if($Id -eq 'natural'){Join-Path $package ($plugin+'\Portraits')}else{Join-Path $package ('Variants\'+$Id+'\Portraits')} }
function Same([string]$Game,[string]$Id) { foreach($name in $names){if((Hash (Join-Path $Game ($plugin+'\Portraits\'+$name+'.png'))) -ne (Hash (Join-Path (PortraitRoot $Id) ($name+'.png')))){return $false}};return $true }
function RestoreMetadata([object]$Manifest) { @($Manifest.OwnedFiles | Select-Object RelativePath,WasPresent,OriginalSha256,BackupRelativePath) | ConvertTo-Json -Depth 5 -Compress }
function NewGame([switch]$Existing) {
    $script:counter++
    $game=Join-Path $work ('game-'+$script:counter+'\steamapps\common\LegendOfMortal')
    New-Item -ItemType Directory -Path (Join-Path $game 'Mortal_Data\Managed') -Force | Out-Null
    $pe=New-Object byte[] 256;$pe[0]=0x4D;$pe[1]=0x5A;$pe[0x3C]=0x80;$pe[0x80]=0x50;$pe[0x81]=0x45;$pe[0x84]=0x64;$pe[0x85]=0x86
    foreach($file in @('Mortal.exe','UnityPlayer.dll')){[IO.File]::WriteAllBytes((Join-Path $game $file),$pe)}
    [IO.File]::WriteAllText((Join-Path ([IO.Directory]::GetParent($game).Parent.FullName) 'appmanifest_1859910.acf'),'"AppState" {"buildid" "90000001"}')
    $hashes=[ordered]@{}
    foreach($name in @('Assembly-CSharp.dll','Mortal.Core.dll','Mortal.Story.dll','Fungus.dll')){$file=Join-Path $game ('Mortal_Data\Managed\'+$name);[IO.File]::WriteAllText($file,'fixture-'+$name);$hashes[$name]=Hash $file}
    & $module {param($Hashes)$script:SupportedGameBuilds=@([pscustomobject]@{BuildId='90000001';Hashes=$Hashes})} $hashes
    if($Existing){
        $deps=Get-Content -LiteralPath (Join-Path $package 'Dependencies\BepInEx\runtime-manifest.json') -Raw | ConvertFrom-Json
        foreach($file in $deps.Files){$target=Join-Path $game $file.RelativePath;New-Item -ItemType Directory -Path (Split-Path -Parent $target) -Force | Out-Null;Copy-Item -LiteralPath (Join-Path $package ('Dependencies\BepInEx\files\'+$file.RelativePath)) -Destination $target}
        Copy-Item -LiteralPath (Join-Path $package 'Loader\winhttp.dll') -Destination (Join-Path $game 'winhttp.dll')
    }
    return $game
}
function EnableFailure([string]$TargetId,[bool]$BlockRecovery) {
    & $module {
        param($SourceRoot,$Block)
        $script:OriginalManagerCopy=${function:Copy-ZHVerified};$script:ManagerFailed=$false;$script:BlockManagerRecovery=$Block;$script:ManagerSourceRoot=$SourceRoot
        function script:Copy-ZHVerified([string]$Source,[string]$Destination,[string]$Sha256){
            if($script:BlockManagerRecovery -and $Source -like '*\Switches\*\Files\*'){throw 'RECOVERY_BLOCKED'}
            & $script:OriginalManagerCopy $Source $Destination $Sha256
            if(-not $script:ManagerFailed -and $Source.StartsWith($script:ManagerSourceRoot,[StringComparison]::OrdinalIgnoreCase) -and $Source.EndsWith('\normal.png')){$script:ManagerFailed=$true;throw 'INJECTED_MANAGER_FAILURE'}
        }
    } (PortraitRoot $TargetId) $BlockRecovery
}
function DisableFailure { & $module {Set-Item Function:script:Copy-ZHVerified -Value $script:OriginalManagerCopy} }
function NormalizedHash([string]$Path) {
    $value=[IO.File]::ReadAllText($Path,[Text.Encoding]::UTF8).TrimStart([char]0xFEFF).Replace("`r`n","`n").Replace("`r","`n")
    $sha=[Security.Cryptography.SHA256]::Create()
    try {([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($value)))).Replace('-','')} finally {$sha.Dispose()}
}
try {
    # First verify all actual release portraits and the shared plugin bytes.
    $realVariants=@(Get-ZhaoHuoVariants -PackageRoot $repo)
    Assert ($realVariants.Count -eq 3) 'Production catalog exposes exactly three variants'
    foreach($variant in $realVariants){
        $actions=@(& $module {param($Root,$Variant)Get-ZHVariantPayload $Root $Variant} $repo $variant)
        $fingerprint=& $module {param($Items)Get-ZHPayloadFingerprint $Items} $actions
        Assert ($actions.Count -eq 50 -and $fingerprint -eq $variant.PayloadFingerprint) ('Actual 47 portraits plus 3 shared files match canonical '+$variant.Id+' fingerprint')
    }
    New-Item -ItemType Directory -Path (Join-Path $package 'Dependencies\BepInEx') -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $repo 'Dependencies\BepInEx\runtime-manifest.json') -Destination (Join-Path $package 'Dependencies\BepInEx')
    Copy-Item -LiteralPath (Join-Path $repo 'Dependencies\BepInEx\files') -Destination (Join-Path $package 'Dependencies\BepInEx') -Recurse
    Copy-Item -LiteralPath (Join-Path $repo 'Loader') -Destination $package -Recurse
    foreach($id in $ids){New-Item -ItemType Directory -Path (PortraitRoot $id) -Force | Out-Null;foreach($name in $names){[IO.File]::WriteAllText((Join-Path (PortraitRoot $id) ($name+'.png')),($id+' fixture '+$name))}}
    foreach($name in @('ZhaoHuoNatural.dll','portrait-map.txt','portrait-layout.tsv')){[IO.File]::WriteAllText((Join-Path $package ($plugin+'\'+$name)),'shared inert fixture '+$name)}
    $catalog=Get-Content -LiteralPath (Join-Path $repo 'VariantCatalog.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    $fixturePins=@{}
    foreach($variant in $catalog.Variants){$items=@(& $module {param($Root,$Variant)Get-ZHVariantPayload $Root $Variant} $package $variant);$variant.PayloadFingerprint=& $module {param($Items)Get-ZHPayloadFingerprint $Items} $items;$fixturePins[$variant.Id]=$variant.PayloadFingerprint}
    # Fixture-only private overrides; no production bypass or game assembly runs.
    & $module {param($Pins)$script:KnownVariantFingerprints=$Pins} $fixturePins
    $catalogPath=Join-Path $package 'VariantCatalog.json';Json $catalogPath $catalog
    $catalogText=[IO.File]::ReadAllText($catalogPath)
    $clean=NewGame
    $beforeFiles=@(Get-ChildItem -LiteralPath $clean -Recurse -File).Count
    Assert ((Status $clean).Status -eq 'NotInstalled' -and @(Get-ChildItem -LiteralPath $clean -Recurse -File).Count -eq $beforeFiles) 'NotInstalled status is read-only'
    $default=Install-ZhaoHuo -GamePath $clean -PackageRoot $package -CheckOnly -Log $quiet
    Assert ($default.Variant.Id -eq 'natural' -and -not(Test-Path -LiteralPath (Join-Path $clean 'BepInEx'))) 'Omitted VariantId defaults to natural and CheckOnly writes nothing'
    Reject {Get-ZhaoHuoInstallPlan -GamePath $clean -PackageRoot $package -VariantId 'unknown'} 'Unknown selected variant is rejected'
    $mutexScript=Join-Path $work 'Hold-Mutex.ps1';$ready=Join-Path $work 'mutex-ready';$release=Join-Path $work 'mutex-release'
    $holderSource=@'
param($ModulePath,$GamePath,$Ready,$Release)
$ErrorActionPreference='Stop'
$m=Import-Module $ModulePath -Force -PassThru
$mutex=& $m {param($Game) Enter-ZHOperation $Game} $GamePath
try {
    [IO.File]::WriteAllText($Ready,'ready')
    $deadline=[DateTime]::UtcNow.AddSeconds(40)
    while(-not(Test-Path -LiteralPath $Release) -and [DateTime]::UtcNow -lt $deadline){Start-Sleep -Milliseconds 100}
} finally {$mutex.ReleaseMutex();$mutex.Dispose()}
'@
    [IO.File]::WriteAllText($mutexScript,$holderSource,(New-Object Text.UTF8Encoding($true)))
    $arguments=@('-NoProfile','-ExecutionPolicy','Bypass','-File',('"'+$mutexScript+'"'),('"'+(Join-Path $repo 'installer\ZhaoHuoInstaller.psm1')+'"'),('"'+$clean+'"'),('"'+$ready+'"'),('"'+$release+'"'))
    $child=Start-Process -FilePath (Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe') -ArgumentList $arguments -WindowStyle Hidden -PassThru
    try {
        $deadline=[DateTime]::UtcNow.AddSeconds(15)
        while(-not(Test-Path -LiteralPath $ready) -and -not $child.HasExited -and [DateTime]::UtcNow -lt $deadline){Start-Sleep -Milliseconds 100}
        Assert (Test-Path -LiteralPath $ready) 'Independent process acquires per-game mutex'
        Reject {Install-ZhaoHuo -GamePath $clean.ToUpperInvariant() -PackageRoot $package -CheckOnly -Log $quiet} 'Second process install/check is rejected for the same canonical path'
        Reject {Uninstall-ZhaoHuo -GamePath $clean -CheckOnly -Log $quiet} 'Second process uninstall/check is rejected while installation lock is held'
        Assert (-not(Test-Path -LiteralPath (Join-Path $clean 'BepInEx'))) 'Lock conflict creates no game files or transaction records'
    } finally {[IO.File]::WriteAllText($release,'release');if(-not $child.WaitForExit(15000)){throw 'Mutex holder did not terminate'};$child.Dispose()}
    $unlocked=Install-ZhaoHuo -GamePath $clean -PackageRoot $package -CheckOnly -Log $quiet
    Assert ($unlocked.Variant.Id -eq 'natural') 'Lock is released after independent holder exits'
    Reject {Install-ZhaoHuo -GamePath $clean -PackageRoot $package -VariantId unknown -CheckOnly -Log $quiet} 'Operation exception is surfaced while holding the lock'
    $unlocked=Install-ZhaoHuo -GamePath $clean -PackageRoot $package -CheckOnly -Log $quiet
    Assert ($unlocked.Variant.Id -eq 'natural') 'Operation exception releases mutex in finally'
    $reentrant=& $module {param($Game)$a=Enter-ZHOperation $Game;try{$b=Enter-ZHOperation $Game;try{$true}finally{$b.ReleaseMutex();$b.Dispose()}}finally{$a.ReleaseMutex();$a.Dispose()}} $clean
    Assert $reentrant 'Same-thread lock is reentrant for install failure rollback'

    foreach($from in $ids){foreach($to in $ids){if($from -eq $to){continue}
        $game=NewGame
        Install-ZhaoHuo -GamePath $game -PackageRoot $package -VariantId $from -Log $quiet | Out-Null
        $initial=State $game
        if($from -eq 'natural'){foreach($field in @('VariantId','VariantDisplayName','PayloadFingerprint')){$initial.PSObject.Properties.Remove($field)};Json (StatePath $game) $initial}
        $manifestHash=Hash (StatePath $game);$originalRestore=RestoreMetadata $initial
        Assert ((Status $game).VariantId -eq $from -and (Hash (StatePath $game)) -eq $manifestHash) ($from+' -> '+$to+': installed identity is inferred from actual files without modifying old schema3 records')
        $plan=Install-ZhaoHuo -GamePath $game -PackageRoot $package -VariantId $to -CheckOnly -Log $quiet
        Assert ($plan.SwitchRequired -and $plan.Actions.Count -eq 47 -and (Same $game $from) -and (Hash (StatePath $game)) -eq $manifestHash) ($from+' -> '+$to+': CheckOnly plans exactly 47 portraits and is read-only')
        Install-ZhaoHuo -GamePath $game -PackageRoot $package -VariantId $to -Log $quiet | Out-Null
        $after=State $game
        Assert ((Same $game $to) -and (Status $game).VariantId -eq $to -and $after.InstallationId -eq $initial.InstallationId -and $after.BackupRelativePath -eq $initial.BackupRelativePath -and (RestoreMetadata $after) -ceq $originalRestore) ($from+' -> '+$to+': exact portrait switch preserves first installation and original restore metadata')
        $afterHash=Hash (StatePath $game)
        $noop=Install-ZhaoHuo -GamePath $game -PackageRoot $package -VariantId $to -Log $quiet
        Assert ($noop.AlreadyInstalled -and -not $noop.SwitchRequired -and (Hash (StatePath $game)) -eq $afterHash) ($from+' -> '+$to+': selecting installed appearance is a byte-identical no-op')
        Uninstall-ZhaoHuo -GamePath $game -Log $quiet
        Assert (-not(Test-Path -LiteralPath (Join-Path $game $plugin)) -and -not(Test-Path -LiteralPath (Join-Path $game 'winhttp.dll'))) ($from+' -> '+$to+': uninstall restores the original clean state')
    }}
    $cycle=NewGame -Existing
    $core=Join-Path $cycle 'BepInEx\core\BepInEx.Core.dll';$coreHash=Hash $core
    $config=Join-Path $cycle 'doorstop_config.ini';Add-Content -LiteralPath $config -Value '# original user comment';$configHash=Hash $config
    $legacy=Join-Path $cycle 'BepInEx\plugins\Tianfei\MortalBeauty.dll';New-Item -ItemType Directory -Path (Split-Path -Parent $legacy) -Force | Out-Null;[IO.File]::WriteAllText($legacy,'original old mod')
    $other=Join-Path $cycle 'BepInEx\plugins\OtherMod.dll';[IO.File]::WriteAllText($other,'unrelated mod')
    Install-ZhaoHuo -GamePath $cycle -PackageRoot $package -VariantId xianxia -Log $quiet | Out-Null
    $first=State $cycle;$firstRestore=RestoreMetadata $first
    $backupFile=Join-Path $cycle ('BepInEx\ZhaoHuoNatural-install\'+$first.BackupRelativePath+'\MortalBeauty.dll');$backupHash=Hash $backupFile
    foreach($id in @('natural','handsome','xianxia','handsome','natural','xianxia','natural','handsome','xianxia')){
        Install-ZhaoHuo -GamePath $cycle -PackageRoot $package -VariantId $id -Log $quiet | Out-Null
        $current=State $cycle
        Assert ((Same $cycle $id) -and $current.InstallationId -eq $first.InstallationId -and (RestoreMetadata $current) -ceq $firstRestore -and (Hash $backupFile) -eq $backupHash) ('Multi-cycle step '+@($checks | Where-Object {$_ -like 'Multi-cycle*'}).Count+': '+$id+' preserves original backup')
    }
    Assert ((Hash $core) -eq $coreHash -and (Hash $config) -eq $configHash -and (Get-Content -LiteralPath $other -Raw) -eq 'unrelated mod') 'Nine switches leave pre-existing core, customized config and unrelated mod byte-identical'
    Uninstall-ZhaoHuo -GamePath $cycle -Log $quiet
    Assert ((Hash $core) -eq $coreHash -and (Hash $config) -eq $configHash -and (Get-Content -LiteralPath $legacy -Raw) -eq 'original old mod' -and (Test-Path -LiteralPath $other)) 'Uninstall after multiple cycles restores initial legacy plugin and preserves pre-existing environment'

    foreach($from in $ids){foreach($to in $ids){if($from -eq $to){continue}
        $game=NewGame;Install-ZhaoHuo -GamePath $game -PackageRoot $package -VariantId $from -Log $quiet | Out-Null;$before=Hash (StatePath $game)
        EnableFailure $to $false
        try{Reject {Install-ZhaoHuo -GamePath $game -PackageRoot $package -VariantId $to -Log $quiet} ($from+' -> '+$to+': injected partial-write failure is reported')}finally{DisableFailure}
        Assert ((Hash (StatePath $game)) -eq $before -and (Same $game $from) -and (Status $game).VariantId -eq $from) ($from+' -> '+$to+': rollback restores exact manifest and all original portraits')
        Uninstall-ZhaoHuo -GamePath $game -Log $quiet
    }}
    $game=NewGame;Install-ZhaoHuo -GamePath $game -PackageRoot $package -VariantId handsome -Log $quiet | Out-Null;$before=Hash (StatePath $game)
    EnableFailure 'natural' $true
    try{Reject {Install-ZhaoHuo -GamePath $game -PackageRoot $package -VariantId natural -Log $quiet} 'Interrupted rollback retains a pending recovery transaction'}finally{DisableFailure}
    $journal=Join-Path $game 'BepInEx\ZhaoHuoNatural-install\ActiveSwitch.json';$journalHash=Hash $journal
    Assert ((Status $game).Status -eq 'RecoveryRequired' -and (Hash $journal) -eq $journalHash) 'Status reports interrupted switch without recovering or writing files'
    $check=Install-ZhaoHuo -GamePath $game -PackageRoot $package -VariantId xianxia -CheckOnly -Log $quiet
    Assert ($check.RecoveryRequired -and (Hash $journal) -eq $journalHash) 'Recovery CheckOnly does not mutate the pending transaction'
    $edited=Join-Path $game ($plugin+'\Portraits\normal.png');[IO.File]::WriteAllText($edited,'user edit after interruption')
    & $module {param($Game)$null=Restore-ZHSwitch -Paths (Get-ZHLocations $Game)} $game
    $preserved=@(Get-ChildItem -LiteralPath (Join-Path $game 'BepInEx\ZhaoHuoNatural-install') -Recurse -File | Where-Object {$_.FullName -like '*PreservedDuringRecovery*normal.png'})
    Assert ((Same $game 'handsome') -and (Hash (StatePath $game)) -eq $before -and $preserved.Count -eq 1 -and (Get-Content -LiteralPath $preserved[0].FullName -Raw) -eq 'user edit after interruption') 'Recovery restores prior variant and preserves edits made after interruption'

    $originalState=State $game;$stateText=[IO.File]::ReadAllText((StatePath $game));$normal=Join-Path $game ($plugin+'\Portraits\normal.png');$normalBytes=[IO.File]::ReadAllBytes($normal)
    [IO.File]::WriteAllText($normal,'modified portrait')
    Assert ((Status $game).Status -eq 'Modified' -and $null -eq (Status $game).VariantId) 'Modified image never receives a trusted installed badge'
    Reject {Install-ZhaoHuo -GamePath $game -PackageRoot $package -VariantId natural -Log $quiet} 'Modified image blocks switching'
    $forged=State $game;($forged.OwnedFiles | Where-Object {$_.RelativePath -eq ($plugin+'\Portraits\normal.png')}).InstalledSha256=Hash $normal
    $forged.PSObject.Properties.Remove('PayloadFingerprint');Json (StatePath $game) $forged
    Assert ((Status $game).Status -eq 'Modified') 'Self-consistent but unknown edited payload fingerprint is not trusted'
    Reject {Install-ZhaoHuo -GamePath $game -PackageRoot $package -VariantId natural -Log $quiet} 'Unknown fingerprint blocks switching even when manifest hashes were edited'
    [IO.File]::WriteAllBytes($normal,$normalBytes);[IO.File]::WriteAllText((StatePath $game),$stateText,(New-Object Text.UTF8Encoding($true)))
    foreach($field in @('VariantId','PayloadFingerprint')){$bad=State $game;if($field -eq 'VariantId'){$bad.VariantId='natural'}else{$bad.PayloadFingerprint='0'*64};Json (StatePath $game) $bad;Assert ((Status $game).Status -eq 'Modified') ($field+' mismatch removes trusted status');Reject {Install-ZhaoHuo -GamePath $game -PackageRoot $package -VariantId handsome -Log $quiet} ($field+' mismatch blocks even same-variant no-op');[IO.File]::WriteAllText((StatePath $game),$stateText,(New-Object Text.UTF8Encoding($true)))}
    $extra=Join-Path $game ($plugin+'\user-note.txt');[IO.File]::WriteAllText($extra,'keep me')
    Assert ((Status $game).Status -eq 'Modified') 'Unknown extra plugin file blocks trusted installed status'
    Reject {Install-ZhaoHuo -GamePath $game -PackageRoot $package -VariantId handsome -Log $quiet} 'Unknown extra plugin file blocks same-variant apply'
    Assert ((Get-Content -LiteralPath $extra -Raw) -eq 'keep me') 'Rejected apply preserves unknown file';Remove-Item -LiteralPath $extra
    $diag=Join-Path $game ($plugin+'\Diagnostics\fixture.txt');New-Item -ItemType Directory -Path (Split-Path -Parent $diag) -Force | Out-Null;[IO.File]::WriteAllText($diag,'diagnostic')
    Assert ((Status $game).Status -eq 'Installed') 'Known diagnostics subtree does not change installed portrait identity'
    Uninstall-ZhaoHuo -GamePath $game -Log $quiet

    $unmanaged=NewGame;New-Item -ItemType Directory -Path (Join-Path $unmanaged $plugin) -Force | Out-Null
    foreach($file in @(Get-ChildItem -LiteralPath (Join-Path $package $plugin) -Force)){Copy-Item -LiteralPath $file.FullName -Destination (Join-Path $unmanaged $plugin) -Recurse}
    Assert ((Status $unmanaged).Status -eq 'Unmanaged') 'Untracked manual payload is not presented as managed installation'
    foreach($id in @('handsome','xianxia')){Reject {Install-ZhaoHuo -GamePath $unmanaged -PackageRoot $package -VariantId $id -Log $quiet} ('Untracked natural files cannot be silently taken over by '+$id)}
    Install-ZhaoHuo -GamePath $unmanaged -PackageRoot $package -VariantId natural -Log $quiet | Out-Null
    Assert ((Status $unmanaged).Status -eq 'Installed' -and -not (Status $unmanaged).CanSwitch) 'Exact natural manual copy retains backup-adoption behavior and cannot directly switch'
    Reject {Install-ZhaoHuo -GamePath $unmanaged -PackageRoot $package -VariantId xianxia -Log $quiet} 'Adopted manual files preserve original rollback boundary'
    Uninstall-ZhaoHuo -GamePath $unmanaged -Log $quiet
    Assert ((Same $unmanaged 'natural')) 'Uninstall of adopted payload restores every original manual file'

    foreach($case in @('duplicate','fingerprint','absolute','parent','double-slash','portrait-parent')){
        $bad=$catalogText | ConvertFrom-Json
        switch($case){'duplicate'{$bad.Variants[1].Id='natural'}'fingerprint'{$bad.Variants[1].PayloadFingerprint='0'*64}'absolute'{$bad.Variants[1].PreviewPath='C:/outside.png'}'parent'{$bad.Variants[1].PreviewPath='../outside.png'}'double-slash'{$bad.Variants[1].PreviewPath='Variants//handsome/Portraits/normal.png'}'portrait-parent'{$bad.Variants[1].PortraitPath='Variants/handsome/../Portraits'}}
        Json $catalogPath $bad;Reject {Get-ZhaoHuoVariants -PackageRoot $package} ('Catalog rejects '+$case+' before preview or payload access')
    }
    [IO.File]::WriteAllText($catalogPath,$catalogText,(New-Object Text.UTF8Encoding($true)))
    $portraitPath=PortraitRoot 'handsome';$moved=$portraitPath+'-original';$outside=Join-Path $work 'junction-target';New-Item -ItemType Directory -Path $outside | Out-Null
    Move-Item -LiteralPath $portraitPath -Destination $moved
    try{New-Item -ItemType Junction -Path $portraitPath -Target $outside | Out-Null;Reject {Get-ZhaoHuoVariants -PackageRoot $package} 'Catalog rejects portrait/preview directory junction before reading images'}finally{if(Test-Path -LiteralPath $portraitPath){Remove-Item -LiteralPath $portraitPath};Move-Item -LiteralPath $moved -Destination $portraitPath}
    $saved=[IO.File]::ReadAllBytes((Join-Path (PortraitRoot 'xianxia') 'normal.png'));[IO.File]::WriteAllText((Join-Path (PortraitRoot 'xianxia') 'normal.png'),'tampered package image')
    Reject {Install-ZhaoHuo -GamePath $clean -PackageRoot $package -VariantId xianxia -CheckOnly -Log $quiet} 'Tampered selected package image fails canonical fingerprint validation'
    [IO.File]::WriteAllBytes((Join-Path (PortraitRoot 'xianxia') 'normal.png'),$saved)

    $codePaths=@('installer/ZhaoHuoInstaller.psm1','installer/VariantSupport.ps1','installer/AppearanceManager.ps1','VariantCatalog.json','tests/Test-AppearanceManager.ps1')
    $report=[ordered]@{status='passed';suite='appearance-manager';assertionCount=$checks.Count;assertions=@($checks);powershell=$PSVersionTable.PSVersion.ToString();startedUtc=$start.ToString('o');finishedUtc=[DateTime]::UtcNow.ToString('o');scope='Actual production payload fingerprints plus isolated inert game/payload transaction fixtures. No real game writes or game assembly execution.';CodeHashAlgorithm='SHA256-UTF8-noBOM-LF-v1';CodeHashes=@($codePaths | ForEach-Object {[pscustomobject]@{Path=$_;Sha256=(NormalizedHash (Join-Path $repo $_))}})}
    Json $ReportPath $report
    Write-Host ('PASS TOTAL: '+$checks.Count)
} catch { Write-Error $_;exit 1 }
