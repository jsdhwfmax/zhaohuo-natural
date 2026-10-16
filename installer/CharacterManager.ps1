#requires -Version 5.1
# Per-character planning. This file never loads or executes a game assembly.
function New-ZHCharacterAction([string]$Relative,[string]$Source,[string]$Hash,[string]$Category,[string]$CharacterId) {
    [pscustomobject]@{RelativePath=$Relative;Source=$Source;Content=$null;Sha256=$Hash;NewPresent=$true;Category=$Category;CharacterId=$CharacterId}
}
function Get-PortraitApplyPlan {
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)][string]$GamePath,[Parameter(Mandatory=$true)][string]$PackageRoot,
        [string]$CharacterId='player',[string]$VariantId='natural')
    $root=Get-ZHCanonical $PackageRoot;$paths=Get-ZHLocations $GamePath
    foreach($path in @($root,$paths.Game,$paths.Plugin,$paths.State,$paths.Manifest,$paths.Legacy,$paths.Disabled)){Assert-ZHNoLink $path}
    if($root-eq $paths.Game -or $root.StartsWith($paths.Game+'\',[StringComparison]::OrdinalIgnoreCase)){throw '请将完整管理器解压到游戏目录之外，再运行安装；不能直接覆盖到游戏根目录。'}
    Assert-ZHStopped $paths.Game
    if(Test-Path -LiteralPath (Get-ZHSwitchPath $paths)){throw '存在未完成事务，请通过应用或全部卸载入口先恢复。'}
    $catalog=Read-ZHCharacterCatalog $root
    $definition=@($catalog.Characters|Where-Object Id -eq $CharacterId)
    if($definition.Count-ne 1){throw '此管理器不支持所选角色。'}
    $variant=@($definition[0].Variants|Where-Object Id -eq $VariantId)
    if($variant.Count-ne 1){throw '所选角色没有该外观。'};$variant=$variant[0]
    if(-not $catalog.PackageReady -or -not $variant.Ready){throw '此包的图片或运行组件尚未完成验证，暂不可安装。请使用完整正式发布包。'}
    $validation=Get-ZHGameValidation $paths.Game $root
    $dependencies=@(Read-ZHDependencies $root);$environment=Get-ZHEnvironment $paths.Game $dependencies
    $manifest=Read-ZHState $paths;$manifestHash=$null
    $actions=@();$legacyActions=@()
    if($manifest){
        if(-not(Test-Path -LiteralPath (Get-ZHChild $paths.Game 'doorstop_config.ini') -PathType Leaf)){throw '已安装环境缺少 doorstop_config.ini，请先卸载并恢复后重新安装。'}
        $manifestHash=Get-ZHHash $paths.Manifest
        $after=ConvertTo-ZHCharacterState $paths $manifest $catalog
    }else{
        if(Test-Path -LiteralPath $paths.Plugin){throw '检测到未登记的本包目录。为保护手工文件，不能自动覆盖；请先把该目录完整备份到游戏目录外，再重试。'}
        if(Test-Path -LiteralPath $paths.Disabled){throw '旧插件停用路径已存在，但没有本包记录。请保留文件并先处理冲突。'}
        if($VariantId-eq 'original'){
            return [pscustomobject]@{Paths=$paths;Catalog=$catalog;Manifest=$null;ManifestSha256=$null;After=$null;Actions=@();Validation=$validation;Environment=$environment;CharacterId=$CharacterId;VariantId=$VariantId;RequiresMigration=$false;NoOp=$true}
        }
        $id=(Get-Date -Format 'yyyyMMdd-HHmmss')+'-'+[Guid]::NewGuid().ToString('N').Substring(0,8)
        $legacyPresent=Test-Path -LiteralPath $paths.Legacy -PathType Leaf
        if((Test-Path -LiteralPath $paths.Legacy)-and-not $legacyPresent){throw '旧插件路径被同名目录占用。'}
        $legacyHash=if($legacyPresent){Get-ZHHash $paths.Legacy}else{$null}
        $after=[pscustomobject][ordered]@{
            SchemaVersion=4;PackageId='ZhaoHuoNatural';InstallationId=$id;Status='installed';GamePath=$paths.Game
            InstalledAtUtc=[DateTime]::UtcNow.ToString('o');BackupRelativePath=('Backups\'+$id);RuntimeProtocol=2
            Environment=$environment;AdoptedUntrackedPayload=$false;OwnedFiles=@();CreatedDirectories=@()
            Characters=@(foreach($cid in $script:CharacterIds){[pscustomobject]@{Id=$cid;SelectedVariantId='original';InstalledPayload=$null}})
            Legacy=[pscustomobject]@{WasPresent=$legacyPresent;DisabledByThisInstall=$legacyPresent;Sha256=$legacyHash;Stage='applied'}
        }
        if($legacyPresent){
            $legacyActions+=New-ZHCharacterAction ($script:LegacyRelative+'.disabled-by-zhaohuo-natural') $paths.Legacy $legacyHash 'Legacy' $null
            $legacyActions+=[pscustomobject]@{RelativePath=$script:LegacyRelative;Source=$null;Content=$null;Sha256=$legacyHash;NewPresent=$false;Category='Legacy';CharacterId=$null}
            foreach($action in $legacyActions){
                Set-ZHProperty $action 'ExpectedOldPresent' ($action.RelativePath-eq $script:LegacyRelative)
                Set-ZHProperty $action 'ExpectedOldSha256' $(if($action.RelativePath-eq $script:LegacyRelative){$legacyHash}else{$null})
            }
        }
    }
    foreach($field in @('GameAssemblySha256','SteamBuildId','MatchedBuildId','CompatibilityMode','DetectedBuild','CompatibilityEvidence')){
        $value=switch($field){
            GameAssemblySha256 {$validation.Hashes} SteamBuildId {$validation.BuildId} MatchedBuildId {$validation.MatchedBuildId}
            CompatibilityMode {$validation.CompatibilityMode} DetectedBuild {$validation.DetectedBuild}
            CompatibilityEvidence {if($validation.Probe){[pscustomobject]@{BaselineBuildIds=@($validation.Probe.BaselineBuildIds);Checks=@($validation.Probe.Checks)}}else{$null}}
        }
        Set-ZHProperty $after $field $value
    }
    foreach($shared in $catalog.SharedFiles){
        $relative=$script:PluginRelative+'\'+$shared.Name;$source=Get-ZHChild $root $relative;Assert-ZHNoLink $source
        if(-not(Test-Path -LiteralPath $source -PathType Leaf)-or(Get-ZHHash $source)-ne $shared.Sha256){throw ('共享运行组件校验失败：'+$shared.Name)}
        $actions+=New-ZHCharacterAction $relative $source $shared.Sha256 'SharedPlugin' $null
    }
    $beforeCharacters=if($manifest -and $manifest.SchemaVersion-eq 4){Copy-ZHObject @($manifest.Characters)}else{Copy-ZHObject @($after.Characters)}
    $selected=@($after.Characters|Where-Object Id -eq $CharacterId)[0]
    $selected.SelectedVariantId=$VariantId
    if($variant.Kind-eq 'custom'){
        $desired=@(Get-ZHCharacterAssetActions $root $definition[0] $variant)
        $actions+=$desired
        $wanted=@{};foreach($action in $desired){$wanted[$action.RelativePath]=$true}
        foreach($record in @($after.OwnedFiles|Where-Object{$_.CharacterId-eq $CharacterId -and $_.InstalledPresent})){
            if(-not $wanted.ContainsKey($record.RelativePath)){
                $actions+=[pscustomobject]@{RelativePath=$record.RelativePath;Source=$null;Content=$null;Sha256=$record.InstalledSha256;NewPresent=$false;Category=$record.Category;CharacterId=$CharacterId}
            }
        }
        $selected.InstalledPayload=[pscustomobject]@{VariantId=$VariantId;AssetFingerprint=$variant.AssetFingerprint}
    }
    if(-not $manifest){
        if($environment-eq 'CleanGame'){
            foreach($entry in $dependencies){$actions+=New-ZHCharacterAction $entry.RelativePath $entry.Source $entry.Sha256 'Runtime' $null}
        }elseif(-not(Test-Path -LiteralPath (Get-ZHChild $paths.Game 'doorstop_config.ini'))){
            $entry=@($dependencies|Where-Object RelativePath -eq 'doorstop_config.ini')[0]
            $actions+=New-ZHCharacterAction $entry.RelativePath $entry.Source $entry.Sha256 'Runtime' $null
        }
        $loader=Get-ZHChild $root 'Loader\winhttp.dll';Assert-ZHNoLink $loader
        if((Get-ZHHash $loader)-ne $script:LoaderHash-or(Get-ZHMachine $loader)-ne 0x8664){throw '离线加载器校验失败。'}
        $actions+=New-ZHCharacterAction 'winhttp.dll' $loader $script:LoaderHash 'Loader' $null
    }
    $text=Get-ZHSelectionText $after.Characters
    $actions+=[pscustomobject]@{RelativePath=($script:PluginRelative+'\characters.json');Source=$null;Content=$text;Sha256=(Get-ZHTextHash $text);NewPresent=$true;Category='Selection';CharacterId=$null}
    $changes=@();$records=@($after.OwnedFiles);$seen=@{}
    foreach($action in $actions){
        Assert-ZHManagedTarget $action.RelativePath
        if($seen.ContainsKey($action.RelativePath)){throw '应用计划含重复目标。'};$seen[$action.RelativePath]=$true
        $target=Get-ZHChild $paths.Game $action.RelativePath;Assert-ZHNoLink $target
        if(Test-Path -LiteralPath $target -PathType Container){throw ('目标被目录占用：'+$action.RelativePath)}
        $old=@($records|Where-Object RelativePath -eq $action.RelativePath)
        if($old.Count-gt 1){throw '安装记录重复。'}
        if($old.Count-eq 0){
            $present=Test-Path -LiteralPath $target -PathType Leaf
            if($present -and $action.RelativePath-ne 'winhttp.dll'){throw ('新增受管路径已有外部文件，请先保留并处理：'+$action.RelativePath)}
            $oldHash=if($present){Get-ZHHash $target}else{$null}
            Set-ZHProperty $action 'ExpectedOldPresent' $present;Set-ZHProperty $action 'ExpectedOldSha256' $oldHash
            $record=[pscustomobject]@{RelativePath=$action.RelativePath;InstalledSha256=$action.Sha256;InstalledPresent=$action.NewPresent;WasPresent=$present;OriginalSha256=$oldHash;BackupRelativePath=$(if($present){'Original\'+$action.RelativePath}else{$null});Stage='applied';Category=$action.Category;CharacterId=$action.CharacterId}
            $records+=$record;$changes+=$action
        }else{
            $record=$old[0]
            Set-ZHProperty $action 'ExpectedOldPresent' $record.InstalledPresent
            Set-ZHProperty $action 'ExpectedOldSha256' $(if($record.InstalledPresent){$record.InstalledSha256}else{$null})
            if($record.InstalledPresent-ne $action.NewPresent -or ($action.NewPresent-and $record.InstalledSha256-ne $action.Sha256)){$changes+=$action}
            $record.InstalledSha256=$action.Sha256;$record.InstalledPresent=$action.NewPresent;$record.Stage='applied'
        }
    }
    $after.OwnedFiles=$records;$after.Status='installed'
    $created=@{};foreach($directory in @($after.CreatedDirectories)){$created[$directory]=$true}
    foreach($action in $changes){
        $directory=[IO.Path]::GetDirectoryName((Get-ZHChild $paths.Game $action.RelativePath))
        while($directory -and $directory-ne $paths.Game){if(-not(Test-Path -LiteralPath $directory)){$created[$directory.Substring($paths.Game.Length+1)]=$true};$directory=[IO.Path]::GetDirectoryName($directory)}
    }
    $after.CreatedDirectories=@($created.Keys)
    $migration=($null-ne $manifest -and ($manifest.SchemaVersion-eq 3 -or $manifest.RuntimeProtocol-ne $catalog.RuntimeProtocol))
    [pscustomobject]@{Paths=$paths;Catalog=$catalog;Manifest=$manifest;ManifestSha256=$manifestHash;BeforeCharacters=@($beforeCharacters);After=$after;Actions=@($legacyActions)+@($changes);Validation=$validation;Environment=$environment;CharacterId=$CharacterId;VariantId=$VariantId;RequiresMigration=$migration;NoOp=($manifest-and-not $migration-and $changes.Count-eq 0)}
}
function Set-PortraitAppearance {
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)][string]$GamePath,[Parameter(Mandatory=$true)][string]$PackageRoot,
        [string]$CharacterId='player',[string]$VariantId='natural',[switch]$CheckOnly,[scriptblock]$Log)
    $mutex=Enter-ZHOperation $GamePath
    try{
        $paths=Get-ZHLocations $GamePath
        if(Test-Path -LiteralPath (Get-ZHSwitchPath $paths)){
            $null=Restore-ZHSwitch -Paths $paths -CheckOnly:$CheckOnly -Log $Log
            if($CheckOnly){return [pscustomobject]@{Status='RecoveryRequired';CharacterId=$CharacterId;VariantId=$VariantId;RequiresMigration=$false;ChangedFiles=0}}
        }
        $plan=Get-PortraitApplyPlan -GamePath $GamePath -PackageRoot $PackageRoot -CharacterId $CharacterId -VariantId $VariantId
        $status=if($CheckOnly){'Checked'}elseif($plan.NoOp){'NoOp'}else{'Applied'}
        if($CheckOnly){Write-ZHLog $Log ('检查通过；角色 '+$CharacterId+'，外观 '+$VariantId+'，待修改 '+$plan.Actions.Count+' 个文件。未写入游戏。')}
        elseif($plan.NoOp){Write-ZHLog $Log '当前角色已是所选外观，文件核验通过，无需重复覆盖。'}
        else{$null=Invoke-ZHCharacterTransaction $plan $Log;Write-ZHLog $Log '外观已应用。其他角色选择和首次卸载备份保持不变，请从 Steam 库启动游戏。'}
        return [pscustomobject]@{Status=$status;CharacterId=$CharacterId;VariantId=$VariantId;RequiresMigration=$plan.RequiresMigration;ChangedFiles=$plan.Actions.Count}
    }finally{$mutex.ReleaseMutex();$mutex.Dispose()}
}
function Uninstall-PortraitManager {
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)][string]$GamePath,[switch]$CheckOnly,[scriptblock]$Log)
    Uninstall-ZhaoHuo @PSBoundParameters
}
