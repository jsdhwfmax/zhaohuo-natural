#requires -Version 5.1
function Copy-ZHObject([object]$Value) { $Value|ConvertTo-Json -Depth 20|ConvertFrom-Json }
function Set-ZHProperty([object]$Object,[string]$Name,[object]$Value) { $Object|Add-Member NoteProperty $Name $Value -Force }
function Get-ZHRecordCharacter([string]$Path) {
    if($Path.StartsWith($script:PluginRelative+'\Portraits\',[StringComparison]::OrdinalIgnoreCase)){return 'player'}
    foreach($id in @('tang-buyi','xiahou-lan')){if($Path.StartsWith((Get-ZHCharacterFolder $id)+'\',[StringComparison]::OrdinalIgnoreCase)){return $id}}
    return $null
}
function Assert-ZHManagedTarget([string]$Path) {
    $relative=$Path.Replace('/','\')
    if($relative-in @('winhttp.dll','doorstop_config.ini')){return}
    if($relative-match '^BepInEx\\core\\[^\\:]+\.(dll|xml)$'){return}
    if($relative-in @('ZhaoHuoNatural.dll','portrait-map.txt','portrait-layout.tsv','characters.json'|ForEach-Object{$script:PluginRelative+'\'+$_})){return}
    foreach($id in $script:CharacterIds){
        $root=Get-ZHCharacterFolder $id
        if($id-ne 'player' -and $relative-eq ($root+'\portrait-layout.tsv')){return}
        foreach($name in $script:CharacterAssets[$id]){if($relative-eq ($root+'\Portraits\'+$name+'.png')){return}}
    }
    throw ('多角色记录含有未允许的目标：'+$relative)
}
function Get-ZHSelectionText([object[]]$Characters) {
    $items=@(foreach($id in $script:CharacterIds){
        $state=@($Characters|Where-Object Id -eq $id)
        if($state.Count-ne 1){throw '安装记录缺少或重复角色。'}
        [ordered]@{Id=$id;Enabled=($state[0].SelectedVariantId-ne 'original')}
    })
    [ordered]@{SchemaVersion=1;Characters=$items}|ConvertTo-Json -Depth 5
}
function Assert-ZHInstalledFiles([object]$Paths,[object]$Manifest) {
    if($Manifest.Status-ne 'installed'){throw '安装事务尚未完成，请先使用恢复入口。'}
    $records=@(Get-ZHOwnedRecords $Manifest);$seen=@{};$backup=Get-ZHChild $Paths.State $Manifest.BackupRelativePath
    foreach($record in $records){
        Assert-ZHRecord $record $Paths $backup
        if($seen.ContainsKey($record.RelativePath)){throw '安装记录包含重复目标。'};$seen[$record.RelativePath]=$true
        if($Manifest.SchemaVersion-eq 4){
            Assert-ZHManagedTarget $record.RelativePath
            if($record.InstalledPresent-isnot [bool] -or [string]$record.CharacterId-cne [string](Get-ZHRecordCharacter $record.RelativePath)){throw '文件存在状态或所属角色无效。'}
        }
        $present=if($record.PSObject.Properties['InstalledPresent']){$record.InstalledPresent}else{$true}
        $file=Get-ZHChild $Paths.Game $record.RelativePath
        if($present){if($record.Stage-ne 'applied' -or-not(Test-Path -LiteralPath $file -PathType Leaf) -or (Get-ZHHash $file)-ne $record.InstalledSha256){throw ('受管文件被修改或缺失：'+$record.RelativePath)}}
        elseif(Test-Path -LiteralPath $file){throw ('已停用的受管路径出现新文件，请先保留并处理：'+$record.RelativePath)}
    }
    if(Test-Path -LiteralPath $Paths.Plugin){foreach($file in @(Get-ZHFiles $Paths.Plugin)){
        $relative=$file.FullName.Substring($Paths.Game.Length+1)
        if(-not $seen.ContainsKey($relative) -and-not $relative.StartsWith($script:PluginRelative+'\Diagnostics\',[StringComparison]::OrdinalIgnoreCase)){throw ('本包目录出现未登记文件，已停止操作：'+$relative)}
    }}
    if($Manifest.Legacy.DisabledByThisInstall){
        $original=Get-ZHChild $backup 'MortalBeauty.dll';Assert-ZHNoLink $original
        if((Test-Path -LiteralPath $Paths.Legacy) -or-not(Test-Path -LiteralPath $Paths.Disabled -PathType Leaf) -or (Get-ZHHash $Paths.Disabled)-ne $Manifest.Legacy.Sha256 -or-not(Test-Path -LiteralPath $original -PathType Leaf) -or (Get-ZHHash $original)-ne $Manifest.Legacy.Sha256){throw '历史旧插件状态或首次备份发生变化，未执行升级。'}
    }
    return $records
}
function ConvertTo-ZHCharacterState([object]$Paths,[object]$Manifest,[object]$Catalog) {
    if($Manifest.SchemaVersion-notin @(3,4)){throw '早期私人安装记录未纳入自动迁移，请先使用原包或当前卸载入口恢复；不要删除备份。'}
    $records=@(Assert-ZHInstalledFiles $Paths $Manifest)
    if($Manifest.SchemaVersion-eq 3){
        if(($Manifest.PSObject.Properties['AdoptedUntrackedPayload'] -and $Manifest.AdoptedUntrackedPayload) -or @($records|Where-Object{$_.Category-eq 'Plugin' -and $_.WasPresent}).Count){throw '此安装来自手工文件接管，不能自动多角色升级；请先卸载并归档原文件。'}
        $plugin=@($records|Where-Object Category -eq 'Plugin')
        $legacyVariants=@(foreach($id in @('natural','handsome','xianxia')){[pscustomobject]@{Id=$id;PayloadFingerprint=$script:KnownVariantFingerprints[$id]}})
        $known=Get-ZHKnownVariant $Manifest $plugin $legacyVariants
        $result=Copy-ZHObject $Manifest;Set-ZHProperty $result 'SchemaVersion' 4
        $characters=@(foreach($id in $script:CharacterIds){
            $payload=$null;$selected='original'
            if($id-eq 'player'){
                $selected=$known.Id
                $files=@($plugin|Where-Object{$_.RelativePath.StartsWith($script:PluginRelative+'\Portraits\',[StringComparison]::OrdinalIgnoreCase)}|ForEach-Object{[pscustomobject]@{Name=[IO.Path]::GetFileName($_.RelativePath);Sha256=$_.InstalledSha256}})
                $payload=[pscustomobject]@{VariantId=$selected;AssetFingerprint=(Get-ZHCharacterFingerprint $id $files)}
            }
            [pscustomobject]@{Id=$id;SelectedVariantId=$selected;InstalledPayload=$payload}
        })
        Set-ZHProperty $result 'Characters' $characters;Set-ZHProperty $result 'RuntimeProtocol' 1
        foreach($record in $result.OwnedFiles){
            Set-ZHProperty $record 'InstalledPresent' $true
            $id=Get-ZHRecordCharacter $record.RelativePath;Set-ZHProperty $record 'CharacterId' $id
            if($id){$record.Category='CharacterPortrait'}elseif($record.Category-eq 'Plugin'){$record.Category='SharedPlugin'}
        }
        # Preserve the legacy identification as history, not as a current v2 hash.
        Set-ZHProperty $result 'LegacyPayloadFingerprint' $known.PayloadFingerprint
        foreach($name in @('VariantId','VariantDisplayName','PayloadFingerprint')){$result.PSObject.Properties.Remove($name)}
    }else{$result=Copy-ZHObject $Manifest}
    if($result.RuntimeProtocol-ne 1 -or @($result.Characters).Count-ne 3){throw '多角色安装记录协议无效。'}
    $seen=@{}
    foreach($character in $result.Characters){
        if($character.Id-notin $script:CharacterIds -or $seen.ContainsKey($character.Id)){throw '安装记录含未知或重复角色。'};$seen[$character.Id]=$true
        $definition=@($Catalog.Characters|Where-Object Id -eq $character.Id)[0]
        if(@($definition.Variants|Where-Object Id -eq $character.SelectedVariantId).Count-ne 1){throw '安装记录的角色外观不在此包内。'}
        $images=@($result.OwnedFiles|Where-Object{$_.CharacterId-eq $character.Id -and $_.RelativePath-match '\\Portraits\\[^\\]+\.png$' -and $_.InstalledPresent})
        if($null-eq $character.InstalledPayload){if($images.Count -or $character.SelectedVariantId-ne 'original'){throw '角色图片与停用状态不一致。'};continue}
        $variant=@($definition.Variants|Where-Object Id -eq $character.InstalledPayload.VariantId)
        $files=@($images|ForEach-Object{[pscustomobject]@{Name=[IO.Path]::GetFileName($_.RelativePath);Sha256=$_.InstalledSha256}})
        $fingerprint=Get-ZHCharacterFingerprint $character.Id $files
        if($variant.Count-ne 1 -or $variant[0].Kind-ne 'custom' -or $fingerprint-ne $variant[0].AssetFingerprint -or $fingerprint-ne $character.InstalledPayload.AssetFingerprint -or ($character.SelectedVariantId-ne 'original' -and $character.SelectedVariantId-ne $character.InstalledPayload.VariantId)){throw '角色文件的完整指纹或启用状态不匹配，未自动接管。'}
    }
    if($Manifest.SchemaVersion-eq 4){
        $configRelative=$script:PluginRelative+'\characters.json'
        if(@($records|Where-Object{$_.RelativePath-eq $configRelative -and $_.InstalledPresent}).Count-ne 1){throw '多角色安装缺少受管选择配置。'}
        $config=Get-Content -LiteralPath (Get-ZHChild $Paths.Game $configRelative) -Raw -Encoding UTF8|ConvertFrom-Json
        if($config.SchemaVersion-ne 1 -or @($config.Characters).Count-ne 3){throw '运行时角色开关无效。'};$configIds=@{}
        foreach($entry in $config.Characters){
            if($entry.Id-notin $script:CharacterIds -or $configIds.ContainsKey($entry.Id) -or $entry.Enabled-isnot [bool]){throw '运行时角色开关未知或重复。'};$configIds[$entry.Id]=$true
            $state=@($result.Characters|Where-Object Id -eq $entry.Id)[0]
            if($entry.Enabled-ne ($state.SelectedVariantId-ne 'original')){throw '运行时角色开关与安装记录不同。'}
        }
    }
    return $result
}
function Get-PortraitManagerState {
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)][string]$GamePath,[Parameter(Mandatory=$true)][string]$PackageRoot)
    $catalog=Read-ZHCharacterCatalog $PackageRoot
    $result=[pscustomobject]@{Status='Invalid';HasManifest=$false;SchemaVersion=$null;RequiresMigration=$false;CanApply=$false;Message='';Characters=@()}
    $state=$null
    try{
        $paths=Get-ZHLocations $GamePath
        foreach($path in @($paths.Game,$paths.State,$paths.Manifest,$paths.Plugin)){Assert-ZHNoLink $path}
        if(-not(Test-Path -LiteralPath (Get-ZHChild $paths.Game 'Mortal.exe') -PathType Leaf)){throw '请选择包含 Mortal.exe 的游戏目录。'}
        $result.HasManifest=Test-Path -LiteralPath $paths.Manifest -PathType Leaf
        if(Test-Path -LiteralPath (Get-ZHSwitchPath $paths)){$result.Status='RecoveryRequired';throw '存在未完成事务，应用或全部卸载会先恢复；仅检查不写入。'}
        $manifest=Read-ZHState $paths
        if($null-eq $manifest){
            if(Test-Path -LiteralPath $paths.Plugin){$result.Status='Unmanaged';throw '本包目录没有活动安装记录，请先保留并归档该目录。'}
            $result.Status='NotInstalled';$result.CanApply=$catalog.PackageReady;$result.Message='尚未安装本包，各角色使用原版。'
        }else{
            $result.SchemaVersion=$manifest.SchemaVersion
            if($manifest.SchemaVersion-notin @(3,4)){$result.Status='LegacyUnsupported';throw '早期私人记录请先使用卸载入口恢复，不能自动迁移。'}
            if($manifest.Status-ne 'installed'){$result.Status='RecoveryRequired';throw '安装事务尚未完成，请先恢复。'}
            $result.Status='Modified';$state=ConvertTo-ZHCharacterState $paths $manifest $catalog
            $result.Status='Installed';$result.RequiresMigration=($manifest.SchemaVersion-eq 3);$result.CanApply=$catalog.PackageReady;$result.Message='已核验各角色当前外观。'
        }
    }catch{$result.Message=$_.Exception.Message;$result.CanApply=$false}
    $result.Characters=@(foreach($definition in $catalog.Characters){
        $id=$null;$name=$null;$kind='Unknown'
        if($result.Status-eq 'NotInstalled'){$id='original'}
        elseif($result.Status-eq 'Installed'){$id=@($state.Characters|Where-Object Id -eq $definition.Id)[0].SelectedVariantId}
        if($id){$variant=@($definition.Variants|Where-Object Id -eq $id)[0];$name=$variant.DisplayName;$kind=if($id-eq 'original'){'Original'}else{'Custom'}}
        [pscustomobject]@{Id=$definition.Id;DisplayName=$definition.DisplayName;State=$kind;SelectedVariantId=$id;InstalledVariantId=$id;InstalledDisplayName=$name}
    })
    return $result
}
