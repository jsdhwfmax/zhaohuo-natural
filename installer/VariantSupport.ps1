#requires -Version 5.1
# Loaded inside ZhaoHuoInstaller.psm1. This file never loads game assemblies.
function Get-ZHPayloadFingerprint([object[]]$Files) {
    $lines = [string[]]@($Files | ForEach-Object {
        $hash = if ($_.PSObject.Properties['Sha256']) { $_.Sha256 } else { $_.InstalledSha256 }
        ([string]$_.RelativePath).Replace('\','/').ToLowerInvariant() + '=' + ([string]$hash).ToUpperInvariant()
    })
    # Sort-Object uses different linguistic collation in .NET Framework and
    # modern .NET. Canonical payload hashes must be identical in PS 5.1 / 7.
    [Array]::Sort($lines, [StringComparer]::Ordinal)
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes(($lines -join "`n"))))).Replace('-','') }
    finally { $sha.Dispose() }
}
function Read-ZHVariant([string]$PackageRoot,[string]$VariantId) {
    $catalog = Read-ZHVariantCatalog $PackageRoot
    if ($null -ne $catalog) {
        if ([string]::IsNullOrWhiteSpace($VariantId)) { $VariantId=$catalog.DefaultVariantId }
        $selected = @($catalog.Variants | Where-Object { $_.Id -eq $VariantId })
        if ($selected.Count -ne 1) { throw '请选择 natural、handsome 或 xianxia 中的一种外观。' }
        $selected[0] | Add-Member NoteProperty SwitchFrom @($catalog.Variants | Where-Object { $_.Id -ne $VariantId })
        $selected[0] | Add-Member NoteProperty ManagerCatalog $true
        return $selected[0]
    }
    $file = Get-ZHChild $PackageRoot 'Variant.json'
    Assert-ZHNoLink $file
    if (-not (Test-Path -LiteralPath $file -PathType Leaf)) {
        if ($VariantId -and $VariantId -ne 'natural') { throw '此旧安装包仅包含 natural 外观。' }
        return [pscustomobject]@{ Id='natural'; DisplayName='赵活自然版'; PayloadReady=$true; PayloadFingerprint=$null; SwitchFrom=@() }
    }
    $data = Get-Content -LiteralPath $file -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($data.SchemaVersion -ne 1 -or $data.Id -notin @('natural','handsome','xianxia') -or [string]::IsNullOrWhiteSpace($data.DisplayName)) { throw '外观包描述文件无效，请重新完整解压安装包。' }
    if ($data.PayloadReady -isnot [bool] -or -not $data.PayloadReady) { throw '外观包图片尚未全部准备完成；当前目录是开发准备版，不能安装或发布。' }
    if ($data.PayloadFingerprint -notmatch '^[0-9A-Fa-f]{64}$') { throw '外观包缺少完整载荷校验值。' }
    if ($VariantId -and $VariantId -ne $data.Id) { throw '所选外观不在此旧安装包中。' }
    $sourceIds=@{}; $sourceHashes=@{}
    foreach ($source in @($data.SwitchFrom)) {
        if ($source.Id -notin @('natural','handsome','xianxia') -or $source.Id -eq $data.Id -or $source.PayloadFingerprint -notmatch '^[0-9A-Fa-f]{64}$' -or $sourceIds.ContainsKey($source.Id) -or $sourceHashes.ContainsKey($source.PayloadFingerprint)) { throw '外观包的允许切换来源无效或重复。' }
        $sourceIds[$source.Id]=$true; $sourceHashes[$source.PayloadFingerprint]=$true
    }
    return $data
}
function Get-ZHSwitchPath([object]$Paths) { Get-ZHChild $Paths.State 'ActiveSwitch.json' }
function Assert-ZHSwitchSource([object]$PlanVariant,[object]$Manifest,[object[]]$Records,[object[]]$Actions,[object]$Paths) {
    if ($PlanVariant.Id -notin @('natural','handsome','xianxia') -or $Manifest.SchemaVersion -ne 3) { throw '此安装包不能直接切换当前旧包，请使用当前包卸载后再安装。' }
    if (($Manifest.PSObject.Properties['AdoptedUntrackedPayload'] -and $Manifest.AdoptedUntrackedPayload) -or @($Records | Where-Object { $_.WasPresent }).Count -ne 0) { throw '当前立绘来自手工复制或误解压接管，不能自动切换。请保留备份并先卸载；原文件应归档到 BepInEx\plugins 之外后再安装。' }
    $currentFingerprint = Get-ZHPayloadFingerprint $Records
    $matchedSource=@($PlanVariant.SwitchFrom | Where-Object { $_.PayloadFingerprint -eq $currentFingerprint })
    if ($matchedSource.Count -ne 1) { throw '当前受管立绘不是本包认可的完整外观，不能自动切换；请保留文件并先使用当前安装器卸载。' }
    if ($Manifest.PSObject.Properties['VariantId'] -and $Manifest.VariantId -ne $matchedSource[0].Id) { throw '安装记录的外观名称与完整文件指纹不一致，未执行切换。请保留文件和记录。' }
    if ($Manifest.PSObject.Properties['PayloadFingerprint'] -and $Manifest.PayloadFingerprint -ne $currentFingerprint) { throw '安装记录的外观指纹与实际文件不一致，未执行切换。' }
    if ($Records.Count -ne 50 -or $Actions.Count -ne 50) { throw '切换只支持完整的 50 个受管载荷文件。' }
    $owned = @{}
    foreach ($record in $Records) { $owned[$record.RelativePath] = $record.InstalledSha256 }
    foreach ($action in $Actions) {
        if (-not $owned.ContainsKey($action.RelativePath)) { throw '两份外观包的文件路径不同，不能直接切换。' }
        if ($action.RelativePath -notmatch '\\Portraits\\[^\\]+\.png$' -and $action.Sha256 -ne $owned[$action.RelativePath]) { throw '插件 DLL、映射或布局发生变化，不能使用仅更换立绘的切换流程。' }
    }
    foreach ($file in @(Get-ZHFiles $Paths.Plugin)) {
        $relative = $file.FullName.Substring($Paths.Game.Length + 1)
        if (-not $owned.ContainsKey($relative) -and -not $relative.StartsWith($script:PluginRelative + '\Diagnostics\',[StringComparison]::OrdinalIgnoreCase)) { throw "立绘目录中有未登记文件，不能自动切换；该文件已保留：$relative" }
    }
    return $matchedSource[0]
}
function Read-ZHSwitch([object]$Paths) {
    $journalPath = Get-ZHSwitchPath $Paths
    Assert-ZHNoLink $journalPath
    if (-not (Test-Path -LiteralPath $journalPath -PathType Leaf)) { return $null }
    $journal = Get-Content -LiteralPath $journalPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($journal.SchemaVersion -ne 1 -or $journal.PackageId -ne 'ZhaoHuoNatural' -or $journal.GamePath -ne $Paths.Game -or
        $journal.InstallationId -notmatch '^\d{8}-\d{6}-[0-9a-f]{8}$' -or $journal.SwitchId -notmatch '^\d{8}-\d{6}-[0-9a-f]{8}$' -or
        $journal.BackupRelativePath -ne ('Backups\' + $journal.InstallationId + '\Switches\' + $journal.SwitchId)) { throw '切换恢复记录无效，请保留备份，勿手工删除记录。' }
    $backup = Get-ZHChild $Paths.State $journal.BackupRelativePath
    $beforePath = Get-ZHChild $backup 'ManifestBefore.json'
    Assert-ZHNoLink $beforePath
    if ($journal.BeforeManifestSha256 -notmatch '^[0-9A-Fa-f]{64}$' -or -not (Test-Path -LiteralPath $beforePath -PathType Leaf) -or (Get-ZHHash $beforePath) -ne $journal.BeforeManifestSha256) { throw '切换前安装记录备份损坏，未执行恢复。' }
    $before = Get-Content -LiteralPath $beforePath -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($before.SchemaVersion -ne 3 -or $before.PackageId -ne 'ZhaoHuoNatural' -or $before.GamePath -ne $Paths.Game -or $before.Status -ne 'installed' -or $before.InstallationId -ne $journal.InstallationId -or $before.BackupRelativePath -ne ('Backups\' + $journal.InstallationId)) { throw '切换前安装记录不属于当前安装，未执行恢复。' }
    Assert-ZHNoLink $Paths.Manifest
    $active = Read-ZHState $Paths
    if ($null -eq $active -or $active.InstallationId -ne $journal.InstallationId) { throw '当前安装已被移除或属于另一次安装，不能自动恢复此切换。请保留备份。' }
    $seen = @{}
    if (@($journal.Files).Count -lt 1 -or @($journal.Files).Count -gt $script:PortraitNames.Count) { throw '切换文件清单数量无效。' }
    foreach ($file in @($journal.Files)) {
        $relative = [string]$file.RelativePath
        $allowed = @($script:PortraitNames | ForEach-Object { $script:PluginRelative + '\Portraits\' + $_ + '.png' })
        if ($relative -notin $allowed -or $seen.ContainsKey($relative) -or $file.Stage -notin @('pending','applying','applied') -or $file.OldSha256 -notmatch '^[0-9A-Fa-f]{64}$' -or $file.NewSha256 -notmatch '^[0-9A-Fa-f]{64}$') { throw '切换记录包含不允许的文件或事务状态。' }
        $seen[$relative] = $true
        if (@($before.OwnedFiles | Where-Object { $_.Category -eq 'Plugin' -and $_.RelativePath -eq $relative -and $_.InstalledSha256 -eq $file.OldSha256 }).Count -ne 1) { throw '切换记录与原安装文件清单不一致。' }
        $original = Get-ZHChild $backup ('Files\' + $relative)
        $target = Get-ZHChild $Paths.Game $relative
        Assert-ZHNoLink $original; Assert-ZHNoLink $target
        if (-not (Test-Path -LiteralPath $original -PathType Leaf) -or (Get-ZHHash $original) -ne $file.OldSha256) { throw "切换前立绘备份缺失或校验失败：$relative" }
        if (Test-Path -LiteralPath $target -PathType Container) { throw '切换目标被同名目录占用，未执行恢复。' }
    }
    [pscustomobject]@{ Journal=$journal; JournalPath=$journalPath; Backup=$backup; BeforePath=$beforePath; Before=$before }
}
function Restore-ZHSwitch([object]$Paths,[switch]$CheckOnly,[scriptblock]$Log) {
    $journalPath=Get-ZHSwitchPath $Paths;Assert-ZHNoLink $journalPath
    if(Test-Path -LiteralPath $journalPath -PathType Leaf){
        $header=Get-Content -LiteralPath $journalPath -Raw -Encoding UTF8|ConvertFrom-Json
        if($header.SchemaVersion-eq 2){return (Restore-ZHCharacterTransaction -Paths $Paths -CheckOnly:$CheckOnly -Log $Log)}
    }
    $pending = Read-ZHSwitch $Paths
    if ($null -eq $pending) { return $false }
    Assert-ZHStopped $Paths.Game
    if ($CheckOnly) { Write-ZHLog $Log '发现未完成切换，恢复记录与备份校验通过；仅检查未修改文件。请点击安装或卸载，由当前安装器先恢复本次切换前的外观。'; return $true }
    foreach ($file in @($pending.Journal.Files)) {
        $target = Get-ZHChild $Paths.Game $file.RelativePath
        if (Test-Path -LiteralPath $target -PathType Leaf) {
            $hash = Get-ZHHash $target
            if ($hash -ne $file.OldSha256 -and $hash -ne $file.NewSha256) {
                $preserved = Get-ZHChild $pending.Backup ('PreservedDuringRecovery\' + $file.RelativePath)
                if (Test-Path -LiteralPath $preserved) { $preserved += '.' + [Guid]::NewGuid().ToString('N') }
                Copy-ZHVerified $target $preserved $hash
                Write-ZHLog $Log "已保留中断后修改的立绘：$preserved" 'Warning'
            }
        }
        Copy-ZHVerified (Get-ZHChild $pending.Backup ('Files\' + $file.RelativePath)) $target $file.OldSha256
    }
    $temporary = $Paths.Manifest + '.restore.tmp'
    Copy-ZHVerified $pending.BeforePath $temporary $pending.Journal.BeforeManifestSha256
    Move-Item -LiteralPath $temporary -Destination $Paths.Manifest -Force
    $archive = Get-ZHChild $pending.Backup 'RolledBackSwitch.json'
    Assert-ZHNoLink $archive
    Move-Item -LiteralPath $pending.JournalPath -Destination $archive -Force
    Write-ZHLog $Log '未完成的外观切换已回滚，恢复切换前立绘和安装记录；最初卸载备份仍保留。'
    return $true
}
function Invoke-ZHVariantSwitch([object]$Plan,[scriptblock]$Log) {
    $paths = $Plan.Paths
    Assert-ZHStopped $paths.Game
    if ((Get-ZHHash $paths.Manifest) -ne $Plan.ManifestSha256) { throw '安装记录在检查后发生变化，请重新检查再切换。' }
    foreach ($record in @($Plan.Manifest.OwnedFiles)) {
        if ((Get-ZHHash (Get-ZHChild $paths.Game $record.RelativePath)) -ne $record.InstalledSha256) { throw "已安装文件在检查后发生变化，切换停止：$($record.RelativePath)" }
    }
    $switchId = (Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + [Guid]::NewGuid().ToString('N').Substring(0,8)
    $backupRelative = $Plan.Manifest.BackupRelativePath + '\Switches\' + $switchId
    $backup = Get-ZHChild $paths.State $backupRelative
    Assert-ZHNoLink $backup
    New-Item -ItemType Directory -Path $backup -Force | Out-Null
    $beforePath = Get-ZHChild $backup 'ManifestBefore.json'
    Copy-ZHVerified $paths.Manifest $beforePath $Plan.ManifestSha256
    $records = @()
    foreach ($action in $Plan.Actions) {
        $old = @($Plan.Manifest.OwnedFiles | Where-Object { $_.RelativePath -eq $action.RelativePath })[0]
        Copy-ZHVerified (Get-ZHChild $paths.Game $action.RelativePath) (Get-ZHChild $backup ('Files\' + $action.RelativePath)) $old.InstalledSha256
        $records += [pscustomobject]@{ RelativePath=$action.RelativePath; OldSha256=$old.InstalledSha256; NewSha256=$action.Sha256; Stage='pending' }
    }
    $after = Get-Content -LiteralPath $beforePath -Raw -Encoding UTF8 | ConvertFrom-Json
    foreach ($record in $after.OwnedFiles) {
        $replacement = @($Plan.Actions | Where-Object { $_.RelativePath -eq $record.RelativePath })
        if ($replacement.Count -eq 1) { $record.InstalledSha256 = $replacement[0].Sha256 }
    }
    $after | Add-Member NoteProperty VariantId $Plan.Variant.Id -Force
    $after | Add-Member NoteProperty VariantDisplayName $Plan.Variant.DisplayName -Force
    $after | Add-Member NoteProperty PayloadFingerprint $Plan.PayloadFingerprint -Force
    $after | Add-Member NoteProperty LastVariantSwitch ([pscustomobject]@{ SwitchId=$switchId; AtUtc=[DateTime]::UtcNow.ToString('o'); From=$Plan.SourceVariant.Id; To=$Plan.Variant.Id; FromPayloadFingerprint=$Plan.SourceVariant.PayloadFingerprint; ToPayloadFingerprint=$Plan.PayloadFingerprint; BackupRelativePath=$backupRelative; CompatibilityMode=$Plan.Validation.CompatibilityMode; DetectedBuild=$Plan.Validation.DetectedBuild }) -Force
    $during = Get-Content -LiteralPath $beforePath -Raw -Encoding UTF8 | ConvertFrom-Json
    $during.Status = 'switching'
    $journal = [pscustomobject]@{ SchemaVersion=1; PackageId='ZhaoHuoNatural'; GamePath=$paths.Game; InstallationId=$Plan.Manifest.InstallationId; SwitchId=$switchId; BackupRelativePath=$backupRelative; BeforeManifestSha256=$Plan.ManifestSha256; From=$Plan.SourceVariant.Id; To=$Plan.Variant.Id; FromPayloadFingerprint=$Plan.SourceVariant.PayloadFingerprint; ToPayloadFingerprint=$Plan.PayloadFingerprint; Files=$records }
    $journalPath = Get-ZHSwitchPath $paths
    Save-ZHJson $journal $journalPath
    try {
        Save-ZHJson $during $paths.Manifest
        for ($index=0; $index -lt $records.Count; $index++) {
            $records[$index].Stage='applying'; Save-ZHJson $journal $journalPath
            $action=$Plan.Actions[$index]
            Copy-ZHVerified $action.Source (Get-ZHChild $paths.Game $action.RelativePath) $action.Sha256
            $records[$index].Stage='applied'; Save-ZHJson $journal $journalPath
        }
        Save-ZHJson $after $paths.Manifest
        $archive = Get-ZHChild $backup 'SwitchManifest.json'
        Assert-ZHNoLink $archive
        Move-Item -LiteralPath $journalPath -Destination $archive
        Write-ZHLog $Log ("已安全切换为$($Plan.Variant.DisplayName)。原安装备份未替换，其他模组和存档未改动；请从 Steam 启动游戏。")
        Write-ZHLog $Log "切换前立绘与记录已保留：$backup"
        return $after
    } catch {
        $failure=$_
        Write-ZHLog $Log ('切换失败，正在恢复上一版立绘：' + $failure.Exception.Message) 'Error'
        try { $null=Restore-ZHSwitch -Paths $paths -Log $Log }
        catch { Write-ZHLog $Log ('自动恢复未完成，请保留全部备份并再次运行当前外观包的安装或卸载入口：' + $_.Exception.Message) 'Error' }
        throw $failure
    }
}
