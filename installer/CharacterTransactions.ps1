#requires -Version 5.1
# A journal is committed before the first game-file mutation. Its first-install
# backups are immutable; transaction snapshots are a separate recovery layer.
function Assert-ZHTransactionTarget([string]$Relative) {
    if($Relative-eq $script:LegacyRelative -or $Relative-eq ($script:LegacyRelative+'.disabled-by-zhaohuo-natural')){return}
    Assert-ZHManagedTarget $Relative
}
function Read-ZHCharacterTransaction([object]$Paths) {
    $path=Get-ZHSwitchPath $Paths;Assert-ZHNoLink $path
    $journal=Get-Content -LiteralPath $path -Raw -Encoding UTF8|ConvertFrom-Json
    if($journal.SchemaVersion-ne 2-or $journal.PackageId-ne 'ZhaoHuoNatural'-or $journal.GamePath-ne $Paths.Game -or
        $journal.InstallationId-notmatch '^\d{8}-\d{6}-[0-9a-f]{8}$'-or $journal.TransactionId-notmatch '^\d{8}-\d{6}-[0-9a-f]{8}$'-or
        $journal.BackupRelativePath-ne ('Backups\'+$journal.InstallationId+'\Transactions\'+$journal.TransactionId)-or $journal.BeforeExists-isnot [bool]){throw '多角色恢复记录无效，请保留备份，勿手工删除记录。'}
    $backup=Get-ZHChild $Paths.State $journal.BackupRelativePath;Assert-ZHNoLink $backup
    $afterPath=Get-ZHChild $backup 'ManifestAfter.json';Assert-ZHNoLink $afterPath
    if($journal.AfterManifestSha256-notmatch '^[0-9A-Fa-f]{64}$'-or-not(Test-Path -LiteralPath $afterPath -PathType Leaf)-or(Get-ZHHash $afterPath)-ne $journal.AfterManifestSha256){throw '事务完成记录备份损坏。'}
    $after=Get-Content -LiteralPath $afterPath -Raw -Encoding UTF8|ConvertFrom-Json
    if($after.SchemaVersion-ne 4-or $after.PackageId-ne 'ZhaoHuoNatural'-or $after.GamePath-ne $Paths.Game-or $after.InstallationId-ne $journal.InstallationId-or $after.BackupRelativePath-ne ('Backups\'+$journal.InstallationId)-or $after.Status-ne 'installed'){throw '事务记录不属于当前安装。'}
    $beforePath=Get-ZHChild $backup 'ManifestBefore.json';$before=$null
    if($journal.BeforeExists){
        Assert-ZHNoLink $beforePath
        if($journal.BeforeManifestSha256-notmatch '^[0-9A-Fa-f]{64}$'-or-not(Test-Path -LiteralPath $beforePath -PathType Leaf)-or(Get-ZHHash $beforePath)-ne $journal.BeforeManifestSha256){throw '事务开始前记录备份损坏。'}
        $before=Get-Content -LiteralPath $beforePath -Raw -Encoding UTF8|ConvertFrom-Json
        if($before.SchemaVersion-notin @(3,4)-or $before.Status-ne 'installed'-or $before.PackageId-ne 'ZhaoHuoNatural'-or $before.GamePath-ne $Paths.Game-or $before.InstallationId-ne $journal.InstallationId-or $before.BackupRelativePath-ne $after.BackupRelativePath){throw '事务来源安装记录无效。'}
    }
    $active=Read-ZHState $Paths
    if($active -and $active.InstallationId-ne $journal.InstallationId){throw '当前记录属于另一次安装，不能恢复此事务。'}
    if(-not $active -and $journal.BeforeExists){throw '原有活动安装记录丢失，未自动恢复。'}
    foreach($record in @($after.OwnedFiles)){
        Assert-ZHManagedTarget $record.RelativePath
        Assert-ZHRecord $record $Paths (Get-ZHChild $Paths.State $after.BackupRelativePath)
    }
    foreach($relative in @($after.CreatedDirectories)){
        if($relative-notin @('BepInEx','BepInEx\core','BepInEx\plugins',$script:PluginRelative)-and-not $relative.StartsWith($script:PluginRelative+'\',[StringComparison]::OrdinalIgnoreCase)){throw '事务目录清单无效。'}
        Assert-ZHNoLink (Get-ZHChild $Paths.Game $relative)
    }
    $seen=@{}
    if(@($journal.Files).Count-gt 512){throw '恢复记录文件数超出允许范围。'}
    foreach($file in @($journal.Files)){
        Assert-ZHTransactionTarget $file.RelativePath
        if($seen.ContainsKey($file.RelativePath)-or $file.Stage-notin @('pending','applying','applied')-or $file.OldPresent-isnot [bool]-or $file.NewPresent-isnot [bool]){throw '恢复记录包含重复目标或无效事务状态。'};$seen[$file.RelativePath]=$true
        $target=Get-ZHChild $Paths.Game $file.RelativePath;Assert-ZHNoLink $target
        if(Test-Path -LiteralPath $target -PathType Container){throw '恢复目标被同名目录占用。'}
        if($file.NewPresent-and $file.NewSha256-notmatch '^[0-9A-Fa-f]{64}$'){throw '事务新文件哈希无效。'}
        if($file.RelativePath-like ($script:PluginRelative+'\*')-or $file.RelativePath-notlike ($script:LegacyRelative+'*')){
            $owned=@($after.OwnedFiles|Where-Object RelativePath -eq $file.RelativePath)
            if($owned.Count-ne 1-or $owned[0].InstalledPresent-ne $file.NewPresent-or ($file.NewPresent-and $owned[0].InstalledSha256-ne $file.NewSha256)){throw '事务文件与完成清单不一致。'}
        }elseif(-not $after.Legacy.DisabledByThisInstall-or $after.Legacy.Sha256-ne $(if($file.OldPresent){$file.OldSha256}else{$file.NewSha256})){throw '旧插件事务不匹配。'}
        if($file.OldPresent){
            $snapshot=Get-ZHChild $backup ('Files\'+$file.RelativePath);Assert-ZHNoLink $snapshot
            if($file.OldSha256-notmatch '^[0-9A-Fa-f]{64}$'-or-not(Test-Path -LiteralPath $snapshot -PathType Leaf)-or(Get-ZHHash $snapshot)-ne $file.OldSha256){throw ('事务原文件快照损坏：'+$file.RelativePath)}
        }
        if($before){
            $prior=@($before.OwnedFiles|Where-Object RelativePath -eq $file.RelativePath)
            if($prior.Count-gt 1){throw '事务来源文件记录重复。'}
            if($prior.Count){
                $wasPresent=if($prior[0].PSObject.Properties['InstalledPresent']){$prior[0].InstalledPresent}else{$true}
                if($file.OldPresent-ne $wasPresent-or($wasPresent-and $prior[0].InstalledSha256-ne $file.OldSha256)){throw '事务快照与来源受管清单不一致。'}
            }elseif($file.OldPresent){throw '事务试图接管来源清单以外的原有文件。'}
        }
    }
    [pscustomobject]@{Journal=$journal;JournalPath=$path;Backup=$backup;BeforePath=$beforePath;Before=$before;After=$after}
}
function Restore-ZHCharacterTransaction([object]$Paths,[switch]$CheckOnly,[scriptblock]$Log) {
    Assert-ZHStopped $Paths.Game
    $pending=Read-ZHCharacterTransaction $Paths
    if($CheckOnly){Write-ZHLog $Log '未完成的多角色事务可恢复；仅检查未修改文件。';return $true}
    foreach($file in @($pending.Journal.Files)){
        $target=Get-ZHChild $Paths.Game $file.RelativePath
        if(Test-Path -LiteralPath $target -PathType Leaf){
            $hash=Get-ZHHash $target
            if(($file.OldPresent-and $hash-eq $file.OldSha256)-or($file.Stage-ne 'pending'-and $file.NewPresent-and $hash-eq $file.NewSha256)){}else{
                $keep=Get-ZHChild $pending.Backup ('PreservedDuringRecovery\'+$file.RelativePath)
                if(Test-Path -LiteralPath $keep){$keep+='.'+[Guid]::NewGuid().ToString('N')}
                Copy-ZHVerified $target $keep $hash;Write-ZHLog $Log ('已保留中断后改动：'+$file.RelativePath) 'Warning'
            }
        }
        if($file.OldPresent){Copy-ZHVerified (Get-ZHChild $pending.Backup ('Files\'+$file.RelativePath)) $target $file.OldSha256}
        elseif(Test-Path -LiteralPath $target -PathType Leaf){Remove-Item -LiteralPath $target -Force}
    }
    if($pending.Journal.BeforeExists){
        Copy-ZHVerified $pending.BeforePath ($Paths.Manifest+'.restore.tmp') $pending.Journal.BeforeManifestSha256
        Move-Item -LiteralPath ($Paths.Manifest+'.restore.tmp') -Destination $Paths.Manifest -Force
    }elseif(Test-Path -LiteralPath $Paths.Manifest){Remove-Item -LiteralPath $Paths.Manifest -Force}
    # Only empty directories introduced by this transaction can be removed.
    $beforeDirs=@();if($pending.Before){$beforeDirs=@($pending.Before.CreatedDirectories)}
    foreach($relative in @($pending.After.CreatedDirectories|Sort-Object Length -Descending)){
        if($relative-in $beforeDirs){continue}
        if($relative-notin @('BepInEx','BepInEx\core','BepInEx\plugins',$script:PluginRelative)-and-not $relative.StartsWith($script:PluginRelative+'\',[StringComparison]::OrdinalIgnoreCase)){throw '事务目录清单无效。'}
        $directory=Get-ZHChild $Paths.Game $relative;Assert-ZHNoLink $directory
        if((Test-Path -LiteralPath $directory -PathType Container)-and @(Get-ChildItem -LiteralPath $directory -Force).Count-eq 0){Remove-Item -LiteralPath $directory -Force}
    }
    Move-Item -LiteralPath $pending.JournalPath -Destination (Get-ZHChild $pending.Backup 'RolledBackTransaction.json') -Force
    Write-ZHLog $Log '已恢复本次事务之前的角色选择与文件，首次卸载备份保留。'
    return $true
}
function Invoke-ZHCharacterTransaction([object]$Plan,[scriptblock]$Log) {
    $paths=$Plan.Paths;Assert-ZHStopped $paths.Game
    if($Plan.Manifest){
        if((Get-ZHHash $paths.Manifest)-ne $Plan.ManifestSha256){throw '检查后安装记录改变，已停止。'}
        $null=Assert-ZHInstalledFiles $paths $Plan.Manifest
    }elseif((Test-Path -LiteralPath $paths.Manifest)-or(Test-Path -LiteralPath $paths.Plugin)){throw '检查后出现另一份安装记录或未登记插件目录，已停止。'}
    $after=$Plan.After;$first=Get-ZHChild $paths.State $after.BackupRelativePath
    $txn=(Get-Date -Format 'yyyyMMdd-HHmmss')+'-'+[Guid]::NewGuid().ToString('N').Substring(0,8)
    if($Plan.RequiresMigration){Set-ZHProperty $after 'Migration' ([pscustomobject]@{FromSchemaVersion=$Plan.Manifest.SchemaVersion;BeforeManifestSha256=$Plan.ManifestSha256;TransactionId=$txn})}
    $relative=$after.BackupRelativePath+'\Transactions\'+$txn;$backup=Get-ZHChild $paths.State $relative
    Assert-ZHNoLink $backup;New-Item -ItemType Directory -Path $backup -Force|Out-Null
    $journalFiles=@()
    foreach($action in $Plan.Actions){
        $target=Get-ZHChild $paths.Game $action.RelativePath;Assert-ZHNoLink $target
        $present=Test-Path -LiteralPath $target -PathType Leaf
        $oldHash=if($present){Get-ZHHash $target}else{$null}
        if($action.ExpectedOldPresent-isnot [bool]-or $present-ne $action.ExpectedOldPresent-or($present-and $oldHash-ne $action.ExpectedOldSha256)){throw ('检查后目标已由外部改动，未创建事务：'+$action.RelativePath)}
        if($present){Copy-ZHVerified $target (Get-ZHChild $backup ('Files\'+$action.RelativePath)) $oldHash}
        if($action.NewPresent-and $action.Source){Assert-ZHNoLink $action.Source;if((Get-ZHHash $action.Source)-ne $action.Sha256){throw '检查后包内文件已改变，已停止。'}}
        $journalFiles+=[pscustomobject]@{RelativePath=$action.RelativePath;OldPresent=$present;OldSha256=$oldHash;NewPresent=$action.NewPresent;NewSha256=$action.Sha256;Stage='pending'}
    }
    foreach($record in $after.OwnedFiles){
        if(-not $record.WasPresent){continue}
        $original=Get-ZHChild $first $record.BackupRelativePath;Assert-ZHNoLink $original
        if(Test-Path -LiteralPath $original){if((Get-ZHHash $original)-ne $record.OriginalSha256){throw '首次备份校验失败，未执行操作。'}}
        else{Copy-ZHVerified (Get-ZHChild $paths.Game $record.RelativePath) $original $record.OriginalSha256}
    }
    if(-not $Plan.Manifest-and $after.Legacy.DisabledByThisInstall){Copy-ZHVerified $paths.Legacy (Get-ZHChild $first 'MortalBeauty.dll') $after.Legacy.Sha256}
    $beforePath=Get-ZHChild $backup 'ManifestBefore.json'
    if($Plan.Manifest){Copy-ZHVerified $paths.Manifest $beforePath $Plan.ManifestSha256}
    $afterPath=Get-ZHChild $backup 'ManifestAfter.json';Save-ZHJson $after $afterPath
    $journal=[pscustomobject]@{SchemaVersion=2;PackageId='ZhaoHuoNatural';GamePath=$paths.Game;InstallationId=$after.InstallationId;TransactionId=$txn;BackupRelativePath=$relative;BeforeExists=($null-ne $Plan.Manifest);BeforeManifestSha256=$Plan.ManifestSha256;AfterManifestSha256=(Get-ZHHash $afterPath);FromSchemaVersion=$(if($Plan.Manifest){$Plan.Manifest.SchemaVersion}else{$null});FromCharacters=@($Plan.BeforeCharacters);ToCharacters=@($after.Characters);CharacterId=$Plan.CharacterId;VariantId=$Plan.VariantId;Files=$journalFiles}
    Save-ZHJson $journal (Get-ZHSwitchPath $paths)
    try{
        $guard=Copy-ZHObject $after;$guard.Status='migrating';Save-ZHJson $guard $paths.Manifest
        for($i=0;$i-lt $Plan.Actions.Count;$i++){
            $action=$Plan.Actions[$i];$record=$journal.Files[$i];$target=Get-ZHChild $paths.Game $action.RelativePath
            Assert-ZHNoLink $target
            if($record.OldPresent){if(-not(Test-Path -LiteralPath $target -PathType Leaf)-or(Get-ZHHash $target)-ne $record.OldSha256){throw '事务执行前目标发生外部改变。'}}elseif(Test-Path -LiteralPath $target){throw '事务执行前目标被外部创建。'}
            $record.Stage='applying';Save-ZHJson $journal (Get-ZHSwitchPath $paths)
            if(-not $action.NewPresent){Remove-Item -LiteralPath $target -Force}
            elseif($null-ne $action.Content){
                $temporary=Get-ZHChild $backup 'selection.tmp';[IO.File]::WriteAllText($temporary,$action.Content,(New-Object Text.UTF8Encoding($false)))
                Copy-ZHVerified $temporary $target $action.Sha256
            }else{Copy-ZHVerified $action.Source $target $action.Sha256}
            $record.Stage='applied';Save-ZHJson $journal (Get-ZHSwitchPath $paths)
        }
        Save-ZHJson $after $paths.Manifest
        Move-Item -LiteralPath (Get-ZHSwitchPath $paths) -Destination (Get-ZHChild $backup 'CompletedTransaction.json')
        return $after
    }catch{
        $failure=$_;Write-ZHLog $Log ('应用失败，正在恢复：'+$failure.Exception.Message) 'Error'
        try{$null=Restore-ZHCharacterTransaction -Paths $paths -Log $Log}catch{Write-ZHLog $Log ('自动恢复未完成。保留所有备份，再运行应用或全部卸载：'+$_.Exception.Message) 'Error'}
        throw $failure
    }
}
